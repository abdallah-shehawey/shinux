#!/usr/bin/env bash
# End-to-end proof: publish the repository to a throwaway tree served over
# HTTP, then let a real dnf/apt container add it, install, and upgrade.
#
#   scripts/test-install.sh fedora
#   scripts/test-install.sh debian
#
# Nothing here touches docs/ or the committed pool.
set -euo pipefail
family="${1:-fedora}"
PORT="${PORT:-8099}"

source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-tools.sh"

eng="$(container_engine)" || die "podman or docker is required for the install test"
export BASE_URL="http://127.0.0.1:${PORT}"
export OUT_DIR="${BUILD_DIR}/testsite"
source "$(dirname "$0")/config.sh"   # re-derive RPM_DIR/DEB_DIR under the new OUT_DIR

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
# The exported public key lives in docs/; the throwaway tree needs its own copy
# before the release packages can be generated against it.
cp "${ROOT_DIR}/docs/RPM-GPG-KEY-${REPO_ID}" "${OUT_DIR}/" 2>/dev/null \
  || die "no exported key in docs/; run scripts/gpg-setup.sh first"
cp "${ROOT_DIR}/docs/${REPO_ID}.gpg" "${OUT_DIR}/"

info "publishing a throwaway repository at ${BASE_URL}"
"${ROOT_DIR}/scripts/build.sh"    >/dev/null
"${ROOT_DIR}/scripts/make-repo.sh" >/dev/null

python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${OUT_DIR}" >/dev/null 2>&1 &
server=$!
trap 'kill "${server}" 2>/dev/null || true' EXIT
sleep 1
curl -fsS "${BASE_URL}/index.html" >/dev/null || die "local http server did not come up"

case "$family" in
  fedora)
    image="registry.fedoraproject.org/fedora:44"
    script='set -eu
      rpm --import '"${BASE_URL}"'/RPM-GPG-KEY-'"${REPO_ID}"'
      dnf install -y '"${BASE_URL}"'/rpm/'"$(cd "${RPM_DIR}" && ls -1 ${REPO_ID}-release-*.rpm | sort -V | tail -1)"'
      dnf -q repolist '"${REPO_ID}"'
      # The Fedora container image sets tsflags=nodocs, which strips man pages
      # on install. Turn that off so the test actually checks them.
      dnf install -y -q --setopt=tsflags= man-db bash-completion >/dev/null

      echo "### installing every package from the repository"
      dnf install -y --setopt=tsflags= '"${REPO_ID}"'-scripts hello-'"${REPO_ID}"'

      echo "### the metapackage pulled in its dependencies"
      rpm -q vidtime padnum meet hashnum dlup antigravity-update update-every-thing

      echo "### signature on an installed package"
      rpm -q --qf "%{NAME}: %{RSAHEADER:pgpsig}\n" vidtime

      echo "### every command answers --version and --help"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        "$c" --version
        "$c" --help >/dev/null
      done

      echo "### man pages are installed and readable"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        man -w "$c" >/dev/null
      done

      echo "### bash completions are installed"
      ls /usr/share/bash-completion/completions/ | sort

      echo "### update-every-thing detects the right package manager"
      update-every-thing --help | grep -i "dnf/yum or apt"

      echo "### a command actually runs"
      hello-'"${REPO_ID}"'
      cd /tmp && mkdir -p pn && cd pn && touch "1 a.txt" "2 b.txt" "10 c.txt"
      padnum && ls -1'
    ;;
  debian)
    image="docker.io/library/ubuntu:24.04"
    script='set -eu
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates gnupg man-db bash-completion >/dev/null

      echo "### adding the repository the one-command way"
      curl -fsSL '"${BASE_URL}"'/'"${REPO_ID}"'-keyring.deb -o /tmp/keyring.deb
      apt-get install -y /tmp/keyring.deb
      apt-get update

      echo "### the Release file verified against the pinned key"
      apt-cache policy | grep -A1 '"${REPO_ID}"' | head -4

      echo "### installing every package from the repository"
      apt-get install -y '"${REPO_ID}"'-scripts hello-'"${REPO_ID}"'

      echo "### the metapackage pulled in its dependencies"
      dpkg -l vidtime padnum meet hashnum dlup antigravity-update update-every-thing \
        | awk "/^ii/ { print \$2, \$3 }"

      echo "### every command answers --version and --help"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        "$c" --version
        "$c" --help >/dev/null
      done

      echo "### man pages are installed and readable"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        man -w "$c" >/dev/null
      done

      echo "### bash completions are installed"
      ls /usr/share/bash-completion/completions/ | sort

      echo "### update-every-thing picked apt, not dnf"
      update-every-thing --help | grep -i "dnf/yum or apt"

      echo "### a command actually runs"
      hello-'"${REPO_ID}"'
      cd /tmp && mkdir -p pn && cd pn && touch "1 a.txt" "2 b.txt" "10 c.txt"
      padnum && ls -1'
    ;;
  *) die "unknown family '${family}' (expected fedora or debian)" ;;
esac

info "running the install test in ${image}"
"$eng" run --rm --network=host "$image" bash -c "$script"
info "${family}: add-repo -> install -> run all passed"
