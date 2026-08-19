#!/usr/bin/env bash
# Create the repository signing key, or re-export an existing one.
#
# The key lives in a project-local keyring (.gnupg/) that is git-ignored, so it
# never leaves this machine by accident. The public half is exported into docs/
# in both formats package managers expect.
#
# The key is generated WITHOUT a passphrase on purpose: rpm --addsign and the CI
# job both need to sign unattended. Treat .gnupg/ and the exported private key
# as secrets.
set -euo pipefail
source "$(dirname "$0")/config.sh"

mkdir -p "${GNUPGHOME_DIR}"
chmod 700 "${GNUPGHOME_DIR}"
export GNUPGHOME="${GNUPGHOME_DIR}"

if fpr="$(gpg_fpr)"; then
  info "reusing existing key ${fpr}"
else
  info "generating a new 4096-bit RSA signing key for ${GPG_KEY_UID}"
  gpg --batch --quiet --gen-key <<GPGEOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: ${REPO_NAME} Signing Key
Name-Email: ${MAINTAINER_EMAIL}
Expire-Date: 0
%commit
GPGEOF
  fpr="$(gpg_fpr)" || die "key generation reported success but no secret key was found"
  info "created key ${fpr}"
fi

mkdir -p "${OUT_DIR}"
gpg --armor --export "${fpr}" > "${KEY_ASC}"
gpg --export "${fpr}" > "${KEY_GPG}"
info "public key exported to ${KEY_ASC#"${ROOT_DIR}/"} and ${KEY_GPG#"${ROOT_DIR}/"}"

# Private key export, for pasting into the GPG_PRIVATE_KEY GitHub secret.
priv="${ROOT_DIR}/private-key.asc"
if [ ! -f "$priv" ]; then
  gpg --armor --export-secret-keys "${fpr}" > "$priv"
  chmod 600 "$priv"
  cat <<MSG

  Private key written to: ${priv}
  1. Copy its whole contents into a GitHub secret named GPG_PRIVATE_KEY
     (Settings -> Secrets and variables -> Actions -> New repository secret).
  2. Then delete the file. It is git-ignored, but do not leave it lying around.
  3. Back up ${GNUPGHOME_DIR} somewhere safe: losing it means every existing
     user has to re-trust a brand new key.

MSG
fi

echo "${fpr}" > "${ROOT_DIR}/.gpg-fingerprint"
