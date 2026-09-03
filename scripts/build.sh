#!/usr/bin/env bash
# Build every package in packages/ plus the generated repo-configuration
# packages, into build/out/{rpm,deb,arch}.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-tools.sh"
source "$(dirname "$0")/lib-pkg.sh"

rm -rf "${BUILD_DIR}/out"
mkdir -p "${BUILD_DIR}/out"/{rpm,deb,arch}

# The configuration packages embed the public key, and it is no longer a
# committed file -- write it out of the signing keyring first.
"${ROOT_DIR}/scripts/export-key.sh"

"${ROOT_DIR}/scripts/gen-release-packages.sh"

shopt -s nullglob
for pkgdir in "${ROOT_DIR}/packages"/*/ "${BUILD_DIR}/generated"/*/; do
  [ -f "${pkgdir}/metadata.env" ] || continue
  ( # subshell so one package's metadata cannot leak into the next
    PKG_FORMATS="rpm deb"
    # shellcheck disable=SC1091
    source "${pkgdir}/metadata.env"

    # A src/ that is generated rather than committed is absent from every
    # checkout but the publishing machine's -- CI included. Building anyway
    # produces a package holding nothing but its README, and make-repo.sh
    # copies that straight over the good one already in docs/.
    if [ -n "${PKG_SRC_GENERATED:-}" ] &&
       [ -z "$(find "${pkgdir}src" -type f -print -quit 2>/dev/null)" ]; then
      printf '\033[33m==>\033[0m skipping %s: src/ is empty, run %s to stage it\n' \
        "${PKG_NAME}" "${PKG_SRC_GENERATED}" >&2
      exit 0   # the subshell only; the other packages still build
    fi
    for fmt in ${PKG_FORMATS}; do
      case "$fmt" in
        rpm) build_rpm "${pkgdir%/}" ;;
        deb)  build_deb "${pkgdir%/}" ;;
        arch) build_arch "${pkgdir%/}" ;;
        *)    die "unknown format '${fmt}' in ${pkgdir}metadata.env" ;;
      esac
    done
  )
done

info "built:"
find "${BUILD_DIR}/out" -type f \( -name '*.rpm' -o -name '*.deb' -o -name '*.pkg.tar.zst' \) -printf '    %P\n' | sort
