#!/usr/bin/env bash
# Generate the static landing page and the standalone config files that live
# next to the metadata in docs/.
set -euo pipefail
source "$(dirname "$0")/config.sh"

FPR="$(cat "${ROOT_DIR}/.gpg-fingerprint" 2>/dev/null || echo unknown)"
RELEASE_RPM="$(cd "${RPM_DIR}" 2>/dev/null && ls -1 ${REPO_ID}-release-*.rpm 2>/dev/null | sort -V | tail -1)"
RELEASE_RPM="${RELEASE_RPM:-${REPO_ID}-release-1.0-1.noarch.rpm}"
FPR_PRETTY="$(echo "${FPR}" | sed 's/.\{4\}/& /g; s/ $//')"

# Standalone copies, for people who prefer adding the repo by hand.
cat > "${OUT_DIR}/${REPO_ID}.repo" <<EOF
[${REPO_ID}]
name=${REPO_NAME}
baseurl=${BASE_URL}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
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

# ------------------------------------------------------------- package table -
rows=""
shopt -s nullglob
for f in "${RPM_DIR}"/*.rpm; do
  n="$(rpm -qp --qf '%{NAME}|%{VERSION}-%{RELEASE}|%{ARCH}|%{SUMMARY}' "$f" 2>/dev/null)" || continue
  IFS='|' read -r name ver arch summ <<< "$n"
  rows+="<tr><td><code>${name}</code></td><td>${ver}</td><td><span class=\"badge rpm\">rpm</span> ${arch}</td><td>${summ}</td></tr>"
done
for f in "${DEB_DIR}"/pool/*/*/*/*.deb; do
  name="$(dpkg-deb -f "$f" Package 2>/dev/null)" || continue
  ver="$(dpkg-deb -f "$f" Version)"; arch="$(dpkg-deb -f "$f" Architecture)"
  summ="$(dpkg-deb -f "$f" Description | head -1)"
  rows+="<tr><td><code>${name}</code></td><td>${ver}</td><td><span class=\"badge deb\">deb</span> ${arch}</td><td>${summ}</td></tr>"
done

cat > "${OUT_DIR}/index.html" <<HTMLEOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${REPO_NAME}</title>
<meta name="description" content="Third-party dnf and apt repository maintained by ${MAINTAINER_NAME}.">
<style>
  :root{--bg:#0b0f14;--panel:#111823;--line:#1e2a3a;--fg:#e6edf5;--dim:#8ea0b5;
        --accent:#38bdf8;--accent2:#f59e0b;--code:#0a0e13}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:16px/1.65 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
  .wrap{max-width:880px;margin:0 auto;padding:48px 20px 80px}
  h1{font-size:2rem;margin:0 0 6px;letter-spacing:-.02em}
  h2{font-size:1.15rem;margin:44px 0 12px;color:var(--accent)}
  p.lead{color:var(--dim);margin:0 0 8px}
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
  <h1>${REPO_NAME}</h1>
  <p class="lead">A signed package repository for <strong>dnf</strong> (Fedora, RHEL, CentOS, Rocky, Alma)
     and <strong>apt</strong> (Debian, Ubuntu, Mint).</p>

  <h2>1 &middot; Add the repository</h2>
  <div class="tabs" role="tablist">
    <button class="tab" role="tab" aria-selected="true"  data-panel="p-dnf">Fedora / RHEL</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="p-apt">Debian / Ubuntu</button>
    <button class="tab" role="tab" aria-selected="false" data-panel="p-sh">One-liner</button>
  </div>

  <div class="card" id="p-dnf">
<pre><code>sudo rpm --import ${BASE_URL}/RPM-GPG-KEY-${REPO_ID}
sudo dnf install -y ${BASE_URL}/rpm/${RELEASE_RPM}</code></pre>
    <p class="lead">Drops <code>/etc/yum.repos.d/${REPO_ID}.repo</code> and the signing key.</p>
  </div>

  <div class="card" id="p-apt" hidden>
<pre><code>sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL ${BASE_URL}/${REPO_ID}.gpg -o /etc/apt/keyrings/${REPO_ID}.gpg
sudo curl -fsSL ${BASE_URL}/${REPO_ID}.sources -o /etc/apt/sources.list.d/${REPO_ID}.sources
sudo apt update</code></pre>
  </div>

  <div class="card" id="p-sh" hidden>
<pre><code>curl -fsSL ${BASE_URL}/install.sh | sudo sh</code></pre>
    <p class="lead">Detects dnf or apt and does the right thing. Read it first if you would rather not pipe to a shell.</p>
  </div>

  <h2>2 &middot; Install a package</h2>
  <div class="card">
<pre><code>sudo dnf install hello-${REPO_ID}     <span style="color:#5d7186"># Fedora / RHEL</span>
sudo apt install hello-${REPO_ID}     <span style="color:#5d7186"># Debian / Ubuntu</span></code></pre>
  </div>

  <h2>Available packages</h2>
  <div class="card">
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
  const tabs = document.querySelectorAll('.tab');
  tabs.forEach(t => t.addEventListener('click', () => {
    tabs.forEach(o => {
      const on = o === t;
      o.setAttribute('aria-selected', on);
      document.getElementById(o.dataset.panel).hidden = !on;
    });
  }));
</script>
</body>
</html>
HTMLEOF

info "site written to ${OUT_DIR#"${ROOT_DIR}/"}/index.html"
