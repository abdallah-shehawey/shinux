#!/usr/bin/env bash
# Generate the static landing page and the standalone config files that live
# next to the metadata in docs/.
set -euo pipefail
source "$(dirname "$0")/config.sh"

FPR="$(cat "${ROOT_DIR}/.gpg-fingerprint" 2>/dev/null || echo unknown)"
RELEASE_RPM="$(cd "${RPM_DIR}" 2>/dev/null && ls -1 ${REPO_ID}-release-*.rpm 2>/dev/null | sort -V | tail -1)"
RELEASE_RPM="${RELEASE_RPM:-${REPO_ID}-release-1.0-1.noarch.rpm}"
KEYRING_DEB="$(find "${DEB_DIR}" -type f -name "${REPO_ID}-archive-keyring_*.deb" 2>/dev/null \
                 -printf '%f\n' | sort -V | tail -1)"
KEYRING_DEB="${KEYRING_DEB:-${REPO_ID}-archive-keyring_1.0-1_all.deb}"

# The two packages that add the repository are packages too, and they were the
# last thing still fetched from Pages, which reports nothing. Everything else
# here -- keys, signatures, the sources file -- has to stay on Pages: it is
# read before this repository is trusted at all, and none of it is a download
# worth counting. Off the pool these fall back to the Pages copies, which is
# what `make serve` and the install tests need; the short docs/-keyring.deb
# alias stays published either way, for links already handed out.
if [ "${ASSET_POOL}" = "1" ]; then
  RELEASE_RPM_URL="${ASSET_BASE}/${RELEASE_RPM}"
  KEYRING_DEB_URL="${ASSET_BASE}/${KEYRING_DEB}"
else
  RELEASE_RPM_URL="${BASE_URL}/rpm/${RELEASE_RPM}"
  KEYRING_DEB_URL="${BASE_URL}/${REPO_ID}-keyring.deb"
fi
FPR_PRETTY="$(echo "${FPR}" | sed 's/.\{4\}/& /g; s/ $//')"

