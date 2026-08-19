#!/usr/bin/env bash
# Build every package in packages/ plus the generated repo-configuration
# packages, into build/out/{rpm,deb}.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-tools.sh"
source "$(dirname "$0")/lib-pkg.sh"

rm -rf "${BUILD_DIR}/out"
mkdir -p "${BUILD_DIR}/out"/{rpm,deb}

"${ROOT_DIR}/scripts/gen-release-packages.sh"

shopt -s nullglob
for pkgdir in "${ROOT_DIR}/packages"/*/ "${BUILD_DIR}/generated"/*/; do
  [ -f "${pkgdir}/metadata.env" ] || continue
  ( # subshell so one package's metadata cannot leak into the next
    PKG_FORMATS="rpm deb"
    # shellcheck disable=SC1091
    source "${pkgdir}/metadata.env"
    for fmt in ${PKG_FORMATS}; do
      case "$fmt" in
        rpm) build_rpm "${pkgdir%/}" ;;
        deb) build_deb "${pkgdir%/}" ;;
        *)   die "unknown format '${fmt}' in ${pkgdir}metadata.env" ;;
      esac
    done
  )
done

info "built:"
find "${BUILD_DIR}/out" -type f \( -name '*.rpm' -o -name '*.deb' \) -printf '    %P\n' | sort
