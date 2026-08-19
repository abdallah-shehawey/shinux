#!/usr/bin/env bash
# Materialise the two "add the repository" packages under build/generated.
#
#   <id>-release            (RPM) -> /etc/yum.repos.d/<id>.repo + the GPG key
#   <id>-archive-keyring    (DEB) -> /etc/apt/sources.list.d/<id>.sources + key
#
# They are generated rather than checked in because every field in them comes
# from scripts/config.sh, and the key material comes from docs/.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[ -f "${KEY_ASC}" ] || die "missing ${KEY_ASC}; run scripts/gpg-setup.sh first"
[ -f "${KEY_GPG}" ] || die "missing ${KEY_GPG}; run scripts/gpg-setup.sh first"

GEN="${BUILD_DIR}/generated"
rm -rf "${GEN}"

# ------------------------------------------------------------- RPM release ---
rel="${GEN}/${REPO_ID}-release"
mkdir -p "${rel}/src/etc/yum.repos.d" "${rel}/src/etc/pki/rpm-gpg"

cat > "${rel}/src/etc/yum.repos.d/${REPO_ID}.repo" <<REPOEOF
[${REPO_ID}]
name=${REPO_NAME}
baseurl=${BASE_URL}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}
metadata_expire=6h
skip_if_unavailable=False
countme=0

[${REPO_ID}-source]
name=${REPO_NAME} - Source
baseurl=${BASE_URL}/srpm/
enabled=0
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}
REPOEOF

cp "${KEY_ASC}" "${rel}/src/etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}"
chmod 0644 "${rel}/src/etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}" \
           "${rel}/src/etc/yum.repos.d/${REPO_ID}.repo"

cat > "${rel}/metadata.env" <<METAEOF
PKG_NAME="${REPO_ID}-release"
PKG_VERSION="1.0"
PKG_RELEASE="1"
PKG_FORMATS="rpm"
PKG_SUMMARY="${REPO_NAME} configuration and GPG key"
PKG_DESCRIPTION="Installs the dnf/yum repository definition for the ${REPO_NAME} together with the public GPG key used to sign its packages and metadata. Install this once, then packages from the repository resolve like any other."
PKG_LICENSE="MIT"
PKG_SECTION="misc"
RPM_ARCH="noarch"
DEB_ARCH="all"
RPM_REQUIRES=""
METAEOF

# ---------------------------------------------------------- DEB keyring ------
key="${GEN}/${REPO_ID}-archive-keyring"
mkdir -p "${key}/src/etc/apt/keyrings" "${key}/src/etc/apt/sources.list.d"

cp "${KEY_GPG}" "${key}/src/etc/apt/keyrings/${REPO_ID}.gpg"
chmod 0644 "${key}/src/etc/apt/keyrings/${REPO_ID}.gpg"

cat > "${key}/src/etc/apt/sources.list.d/${REPO_ID}.sources" <<SRCEOF
Types: deb
URIs: ${BASE_URL}/deb
Suites: ${DEB_SUITE}
Components: ${DEB_COMPONENT}
Architectures: ${DEB_ARCHS}
Signed-By: /etc/apt/keyrings/${REPO_ID}.gpg
SRCEOF
chmod 0644 "${key}/src/etc/apt/sources.list.d/${REPO_ID}.sources"

cat > "${key}/metadata.env" <<METAEOF
PKG_NAME="${REPO_ID}-archive-keyring"
PKG_VERSION="1.0"
PKG_RELEASE="1"
PKG_FORMATS="deb"
PKG_SUMMARY="${REPO_NAME} apt sources and signing key"
PKG_DESCRIPTION="Installs the apt sources entry for the ${REPO_NAME} together with the public GPG key used to sign its Release file. Install this once, then packages from the repository resolve like any other."
PKG_LICENSE="MIT"
PKG_SECTION="misc"
RPM_ARCH="noarch"
DEB_ARCH="all"
DEB_DEPENDS="gnupg | gpgv"
METAEOF

# apt only re-reads sources on update; nudge the admin rather than doing it for them.
mkdir -p "${key}/debian"
cat > "${key}/debian/postinst" <<'POSTEOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
  echo "The repository has been added. Run 'sudo apt update' to fetch its package list."
fi
exit 0
POSTEOF
chmod 0755 "${key}/debian/postinst"

info "generated ${REPO_ID}-release (rpm) and ${REPO_ID}-archive-keyring (deb)"