# Everything the page needs that is not generated: the icons, and the two web
# fonts the page is drawn in. site/ is the only part of the published tree that
# is still in git -- docs/ is assembled from scratch on every publish, and CI
# has neither Pillow to redraw the icons nor the fonts installed to bake them.
# This is what puts them in the real tree and in the throwaway one the install
# test serves.
shopt -s nullglob
for icon in "${ROOT_DIR}"/site/*; do
  cp -f "${icon}" "${OUT_DIR}/"
done

# Standalone copies, for people who prefer adding the repo by hand.
# repo_gpgcheck stays off here for the same reason as in the release package:
# packages are still verified by gpgcheck=1, while metadata verification would
# break `dnf install <TAB>`, which runs dnf as an unprivileged user with its own
# empty keyring. See scripts/gen-release-packages.sh for the full note.
cat > "${OUT_DIR}/${REPO_ID}.repo" <<EOF
[${REPO_ID}]
name=${REPO_NAME}
baseurl=${BASE_URL}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=${BASE_URL}/RPM-GPG-KEY-${REPO_ID}
metadata_expire=6h
EOF

# The flat repository on the release rather than the dists/ tree on Pages: a
# release asset is a download GitHub counts and a Pages hit is not. See the
# same stanza in gen-release-packages.sh for why the shape changes.
cat > "${OUT_DIR}/${REPO_ID}.sources" <<EOF
Types: deb
URIs: ${ASSET_ROOT}
Suites: ${POOL_TAG}/
Signed-By: /etc/apt/keyrings/${REPO_ID}.gpg
EOF

# --------------------------------------------------------------- install.sh --
cat > "${OUT_DIR}/install.sh" <<EOF
#!/bin/sh
# ${REPO_NAME} -- one-shot repository installer.
#   curl -fsSL ${BASE_URL}/install.sh | sudo sh
set -eu

BASE_URL="${BASE_URL}"
REPO_ID="${REPO_ID}"
RELEASE_RPM_URL="${RELEASE_RPM_URL}"
# Where the packages themselves are. Metadata, keys and signatures still come
# from Pages; only the download of a package moves, because that is the one
# GitHub counts.
ASSET_BASE="${ASSET_BASE}"
EOF
cat >> "${OUT_DIR}/install.sh" <<'EOF'

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer writes to /etc, run it with sudo." >&2
  exit 1
fi

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else echo "need curl or wget" >&2; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  pm="$(command -v dnf || command -v yum)"
  echo "==> rpm system detected, installing ${REPO_ID}-release"
  fetch "${BASE_URL}/RPM-GPG-KEY-${REPO_ID}" "$tmp/key" \
    || { echo "cannot reach ${BASE_URL}" >&2; exit 1; }
  rpm --import "$tmp/key"
  "$pm" install -y "${RELEASE_RPM_URL}"
  echo "==> done. try: sudo $pm install hello-${REPO_ID}"

elif command -v apt-get >/dev/null 2>&1; then
  echo "==> deb system detected, installing ${REPO_ID}-archive-keyring"
  install -d -m 0755 /etc/apt/keyrings
  fetch "${BASE_URL}/${REPO_ID}.gpg" "/etc/apt/keyrings/${REPO_ID}.gpg"
  chmod 0644 "/etc/apt/keyrings/${REPO_ID}.gpg"
  fetch "${BASE_URL}/${REPO_ID}.sources" "/etc/apt/sources.list.d/${REPO_ID}.sources"
  apt-get update
  # --force-confnew, because this script has just written that same sources
  # file by hand and the package ships it as a conffile. The two are generated
  # from one template and normally match byte for byte, so dpkg says nothing --
  # but if they ever drift, dpkg stops at an interactive conffile prompt, and
  # this script is run through a pipe with no stdin: "end of file on stdin at
  # conffile prompt", and the install fails having already added the repository.
  # The package's copy is the canonical one, so taking it is the right answer.
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confnew "${REPO_ID}-archive-keyring"
  echo "==> done. try: sudo apt install hello-${REPO_ID}"

elif command -v pacman >/dev/null 2>&1; then
  echo "==> Arch system detected, adding ${REPO_ID} pacman repository"
  fetch "${BASE_URL}/${REPO_ID}.gpg" "$tmp/${REPO_ID}.gpg" \
    || { echo "cannot reach ${BASE_URL}/${REPO_ID}.gpg" >&2; exit 1; }
  # `pacman-key --init`, not `install -d`. --lsign-key signs with pacman's own
  # local master key and fails with "There is no secret key available to sign
  # with" if that keyring has not been initialised -- and the `install -d -m
  # 0755` this replaces made it worse, because 0755 is exactly the mode gpg
  # refuses to use a home directory at. --init is idempotent and is what the
  # Arch documentation asks for before --add on any machine.
  pacman-key --init >/dev/null 2>&1
  pacman-key --add "$tmp/${REPO_ID}.gpg" >/dev/null
  pacman-key --lsign-key "$(gpg --show-keys --with-colons "$tmp/${REPO_ID}.gpg" | awk -F: '$1 == "fpr" { print $10; exit }')" >/dev/null
  # The release, not Pages: pacman asks for shinux.db and then for a bare
  # %FILENAME% off this one URL, and both are release assets, so the install is
  # a download GitHub counts. Rewritten on every run, which is how a machine
  # that added the repository before this moves over -- re-run install.sh.
  cat > "/etc/pacman.d/${REPO_ID}-mirrorlist" <<EOF_MIRROR
Server = ${ASSET_BASE}
EOF_MIRROR
  if ! grep -q '^\[${REPO_ID}\]$' /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<EOF_REPO

[${REPO_ID}]
Include = /etc/pacman.d/${REPO_ID}-mirrorlist
SigLevel = Required DatabaseOptional
EOF_REPO
  fi
  pacman -Sy --noconfirm
  echo "==> done. try: sudo pacman -S hello-${REPO_ID}"

else
  echo "Unsupported system: no dnf, yum or apt-get found." >&2
  exit 1
fi
EOF
chmod +x "${OUT_DIR}/install.sh"

# ------------------------------------------------------------- uninstall.sh --
cat > "${OUT_DIR}/uninstall.sh" <<EOF
#!/bin/sh
# ${REPO_NAME} -- remove the repository from this machine.
#   curl -fsSL ${BASE_URL}/uninstall.sh | sudo sh
#
# By default this removes only the repository configuration and its key; any
# packages you installed from it stay. Pass --purge to remove those too.
set -eu

REPO_ID="${REPO_ID}"
EOF
cat >> "${OUT_DIR}/uninstall.sh" <<'EOF'

PURGE=no
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=yes ;;
    -h|--help)
      echo "usage: uninstall.sh [--purge]"
      echo "  --purge  also remove every package installed from the repository"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This removes files under /etc, run it with sudo." >&2
  exit 1
fi

if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  pm="$(command -v dnf || command -v yum)"

  if [ "$PURGE" = yes ]; then
    # Column 3 of `list --installed` is the repository a package came from.
    pkgs="$("$pm" list --installed 2>/dev/null \
            | awk -v r="@${REPO_ID}" '$3 == r && $1 != "'"${REPO_ID}"'-release" {print $1}')"
    if [ -n "$pkgs" ]; then
      echo "==> removing packages installed from ${REPO_ID}: $pkgs"
      # shellcheck disable=SC2086
      "$pm" remove -y $pkgs
    else
      echo "==> no packages from ${REPO_ID} are installed"
    fi
  fi

  if rpm -q "${REPO_ID}-release" >/dev/null 2>&1; then
    echo "==> removing ${REPO_ID}-release"
    "$pm" remove -y "${REPO_ID}-release"
  fi
  rm -f "/etc/yum.repos.d/${REPO_ID}.repo" "/etc/yum.repos.d/${REPO_ID}.repo.rpmnew" \
        "/etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}"

  # Drop the trusted key from the rpm database.
  for k in $(rpm -qa 'gpg-pubkey*' --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n' 2>/dev/null \
             | grep -i "${REPO_ID}" | cut -d' ' -f1); do
    echo "==> forgetting signing key $k"
    rpm -e --allmatches "$k" || true
  done

  "$pm" clean all >/dev/null 2>&1 || true
  echo "==> ${REPO_ID} removed"

elif command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive

  if [ "$PURGE" = yes ]; then
    # Every package name the repository advertises, from apt's cached index.
    names="$(cat /var/lib/apt/lists/*${REPO_ID}*_Packages 2>/dev/null \
             | awk '/^Package: /{print $2}' | sort -u)"
    pkgs=""
    for n in $names; do
      [ "$n" = "${REPO_ID}-archive-keyring" ] && continue
      if dpkg-query -W -f='${Status}' "$n" 2>/dev/null | grep -q '^install ok installed$'; then
        pkgs="$pkgs $n"
      fi
    done
    if [ -n "$pkgs" ]; then
      echo "==> removing packages installed from ${REPO_ID}:$pkgs"
      # shellcheck disable=SC2086
      apt-get purge -y $pkgs
    else
      echo "==> no packages from ${REPO_ID} are installed"
    fi
  fi

  if dpkg-query -W -f='${Status}' "${REPO_ID}-archive-keyring" 2>/dev/null \
       | grep -q '^install ok installed$'; then
    echo "==> removing ${REPO_ID}-archive-keyring"
    apt-get purge -y "${REPO_ID}-archive-keyring"
  fi
  rm -f "/etc/apt/sources.list.d/${REPO_ID}.sources" \
        "/etc/apt/sources.list.d/${REPO_ID}.list" \
        "/etc/apt/keyrings/${REPO_ID}.gpg"

  apt-get update -qq || true
  echo "==> ${REPO_ID} removed"

elif command -v pacman >/dev/null 2>&1; then
  if [ "$PURGE" = yes ]; then
    pkgs="$(pacman -Qq | while read -r name; do
      pacman -Qi "$name" 2>/dev/null | awk -v repo="${REPO_ID}" \
        '$1 == "Name" { n = $3 } $1 == "Repository" && $3 == repo { print n }'
    done)"
    if [ -n "$pkgs" ]; then
      echo "==> removing packages installed from ${REPO_ID}: $pkgs"
      # shellcheck disable=SC2086
      pacman -Rns --noconfirm $pkgs || true
    fi
  fi
  key_fpr="$(gpg --homedir /etc/pacman.d/gnupg --show-keys --with-colons \
    "/etc/pacman.d/${REPO_ID}.gpg" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
  [ -z "$key_fpr" ] || pacman-key --delete "$key_fpr" >/dev/null 2>&1 || true
  sed -i "/^\[${REPO_ID}\]$/,/^SigLevel = Required DatabaseOptional$/d" /etc/pacman.conf
  rm -f "/etc/pacman.d/${REPO_ID}-mirrorlist" "/etc/pacman.d/${REPO_ID}.gpg"
  pacman -Syy --noconfirm >/dev/null 2>&1 || true
  echo "==> ${REPO_ID} removed"

else
  echo "Unsupported system: no dnf, yum, apt-get or pacman found." >&2
  exit 1
fi
EOF
chmod +x "${OUT_DIR}/uninstall.sh"

# ------------------------------------------------------------- package table -
# One row per package, listing which formats carry it, rather than one row per
# built artefact -- otherwise every package appears twice.
declare -A pkg_version=() pkg_summary=() pkg_formats=()
shopt -s nullglob

for f in "${RPM_DIR}"/*.rpm; do
  n="$(rpm -qp --qf '%{NAME}|%{VERSION}-%{RELEASE}|%{SUMMARY}' "$f" 2>/dev/null)" || continue
  IFS='|' read -r name ver summ <<< "$n"
  # Keep only the newest build of each package.
  if [ -z "${pkg_version[$name]:-}" ] || \
     [ "$(printf '%s\n%s\n' "${pkg_version[$name]}" "$ver" | sort -V | tail -1)" = "$ver" ]; then
    pkg_version["$name"]="$ver"
    pkg_summary["$name"]="$summ"
  fi
  case " ${pkg_formats[$name]:-} " in *" rpm "*) ;; *) pkg_formats["$name"]="${pkg_formats[$name]:-} rpm" ;; esac
done

for f in "${DEB_DIR}"/pool/*/*/*/*.deb; do
  name="$(dpkg-deb -f "$f" Package 2>/dev/null)" || continue
  ver="$(dpkg-deb -f "$f" Version)"
  # Not piped into `head -1`: head leaves as soon as it has its line, and
  # dpkg-deb still reading a 73 MB archive then dies of SIGPIPE, which
  # pipefail turns into a failed publish. Take the first line in the shell.
  summ="$(dpkg-deb -f "$f" Description)"
  summ="${summ%%$'\n'*}"
  if [ -z "${pkg_version[$name]:-}" ]; then
    pkg_version["$name"]="$ver"
    pkg_summary["$name"]="$summ"
  fi
  case " ${pkg_formats[$name]:-} " in *" deb "*) ;; *) pkg_formats["$name"]="${pkg_formats[$name]:-} deb" ;; esac
done

# Arch packages are published as native .pkg.tar.zst files under docs/arch.
# Their metadata is authoritative for format support; versions and summaries
# still come from the rpm/deb indexes so the table remains stable on CI hosts
# that do not have an Arch package parser installed.
for meta in "${ROOT_DIR}"/packages/*/metadata.env; do
  [ -f "$meta" ] || continue
  unset PKG_NAME PKG_VERSION PKG_RELEASE PKG_SUMMARY PKG_FORMATS
  # shellcheck disable=SC1090
  source "$meta"
  case " ${PKG_FORMATS:-} " in *" arch "*)
    pkg_formats["${PKG_NAME}"]="${pkg_formats[${PKG_NAME}]:-} arch"
    [ -n "${pkg_version[${PKG_NAME}]:-}" ] || pkg_version["${PKG_NAME}"]="${PKG_VERSION}-${PKG_RELEASE}"
    [ -n "${pkg_summary[${PKG_NAME}]:-}" ] || pkg_summary["${PKG_NAME}"]="${PKG_SUMMARY}"
    ;;
  esac
