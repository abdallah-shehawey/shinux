#!/usr/bin/env bash
# Raise a package's version so subscribers see it as an upgrade.
#
#   scripts/bump.sh hello-shinux            -> 1.0.0-1  becomes 1.0.0-2
#   scripts/bump.sh hello-shinux patch      -> 1.0.0-1  becomes 1.0.1-1
#   scripts/bump.sh hello-shinux minor      -> 1.0.1-2  becomes 1.1.0-1
#   scripts/bump.sh hello-shinux major      -> 1.1.0-1  becomes 2.0.0-1
#   scripts/bump.sh hello-shinux 2.4.0      -> exactly 2.4.0-1
#
# Bump the release (default) when only the packaging changed; bump the version
# when the program itself changed. Both dnf and apt order these the same way,
# so either is enough to trigger an upgrade.
set -euo pipefail
source "$(dirname "$0")/config.sh"

name="${1:-}"; what="${2:-release}"
[ -n "$name" ] || die "usage: $0 <package> [release|patch|minor|major|<version>]"

meta="${ROOT_DIR}/packages/${name}/metadata.env"
[ -f "$meta" ] || die "no such package: packages/${name}"

# shellcheck disable=SC1091
source "$meta"
old="${PKG_VERSION}-${PKG_RELEASE}"
IFS=. read -r maj min pat <<< "${PKG_VERSION}"
maj="${maj:-0}"; min="${min:-0}"; pat="${pat:-0}"

case "$what" in
  release) new_ver="${PKG_VERSION}";           new_rel="$(( PKG_RELEASE + 1 ))" ;;
  patch)   new_ver="${maj}.${min}.$((pat+1))"; new_rel=1 ;;
  minor)   new_ver="${maj}.$((min+1)).0";      new_rel=1 ;;
  major)   new_ver="$((maj+1)).0.0";           new_rel=1 ;;
  *)       new_ver="$what";                    new_rel=1 ;;
esac

sed -i -e "s/^PKG_VERSION=.*/PKG_VERSION=\"${new_ver}\"/" \
       -e "s/^PKG_RELEASE=.*/PKG_RELEASE=\"${new_rel}\"/" "$meta"

info "${name}: ${old} -> ${new_ver}-${new_rel}"
echo "    next: make publish   (build + sign + regenerate metadata)"
