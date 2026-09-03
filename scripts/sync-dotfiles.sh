#!/usr/bin/env bash
# Copy the packaged commands into the dotfiles checkout.
#
#   scripts/sync-dotfiles.sh [path-to-dotfiles-linux]
#
# The packages are the source of truth; the dotfiles copy is a mirror kept for
# machines that do not add the repository. Sources carry @VERSION@ placeholders
# that only the build expands, so substitute them here too -- otherwise the
# mirrored script reports "padnum @VERSION@" for --version.
set -euo pipefail
source "$(dirname "$0")/config.sh"

DOTFILES="${1:-/media/Local-Disk2/Embedded_Linux/dotfiles-linux}"
dest="${DOTFILES}/scripts"
[ -d "$dest" ] || die "no scripts/ under ${DOTFILES}"

for pkgdir in "${ROOT_DIR}"/packages/*/; do
  name="$(basename "$pkgdir")"
  bin="${pkgdir}src/usr/bin/${name}"
  [ -f "$bin" ] || continue   # metapackages ship no command
  # hello-shinux only exists to prove the repository works; it is not one of
  # the personal scripts the dotfiles carry.
  if [ "$name" = "hello-${REPO_ID}" ]; then continue; fi

  # shellcheck disable=SC1091
  ( source "${pkgdir}metadata.env"
    # Match whatever name the mirror already uses, so a copy that predates the
    # packaging (antigravity-update.sh) is updated rather than duplicated.
    out="${dest}/${name}"
    [ -f "$out" ] || { [ -f "${out}.sh" ] && out="${out}.sh"; } || true

    tmp="$(mktemp)"
    sed -e "s|@VERSION@|${PKG_VERSION}|g" \
        -e "s|@RELEASE@|${PKG_RELEASE}|g" \
        -e "s|@BASE_URL@|${BASE_URL}|g" \
        -e "s|@REPO_ID@|${REPO_ID}|g" \
        -e "s|@REPO_NAME@|${REPO_NAME}|g" \
        -e "s|@MAINTAINER@|${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>|g" \
        "$bin" > "$tmp"

    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
      rm -f "$tmp"
    else
      install -m 0755 "$tmp" "$out"
      rm -f "$tmp"
      echo "  updated $(basename "$out") -> ${PKG_VERSION}"
    fi )
done

info "dotfiles mirror in sync (${dest})"
