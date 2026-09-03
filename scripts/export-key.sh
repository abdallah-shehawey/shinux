#!/usr/bin/env bash
# Write the repository's public key into docs/, in both forms clients need.
#
# It used to sit in git next to the packages. docs/ is assembled from scratch
# on every publish now, and the publish job imports the private key from a
# secret into a throwaway GNUPGHOME, so the public half has to be written out
# of that keyring rather than checked out. gpg exports a given key
# byte-for-byte the same every time, so re-running this changes nothing.
#
# Ordering matters: gen-release-packages.sh copies both files into the
# configuration packages, and it runs from build.sh, before make-repo.sh.
set -euo pipefail
source "$(dirname "$0")/config.sh"

export GNUPGHOME="${SIGN_GNUPGHOME:-${GNUPGHOME_DIR}}"
fpr="$(gpg_fpr || true)"
[ -n "${fpr}" ] || die "no signing key; run scripts/gpg-setup.sh first"

mkdir -p "${OUT_DIR}"
gpg --batch --yes --armor --export "${fpr}" > "${KEY_ASC}"   # armored, for rpm --import
gpg --batch --yes         --export "${fpr}" > "${KEY_GPG}"   # dearmored, for apt Signed-By
chmod 0644 "${KEY_ASC}" "${KEY_GPG}"
