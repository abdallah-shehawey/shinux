#!/usr/bin/env bash
# Keep only the newest N versions of every package in the published pool.
#
# Old versions are worth keeping for a while (they make `dnf downgrade` and
# pinned installs work), but the pool is committed to git, so it cannot grow
# without bound. Run this before publish when the repo gets big.
#
#   scripts/prune.sh        keep 3 (default)
#   scripts/prune.sh 1      keep only the newest
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-pool.sh"
keep="${1:-3}"

prune_dir() {
  local dir="$1" pattern="$2" namecmd="$3"
  [ -d "$dir" ] || return 0
  declare -A seen=()
  # Newest first: rpm and dpkg both sort correctly with `sort -V` on the
  # version segment of the filename.
  while IFS= read -r f; do
    local pkg; pkg="$(eval "$namecmd")"
    seen["$pkg"]=$(( ${seen["$pkg"]:-0} + 1 ))
    if [ "${seen["$pkg"]}" -gt "$keep" ]; then
      info "pruning $(basename "$f")"
      rm -f "$f"
    fi
  done < <(find "$dir" -name "$pattern" -printf '%p\n' | sort -Vr)
}

# The arch pool needs a reader of its own: there is no arch equivalent of
# `rpm -qp`, and reading .PKGINFO out of every package would mean decompressing
# the whole pool just to decide what to delete. The name is in the filename,
# and arch_version_name() in lib-pool.sh is where that is read -- shared with
# pool-fetch.sh, which has to keep exactly what this deletes down to.

prune_arch() {
  [ -d "${ARCH_DIR}" ] || return 0
  declare -A seen=()
  while IFS= read -r f; do
    local pkg
    pkg="$(arch_version_name "$f")" || continue
    seen["$pkg"]=$(( ${seen["$pkg"]:-0} + 1 ))
    if [ "${seen["$pkg"]}" -gt "$keep" ]; then
      info "pruning $(basename "$f")"
      # The detached signature goes with it. An orphaned .sig is worse than the
      # package it signed: gen-pacman-repo.py signs only what has no signature
      # yet, so one left behind would survive every rebuild for ever.
      rm -f "$f" "${f}.sig"
    fi
  done < <(find "${ARCH_DIR}" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%p\n' | sort -Vr)
}

prune_dir "${RPM_DIR}" '*.rpm' 'rpm -qp --qf "%{NAME}" "$f" 2>/dev/null'
prune_dir "${DEB_DIR}/pool" '*.deb' 'dpkg-deb -f "$f" Package 2>/dev/null'
prune_arch

info "pruned to the newest ${keep} version(s); run make publish to refresh metadata"