done

# The two repo-configuration packages are install plumbing, not something to
# browse; they get their own section above.
rows=""
for name in $(printf '%s\n' "${!pkg_version[@]}" | LC_ALL=C sort); do
  case "$name" in "${REPO_ID}-release"|"${REPO_ID}-archive-keyring") continue ;; esac
  badges=""
  for fmt in ${pkg_formats[$name]}; do
    badges+="<span class=\"badge ${fmt}\">${fmt}</span> "
  done
  rows+="<tr><td><code>${name}</code></td><td>${pkg_version[$name]}</td><td>${badges}</td><td>${pkg_summary[$name]}</td></tr>"
done

cat > "${OUT_DIR}/index.html" <<HTMLEOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${REPO_NAME}</title>
<meta name="description" content="Third-party dnf and apt repository maintained by ${MAINTAINER_NAME}.">
<meta name="theme-color" content="#0b0f14">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="icon" href="favicon.ico" sizes="48x48">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<!-- The page's own font, found by the parser rather than by the stylesheet
     below it. Only the Latin one: the Arabic face is for the odd word, and a
     page with none of it should not pay 40 KB to find that out. -->
<link rel="preload" href="poetsen-one.woff2" as="font" type="font/woff2" crossorigin>
<style>
  /* Poetsen One for Latin, and beside it a face built for the Arabic it has
     none of -- the pair this repository's maintainer reads their own desktop
     in. Two @font-face faces of ONE family split by \`unicode-range\`: an Arabic
     character matches both, and CSS breaks the tie by declaration order, so the
     Arabic one is written SECOND and moving it is a bug.

     Self-hosted rather than fetched from Google: one origin, no third party
     watching who reads this page, and nothing to go wrong offline. Subsetted,
     so the pair is 81 KB. Both files are committed under site/ and copied out
     with the icons; licences in FONTS-NOTICE.txt beside them. \`local()\` comes
     first, because the machine this was written on has both installed already.

     One weight, 400 -- Poetsen One has no bold face, and the heavier text here
     is the browser's synthesis, which is what it looks like on that desktop. */
  @font-face{font-family:"Poetsen";
    src:local("PoetsenOne"),local("Poetsen One"),url("poetsen-one.woff2") format("woff2");
    font-weight:400;font-style:normal;font-display:swap;
    unicode-range:U+0000-00FF,U+0100-017F,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,
                  U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,
                  U+2190-2193,U+2212,U+2215,U+2713-2714,U+FEFF,U+FFFD}
  /* From the Arabic comma, not from U+0600: the Latin punctuation below it
     reads better in the Latin face. */
  @font-face{font-family:"Poetsen";
    src:local("Poetsen Arabic"),url("poetsen-arabic.woff2") format("woff2");
    font-weight:400;font-style:normal;font-display:swap;
    unicode-range:U+060C-06FF,U+0750-077F,U+0870-08FF,U+FB50-FDFF,U+FE70-FEFF,
                  U+10E60-10E7E,U+1EE00-1EEFF}
  :root{--bg:#0b0f14;--panel:#111823;--line:#1e2a3a;--fg:#e6edf5;--dim:#8ea0b5;
        --accent:#38bdf8;--accent2:#f59e0b;--code:#0a0e13}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:16px/1.65 "Poetsen",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
  /* Full-bleed: the page uses the whole window, with the side gutter growing
     on wide screens instead of a centred column. Only running prose keeps a
     measure, so cards, tables and code blocks span the full width. */
  .wrap{margin:0;padding:48px clamp(20px,4vw,72px) 80px}
  h1{font-size:2rem;margin:0 0 6px;letter-spacing:-.02em;
     display:flex;align-items:center;gap:12px}
  h2{font-size:1.15rem;margin:44px 0 12px;color:var(--accent)}
  p.lead{color:var(--dim);margin:0 0 8px;max-width:90ch}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:14px;
        padding:18px 20px;margin:14px 0}
  .tabs{display:flex;gap:8px;margin:18px 0 0;flex-wrap:wrap}
  .tab{padding:7px 14px;border:1px solid var(--line);border-radius:999px;
       background:transparent;color:var(--dim);cursor:pointer;font:inherit;font-size:.9rem}
  .tab[aria-selected=true]{background:var(--accent);color:#04121c;border-color:var(--accent);font-weight:600}
  pre{background:var(--code);border:1px solid var(--line);border-radius:10px;
      padding:14px 16px;overflow-x:auto;margin:12px 0;font-size:.88rem}
  code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
  pre code{color:#cfe8ff}
  /* Copy button. The wrapper is added by the script at the bottom of the page,
     so the button holds still while a long command scrolls underneath it. */
  .codewrap{position:relative}
  .codewrap pre{padding-right:112px}
  .copy{position:absolute;top:9px;right:9px;display:inline-flex;align-items:center;gap:6px;
        padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--code);
        color:var(--dim);font:inherit;font-size:.75rem;line-height:1;cursor:pointer;
        transition:color .15s,border-color .15s,background .15s}
  .copy:hover,.copy:focus-visible{color:var(--fg);border-color:var(--accent);background:var(--panel)}
  .copy svg{width:14px;height:14px;flex:none;fill:none;stroke:currentColor;stroke-width:2;
            stroke-linecap:round;stroke-linejoin:round}
  .copy.ok{color:#86efac;border-color:#2f6f4f}
  .copy.err{color:#fca5a5;border-color:#7f3030}
  /* Phone widths: the label costs more room than a command line can spare. */
  @media (max-width:560px){
    .codewrap pre{padding-right:48px}
    .copy{padding:7px;gap:0}
    .copy span{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}
  }
  table{width:100%;border-collapse:collapse;margin-top:10px;font-size:.92rem}
  th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}
  th{color:var(--dim);font-weight:600;font-size:.8rem;text-transform:uppercase;letter-spacing:.05em}
  .badge{display:inline-block;padding:1px 7px;border-radius:5px;font-size:.72rem;
         font-weight:700;letter-spacing:.03em}
  .badge.rpm{background:#0e3a52;color:#7dd3fc}
  .badge.deb{background:#4a2f08;color:#fbbf24}
  .badge.arch{background:#163b2f;color:#86efac}
  .fpr{font-family:ui-monospace,monospace;font-size:.82rem;color:var(--accent2);word-break:break-all}
  footer{margin-top:56px;color:var(--dim);font-size:.85rem;border-top:1px solid var(--line);padding-top:18px}
  a{color:var(--accent)}
  [hidden]{display:none!important}
</style>
</head>
<body>
<div class="wrap">
  <h1><img src="logo.svg" alt="" width="40" height="40">${REPO_NAME}</h1>
  <p class="lead">A signed package repository for <strong>dnf</strong> (Fedora, RHEL, CentOS, Rocky, Alma),
     <strong>apt</strong> (Debian, Ubuntu, Mint), and Arch Linux release packages.</p>

  <h2>1 &middot; Add the repository</h2>
  <div class="tabs" role="tablist">
    <button class="tab" role="tab" aria-selected="true"  data-panel="p-sh">Any distro</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="p-dnf">Fedora / RHEL</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="p-apt">Debian / Ubuntu</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="p-arch">Arch Linux</button>
  </div>

  <div class="card" id="p-sh">
<pre><code>curl -fsSL ${BASE_URL}/install.sh | sudo sh</code></pre>
    <p class="lead">Detects dnf or apt, imports the key and adds the repository.
       <a href="install.sh">Read it first</a> if you would rather not pipe into a shell.</p>
  </div>

  <div class="card" id="p-dnf" hidden>
<pre><code>sudo rpm --import ${BASE_URL}/RPM-GPG-KEY-${REPO_ID}
sudo dnf install -y ${RELEASE_RPM_URL}</code></pre>
    <p class="lead">The first line trusts the signing key, the second installs
       <code>/etc/yum.repos.d/${REPO_ID}.repo</code>. Skip the first and dnf asks you to
       confirm the key on your next install instead — same result, one prompt.</p>
  </div>

  <div class="card" id="p-apt" hidden>
<pre><code>curl -fsSL ${KEYRING_DEB_URL} -o /tmp/${REPO_ID}-keyring.deb &amp;&amp; sudo apt install -y /tmp/${REPO_ID}-keyring.deb</code></pre>
    <p class="lead">Installs the sources entry and the signing key, then run <code>sudo apt update</code>.</p>
  </div>

  <div class="card" id="p-arch" hidden>
<pre><code>curl -fsSL ${BASE_URL}/install.sh | sudo sh
sudo pacman -S whatsapp</code></pre>
    <p class="lead">Adds the signed pacman repository and refreshes its database; then install any package with <code>pacman -S</code>.</p>
  </div>

  <h2>2 &middot; Install a package</h2>
  <div class="card">
<pre><code>sudo dnf install hello-${REPO_ID}     <span style="color:#5d7186"># Fedora / RHEL</span>
sudo apt install hello-${REPO_ID}     <span style="color:#5d7186"># Debian / Ubuntu</span>
sudo pacman -S hello-${REPO_ID}  <span style="color:#5d7186"># Arch</span></code></pre>
  </div>

  <h2>3 &middot; Remove the repository</h2>
  <div class="tabs" role="tablist">
    <button class="tab" role="tab" aria-selected="true"  data-panel="r-sh">One-liner</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="r-dnf">Fedora / RHEL</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="r-apt">Debian / Ubuntu</button>
  </div>

  <div class="card" id="r-sh">
<pre><code>curl -fsSL ${BASE_URL}/uninstall.sh | sudo sh
curl -fsSL ${BASE_URL}/uninstall.sh | sudo sh -s -- --purge   <span style="color:#5d7186"># also remove installed packages</span></code></pre>
    <p class="lead">Without <code>--purge</code>, packages you already installed stay on the system;
       only the repository and its key are removed.</p>
  </div>

  <div class="card" id="r-dnf" hidden>
<pre><code>sudo dnf remove ${REPO_ID}-release
sudo rpm -e \$(rpm -qa 'gpg-pubkey*' --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n' | grep -i ${REPO_ID} | cut -d' ' -f1)
sudo dnf clean all</code></pre>
    <p class="lead">The first line drops <code>/etc/yum.repos.d/${REPO_ID}.repo</code>; the second stops trusting the signing key.</p>
  </div>

  <div class="card" id="r-apt" hidden>
<pre><code>sudo apt purge ${REPO_ID}-archive-keyring
sudo rm -f /etc/apt/sources.list.d/${REPO_ID}.sources /etc/apt/keyrings/${REPO_ID}.gpg
sudo apt update</code></pre>
  </div>

  <h2>Available packages</h2>
  <div class="card">
    <p class="lead">Each one is a separate install — take only what you want.
       Every command ships a man page, <code>--help</code>, <code>--version</code>
       and bash completion, and pulls in its own dependencies.
       <code>${REPO_ID}-scripts</code> installs the lot.</p>
    <table>
      <thead><tr><th>Package</th><th>Version</th><th>Format</th><th>Summary</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  </div>

  <h2>Signing key</h2>
  <div class="card">
    <p class="lead">Every package and both metadata indexes are signed with:</p>
    <p class="fpr">${FPR_PRETTY}</p>
    <p class="lead"><a href="RPM-GPG-KEY-${REPO_ID}">RPM-GPG-KEY-${REPO_ID}</a> (armored, for rpm)
       &middot; <a href="${REPO_ID}.gpg">${REPO_ID}.gpg</a> (binary, for apt <code>Signed-By</code>)</p>
  </div>

  <footer>
    Maintained by ${MAINTAINER_NAME} &middot;
    <a href="https://github.com/${GITHUB_USER}/${GITHUB_REPO}">source on GitHub</a>
  </footer>
</div>
<script>
  document.querySelectorAll('.tabs').forEach(group => {
    const tabs = group.querySelectorAll('.tab');
    tabs.forEach(t => t.addEventListener('click', () => {
      tabs.forEach(o => {
        const on = o === t;
        o.setAttribute('aria-selected', on);
        document.getElementById(o.dataset.panel).hidden = !on;
      });
    }));
  });

  // A copy button on every code block. The grey trailing "# ..." notes are
  // markup spans rather than part of any command, so they are dropped from
  // what lands on the clipboard.
  const COPY_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true">'
    + '<rect x="9" y="9" width="11" height="11" rx="2"/>'
    + '<path d="M5 15V5a2 2 0 0 1 2-2h8"/></svg>';
  const OK_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12.5 9 17.5 20 6.5"/></svg>';

  const copyText = text => {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    // Plain http, a local preview say, blocks the async clipboard; this still works.
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    ta.remove();
    return ok ? Promise.resolve() : Promise.reject(new Error('copy blocked'));
  };

  document.querySelectorAll('pre > code').forEach(code => {
    const pre = code.parentNode;
    const wrap = document.createElement('div');
    wrap.className = 'codewrap';
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(pre);

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'copy';
    btn.title = 'Copy to clipboard';
    btn.innerHTML = COPY_SVG + '<span>Copy</span>';
    wrap.appendChild(btn);

    let timer;
    const flash = (state, icon, label) => {
      clearTimeout(timer);
      btn.classList.remove('ok', 'err');
      if (state) btn.classList.add(state);
      btn.innerHTML = icon + '<span>' + label + '</span>';
      timer = setTimeout(() => {
        btn.classList.remove('ok', 'err');
        btn.innerHTML = COPY_SVG + '<span>Copy</span>';
      }, 1800);
    };

    btn.addEventListener('click', () => {
      const clone = code.cloneNode(true);
      clone.querySelectorAll('span').forEach(s => s.remove());
      const text = clone.textContent.split('\n')
        .map(line => line.replace(/\s+\$/, ''))
        .join('\n').trim();

      copyText(text).then(
        () => flash('ok', OK_SVG, 'Copied'),
        () => {
          // Nothing reached the clipboard: select the block so Ctrl+C can.
          const range = document.createRange();
          range.selectNodeContents(code);
          const sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
          flash('err', COPY_SVG, 'Press Ctrl+C');
        });
    });
  });
</script>
</body>
</html>
HTMLEOF

info "site written to ${OUT_DIR#"${ROOT_DIR}/"}/index.html"
