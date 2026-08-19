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
    script='set -eux
      rpm --import '"${BASE_URL}"'/RPM-GPG-KEY-'"${REPO_ID}"'
      dnf install -y '"${BASE_URL}"'/rpm/'"$(cd "${RPM_DIR}" && ls -1 ${REPO_ID}-release-*.rpm | sort -V | tail -1)"'
      dnf -q repolist '"${REPO_ID}"'
      dnf install -y hello-'"${REPO_ID}"'
      hello-'"${REPO_ID}"' --version
      hello-'"${REPO_ID}"'
      rpm -qi hello-'"${REPO_ID}"' | grep -E "Signature|Version"'
    ;;
  debian)
    image="docker.io/library/debian:12"
    script='set -eux
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates gnupg >/dev/null
      install -d -m 0755 /etc/apt/keyrings
      curl -fsSL '"${BASE_URL}"'/'"${REPO_ID}"'.gpg -o /etc/apt/keyrings/'"${REPO_ID}"'.gpg
      curl -fsSL '"${BASE_URL}"'/'"${REPO_ID}"'.sources -o /etc/apt/sources.list.d/'"${REPO_ID}"'.sources
      apt-get update
      apt-get install -y '"${REPO_ID}"'-archive-keyring hello-'"${REPO_ID}"'
      hello-'"${REPO_ID}"' --version
      hello-'"${REPO_ID}"'
      apt-cache policy hello-'"${REPO_ID}"''
    ;;
  *) die "unknown family '${family}' (expected fedora or debian)" ;;
esac

info "running the install test in ${image}"
"$eng" run --rm --network=host "$image" bash -c "$script"
info "${family}: add-repo -> install -> run all passed"
