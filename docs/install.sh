#!/bin/sh
# Shinux Repository -- one-shot repository installer.
#   curl -fsSL https://abdallah-shehawey.github.io/shinux/install.sh | sudo sh
set -eu

BASE_URL="https://abdallah-shehawey.github.io/shinux"
REPO_ID="shinux"
RELEASE_RPM="shinux-release-1.0-1.noarch.rpm"

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
