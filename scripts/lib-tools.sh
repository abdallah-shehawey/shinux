#!/usr/bin/env bash
# Tool resolution, in order of preference:
#   1. the host's own binary
#   2. .tools/root -- rpms unpacked locally by scripts/fetch-tools.sh, no root
#   3. a rootless podman/docker container, for non-rpm hosts
#
# createrepo_c and rpmsign are the two tools Fedora does not ship by default,
# and installing them needs sudo. Steps 2 and 3 keep the whole workflow usable
# without it.

TOOLS_IMAGE="localhost/shinux-tools:latest"

have() { command -v "$1" >/dev/null 2>&1; }

toolroot_bin() {
  local candidate="${ROOT_DIR}/.tools/root/usr/bin/$1"
  [ -x "$candidate" ] && echo "$candidate"
}

container_engine() {
  if have podman; then echo podman
  elif have docker; then echo docker
  else return 1; fi
}

ensure_tools_image() {
  local eng; eng="$(container_engine)" || return 1
  "$eng" image inspect "${TOOLS_IMAGE}" >/dev/null 2>&1 && return 0
  info "building the ${TOOLS_IMAGE} toolbox image (one time)"
  "$eng" build -t "${TOOLS_IMAGE}" -f "${ROOT_DIR}/scripts/Containerfile.tools" "${ROOT_DIR}/scripts"
}

# in_tools <cmd> [args...] -- run inside the toolbox with ROOT_DIR bind-mounted
# at the same path, as the calling uid, so every file it writes stays ours.
in_tools() {
  local eng; eng="$(container_engine)" || die "no way to run '$1': install it, or run scripts/fetch-tools.sh, or install podman"
  ensure_tools_image || die "could not build the toolbox image"
  local extra=()
  [ "$eng" = podman ] && extra+=(--userns=keep-id)
  "$eng" run --rm \
    -v "${ROOT_DIR}:${ROOT_DIR}:z" \
    -w "${PWD}" \
    -e "GNUPGHOME=${GNUPGHOME:-${GNUPGHOME_DIR}}" \
    -u "$(id -u):$(id -g)" \
    "${extra[@]}" \
    "${TOOLS_IMAGE}" "$@"
}

tool() {
  local bin="$1"; shift

  if have "$bin"; then "$bin" "$@"; return; fi

  local local_bin; local_bin="$(toolroot_bin "$bin")"
  if [ -z "$local_bin" ] && have dnf && have rpm2cpio; then
    "${ROOT_DIR}/scripts/fetch-tools.sh" >&2 || true
    local_bin="$(toolroot_bin "$bin")"
  fi
  if [ -n "$local_bin" ]; then
    PATH="${ROOT_DIR}/.tools/root/usr/bin:${PATH}" \
    LD_LIBRARY_PATH="${ROOT_DIR}/.tools/root/usr/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
      "$local_bin" "$@"
    return
  fi

  in_tools "$bin" "$@"
}
