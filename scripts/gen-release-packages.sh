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

# repo_gpgcheck=0 is deliberate, and it is what Fedora, RPM Fusion, EPEL and
# every COPR ship. It does NOT mean packages go unverified: gpgcheck=1 still
# checks the signature on every rpm, which is the part that carries code.
# repo_gpgcheck only covers repomd.xml, and turning it on costs two things
# that matter more here than the metadata signature does:
#   * dnf keeps its repo keyring per cache directory, and an unprivileged dnf
#     uses ~/.cache/libdnf5 — where the key has never been imported. Shell
#     completion runs dnf as your own user, so `dnf install <TAB>` silently
#     drops this repo and never offers its packages.
#   * the first transaction stops on an interactive "Is this ok [y/N]" prompt.
# The metadata is still signed and repomd.xml.asc is still published, so
# anyone who wants the stricter check can set repo_gpgcheck=1 themselves.
cat > "${rel}/src/etc/yum.repos.d/${REPO_ID}.repo" <<REPOEOF
[${REPO_ID}]
name=${REPO_NAME}
baseurl=${BASE_URL}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}
metadata_expire=6h
skip_if_unavailable=False
countme=0

[${REPO_ID}-source]
name=${REPO_NAME} - Source
baseurl=${BASE_URL}/srpm/
enabled=0
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}
REPOEOF

cp "${KEY_ASC}" "${rel}/src/etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}"
chmod 0644 "${rel}/src/etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}" \
           "${rel}/src/etc/yum.repos.d/${REPO_ID}.repo"

# The package deliberately does NOT run `rpm --import` from a scriptlet. It was
# tried: rpm holds its database open for the whole transaction, so a nested
# `rpm --import` fails from %post and from %posttrans alike, and fails quietly.
# Trusting the key is therefore something the *installer* does, before this
# package is fetched -- which is what install.sh and the documented by-hand
# commands do, and what every vendor repository does. dnf's own one-time
# "Is this ok [y/N]" prompt stays as the fallback for anyone who skips it.
#
# The sed below is a one-off migration away from the old repo_gpgcheck=1
# default, not configuration. %config(noreplace) already updates the file for
# anyone who never edited it; this covers the rest, who would otherwise keep a
# setting that breaks shell completion, and get a .rpmnew nobody reads.
mkdir -p "${rel}/rpm"
cat > "${rel}/rpm/posttrans" <<POSTEOF
repo=/etc/yum.repos.d/${REPO_ID}.repo
if [ -f "\$repo" ] && grep -q '^repo_gpgcheck=1' "\$repo"; then
  sed -i 's/^repo_gpgcheck=1/repo_gpgcheck=0/' "\$repo" || :
  rm -f "\$repo.rpmnew"
  echo "${REPO_NAME}: repo_gpgcheck turned off, so shell completion can read the repository"
fi
exit 0
POSTEOF

cat > "${rel}/metadata.env" <<METAEOF
PKG_NAME="${REPO_ID}-release"
PKG_VERSION="1.2"
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

# A flat repository on the release, not the dists/ tree on Pages. Pages
# publishes no statistics, so every `apt install` from here used to be a
# download nobody could see; a release asset is counted. apt has no xml:base to
# redirect just the packages with, so the index moves too -- and `Suites:` with
# a trailing slash and no `Components:` is what tells apt to read
# <URIs>/<Suites>/{InRelease,Packages} and to resolve each Filename against the
# same directory. Every name involved is slash-free, which is the only kind a
# release asset can have.
#
# Architectures is left out deliberately: one flat index carries every
# architecture, each stanza labelled with its own, and apt already filters on
# what dpkg says the machine is.
#
# The dists/ tree stays on Pages and keeps working, so a machine that has not
# upgraded this package yet is not affected.
cat > "${key}/src/etc/apt/sources.list.d/${REPO_ID}.sources" <<SRCEOF
Types: deb
URIs: ${ASSET_ROOT}
Suites: ${POOL_TAG}/
Signed-By: /etc/apt/keyrings/${REPO_ID}.gpg
SRCEOF
chmod 0644 "${key}/src/etc/apt/sources.list.d/${REPO_ID}.sources"

cat > "${key}/metadata.env" <<METAEOF
PKG_NAME="${REPO_ID}-archive-keyring"
# 1.2 moves the sources file onto the release. Without the bump apt would never
# offer it and no existing machine would ever change where it downloads from --
# the same trap the rename hit at 1.1.
PKG_VERSION="1.2"
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
