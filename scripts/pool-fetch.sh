#!/usr/bin/env bash
# Restore the published pool into docs/ from the release assets.
#
# docs/ is not in git any more -- it is assembled here and handed to Pages as
# an artifact -- so a fresh checkout has the metadata generators pointing at an
# empty pool. Left alone, `createrepo_c --update` and gen-apt-metadata.py would
# publish an index of one version: the one this run just built. Every older
# release would vanish from the repository, breaking `dnf downgrade`, version
# pinning, and any apt or pacman client that has not upgraded yet.
#
# Only the newest few versions of each package come back, matching what
# prune.sh keeps, because the Pages artifact has a 1 GB ceiling and one
# whatsapp-desktop version is 270 MB across the three formats. Everything older
# stays in the release, installable by URL.
#
# A file already on disk is never re-downloaded. That is what makes the CI
# cache worth having: with a warm cache this fetches nothing at all, and the
# download counters stay a measure of what real users installed rather than of
# how often the repository rebuilt itself.
#
#   scripts/pool-fetch.sh        restore the newest 4 versions of everything
#   scripts/pool-fetch.sh 2      restore the newest 2
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-pool.sh"

keep="${1:-4}"

if [ -z "${pool_token}" ]; then
  printf '\033[33mwarning:\033[0m no GH_TOKEN or GITHUB_TOKEN; publishing whatever is already in docs/\n' >&2
  exit 0
fi

command -v curl    >/dev/null || die "curl is required to restore the pool"
command -v python3 >/dev/null || die "python3 is required to restore the pool"

release_id="$(pool_release_id)"
if [ -z "${release_id}" ]; then
  info "no ${POOL_TAG} release yet; nothing to restore"
  exit 0
fi

assets="$(pool_assets "${release_id}")"
[ -n "${assets}" ] || { info "the ${POOL_TAG} release is empty; nothing to restore"; exit 0; }

mkdir -p "${RPM_DIR}" "${ARCH_DIR}" "${DEB_DIR}/pool/${DEB_COMPONENT}"

# --------------------------------------------------- pick what to bring back --
# Newest first within each package, so the counter stops at `keep`. Signatures
# are not versions of anything and are decided by the package they sign, below.
wanted=""
declare -A seen=()

while IFS=$'\t' read -r name url; do
  [ -n "${name}" ] || continue
  # Counted per format, not per package: the same version of whatsapp-desktop
  # is an rpm, a deb and an arch package, and one counter for all three would
  # keep four files rather than four versions -- leaving two of the formats
  # with nothing at all in the pool.
  case "${name}" in
    *.rpm)         fmt=rpm ;;
    *.deb)         fmt=deb ;;
    *.pkg.tar.zst) fmt=arch ;;
    *) continue ;;                       # signatures follow their package below
  esac
  pkg="$(asset_package "${name}")" || continue
  key="${fmt}|${pkg}"
  seen["$key"]=$(( ${seen["$key"]:-0} + 1 ))
  [ "${seen["$key"]}" -le "${keep}" ] || continue
  wanted+="${name}"$'\t'"${url}"$'\n'
done < <(printf '%s\n' "${assets}" | sort -Vr)

# The detached signature travels with the package it signs: gen-pacman-repo.py
# signs only what has no signature yet, so a package restored without its .sig
# would be signed again on every publish -- a new signature each time, for a
# file that has not changed.
sigs="$(printf '%s\n' "${assets}" | grep -F '.sig' || true)"
while IFS=$'\t' read -r name url; do
  [ -n "${name}" ] || continue
  case "${name}" in
    *.pkg.tar.zst)
      match="$(printf '%s\n' "${sigs}" | grep -F "${name}.sig"$'\t' || true)"
      [ -n "${match}" ] && wanted+="${match}"$'\n'
      ;;
  esac
done < <(printf '%s' "${wanted}")

# ------------------------------------------------------------- bring it back --
restored=0 present=0
while IFS=$'\t' read -r name url; do
  [ -n "${name}" ] || continue
  dest="$(asset_destination "${name}")" || continue
  if [ -f "${dest}" ]; then present=$(( present + 1 )); continue; fi
  mkdir -p "$(dirname "${dest}")"
  info "restoring ${name}"
  curl --silent --show-error --location --fail --output "${dest}.part" "${url}" \
    || die "could not download ${name}"
  mv -f "${dest}.part" "${dest}"
  restored=$(( restored + 1 ))
done < <(printf '%s' "${wanted}")

info "pool: ${restored} restored, ${present} already on disk"
