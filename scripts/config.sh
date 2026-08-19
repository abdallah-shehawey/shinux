#!/usr/bin/env bash
# Shared configuration for every build/publish script in this repository.
# Edit the values in this block and nothing else needs to change.

GITHUB_USER="abdallah-shehawey"
GITHUB_REPO="shinux"

# Short id used for the .repo file, the apt sources file and the GPG key name.
REPO_ID="shinux"
REPO_NAME="Shinux Repository"

# Public URL that GitHub Pages serves docs/ from. No trailing slash.
BASE_URL="${BASE_URL:-https://${GITHUB_USER}.github.io/${GITHUB_REPO}}"

# Identity burned into the signing key and into every package's Maintainer field.
MAINTAINER_NAME="Abdallah Shehawey"
MAINTAINER_EMAIL="sa9290100@gmail.com"
GPG_KEY_UID="${REPO_NAME} Signing Key <${MAINTAINER_EMAIL}>"

# apt architectures the Release file advertises. Packages marked
# "Architecture: all" are folded into each of these automatically.
DEB_ARCHS="amd64 arm64"
DEB_SUITE="stable"
DEB_COMPONENT="main"

# --- derived paths, do not edit -------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/docs}"   # published by GitHub Pages (main branch, /docs)
RPM_DIR="${OUT_DIR}/rpm"
DEB_DIR="${OUT_DIR}/deb"
KEY_ASC="${OUT_DIR}/RPM-GPG-KEY-${REPO_ID}"   # armored, used by rpm/dnf
KEY_GPG="${OUT_DIR}/${REPO_ID}.gpg"           # dearmored, used by apt signed-by
GNUPGHOME_DIR="${ROOT_DIR}/.gnupg"

export GITHUB_USER GITHUB_REPO REPO_ID REPO_NAME BASE_URL \
       MAINTAINER_NAME MAINTAINER_EMAIL GPG_KEY_UID \
       DEB_ARCHS DEB_SUITE DEB_COMPONENT \
       ROOT_DIR BUILD_DIR OUT_DIR RPM_DIR DEB_DIR KEY_ASC KEY_GPG GNUPGHOME_DIR

# Resolve the signing key fingerprint, if a key exists at all.
gpg_fpr() {
  local home="${GNUPGHOME_DIR}"
  [ -n "${SIGN_GNUPGHOME:-}" ] && home="${SIGN_GNUPGHOME}"
  [ -d "$home" ] || return 1
  GNUPGHOME="$home" gpg --list-secret-keys --with-colons "${GPG_KEY_UID}" 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}'
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
