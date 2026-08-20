#!/usr/bin/env bash
# Generate the static landing page and the standalone config files that live
# next to the metadata in docs/.
set -euo pipefail
source "$(dirname "$0")/config.sh"

FPR="$(cat "${ROOT_DIR}/.gpg-fingerprint" 2>/dev/null || echo unknown)"
RELEASE_RPM="$(cd "${RPM_DIR}" 2>/dev/null && ls -1 ${REPO_ID}-release-*.rpm 2>/dev/null | sort -V | tail -1)"
RELEASE_RPM="${RELEASE_RPM:-${REPO_ID}-release-1.0-1.noarch.rpm}"
FPR_PRETTY="$(echo "${FPR}" | sed 's/.\{4\}/& /g; s/ $//')"

# Icons are generated once by scripts/make-icons.py and committed under docs/.
# When OUT_DIR is a throwaway tree (the install test), carry them across so the
# page it serves is the same page.
if [ "${OUT_DIR}" != "${ROOT_DIR}/docs" ]; then
  for icon in favicon.svg favicon.ico favicon-16.png favicon-32.png \
              apple-touch-icon.png logo.svg; do
    if [ -f "${ROOT_DIR}/docs/${icon}" ]; then
      cp "${ROOT_DIR}/docs/${icon}" "${OUT_DIR}/"
    fi
  done
fi

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

cat > "${OUT_DIR}/${REPO_ID}.sources" <<EOF
Types: deb
URIs: ${BASE_URL}/deb
Suites: ${DEB_SUITE}
Components: ${DEB_COMPONENT}
Architectures: ${DEB_ARCHS}
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
RELEASE_RPM="${RELEASE_RPM}"
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
  "$pm" install -y "${BASE_URL}/rpm/${RELEASE_RPM}"
  echo "==> done. try: sudo $pm install hello-${REPO_ID}"

elif command -v apt-get >/dev/null 2>&1; then
  echo "==> deb system detected, installing ${REPO_ID}-archive-keyring"
  install -d -m 0755 /etc/apt/keyrings
  fetch "${BASE_URL}/${REPO_ID}.gpg" "/etc/apt/keyrings/${REPO_ID}.gpg"
  chmod 0644 "/etc/apt/keyrings/${REPO_ID}.gpg"
  fetch "${BASE_URL}/${REPO_ID}.sources" "/etc/apt/sources.list.d/${REPO_ID}.sources"
  apt-get update
  apt-get install -y "${REPO_ID}-archive-keyring"
  echo "==> done. try: sudo apt install hello-${REPO_ID}"

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

else
  echo "Unsupported system: no dnf, yum or apt-get found." >&2
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
  summ="$(dpkg-deb -f "$f" Description | head -1)"
  if [ -z "${pkg_version[$name]:-}" ]; then
    pkg_version["$name"]="$ver"
    pkg_summary["$name"]="$summ"
  fi
  case " ${pkg_formats[$name]:-} " in *" deb "*) ;; *) pkg_formats["$name"]="${pkg_formats[$name]:-} deb" ;; esac
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
<style>
  :root{--bg:#0b0f14;--panel:#111823;--line:#1e2a3a;--fg:#e6edf5;--dim:#8ea0b5;
        --accent:#38bdf8;--accent2:#f59e0b;--code:#0a0e13}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:16px/1.65 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
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
  table{width:100%;border-collapse:collapse;margin-top:10px;font-size:.92rem}
  th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}
  th{color:var(--dim);font-weight:600;font-size:.8rem;text-transform:uppercase;letter-spacing:.05em}
  .badge{display:inline-block;padding:1px 7px;border-radius:5px;font-size:.72rem;
         font-weight:700;letter-spacing:.03em}
  .badge.rpm{background:#0e3a52;color:#7dd3fc}
  .badge.deb{background:#4a2f08;color:#fbbf24}
  .fpr{font-family:ui-monospace,monospace;font-size:.82rem;color:var(--accent2);word-break:break-all}
  footer{margin-top:56px;color:var(--dim);font-size:.85rem;border-top:1px solid var(--line);padding-top:18px}
  a{color:var(--accent)}
  [hidden]{display:none!important}
</style>
</head>
<body>
<div class="wrap">
  <h1><img src="logo.svg" alt="" width="40" height="40">${REPO_NAME}</h1>
  <p class="lead">A signed package repository for <strong>dnf</strong> (Fedora, RHEL, CentOS, Rocky, Alma)
     and <strong>apt</strong> (Debian, Ubuntu, Mint).</p>

  <h2>1 &middot; Add the repository</h2>
  <div class="tabs" role="tablist">
    <button class="tab" role="tab" aria-selected="true"  data-panel="p-sh">Any distro</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="p-dnf">Fedora / RHEL</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="p-apt">Debian / Ubuntu</button>
  </div>

  <div class="card" id="p-sh">
<pre><code>curl -fsSL ${BASE_URL}/install.sh | sudo sh</code></pre>
    <p class="lead">Detects dnf or apt, imports the key and adds the repository.
       <a href="install.sh">Read it first</a> if you would rather not pipe into a shell.</p>
  </div>

  <div class="card" id="p-dnf" hidden>
<pre><code>sudo rpm --import ${BASE_URL}/RPM-GPG-KEY-${REPO_ID}
sudo dnf install -y ${BASE_URL}/rpm/${RELEASE_RPM}</code></pre>
    <p class="lead">The first line trusts the signing key, the second installs
       <code>/etc/yum.repos.d/${REPO_ID}.repo</code>. Skip the first and dnf asks you to
       confirm the key on your next install instead — same result, one prompt.</p>
  </div>

  <div class="card" id="p-apt" hidden>
<pre><code>curl -fsSL ${BASE_URL}/${REPO_ID}-keyring.deb -o /tmp/${REPO_ID}-keyring.deb &amp;&amp; sudo apt install -y /tmp/${REPO_ID}-keyring.deb</code></pre>
    <p class="lead">Installs the sources entry and the signing key, then run <code>sudo apt update</code>.</p>
  </div>

  <h2>2 &middot; Install a package</h2>
  <div class="card">
<pre><code>sudo dnf install hello-${REPO_ID}     <span style="color:#5d7186"># Fedora / RHEL</span>
sudo apt install hello-${REPO_ID}     <span style="color:#5d7186"># Debian / Ubuntu</span></code></pre>
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
</script>
</body>
</html>
HTMLEOF

info "site written to ${OUT_DIR#"${ROOT_DIR}/"}/index.html"
