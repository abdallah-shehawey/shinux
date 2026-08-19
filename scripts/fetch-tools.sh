#!/usr/bin/env bash
# Fetch createrepo_c and rpmsign into a project-local prefix, without root.
#
# Fedora does not install either by default and `dnf install` needs sudo, so
# the packages are downloaded (dnf download does not need root) and unpacked
# into .tools/root. They are a few hundred kilobytes in total, which matters on
# a slow link where pulling a container image is not an option.
set -euo pipefail
source "$(dirname "$0")/config.sh"

TOOLROOT="${ROOT_DIR}/.tools/root"
PKGDIR="${ROOT_DIR}/.tools/pkgs"
NEEDED_RPMS="createrepo_c createrepo_c-libs drpm rpm-sign dpkg"

command -v dnf >/dev/null 2>&1 || die "fetch-tools.sh needs dnf (Fedora/RHEL host)"
command -v rpm2cpio >/dev/null 2>&1 || die "fetch-tools.sh needs rpm2cpio"
command -v cpio >/dev/null 2>&1 || die "fetch-tools.sh needs cpio"

mkdir -p "${PKGDIR}" "${TOOLROOT}"
info "downloading ${NEEDED_RPMS} into .tools/pkgs (no root required)"
dnf download --nogpgcheck --destdir "${PKGDIR}" --arch "$(uname -m)" ${NEEDED_RPMS} >/dev/null

info "unpacking into .tools/root"
for f in "${PKGDIR}"/*.rpm; do
  ( cd "${TOOLROOT}" && rpm2cpio "$f" | cpio -idmu --quiet )
done

PATH="${TOOLROOT}/usr/bin:${PATH}" LD_LIBRARY_PATH="${TOOLROOT}/usr/lib64" \
  createrepo_c --version >/dev/null || die "createrepo_c still does not run; missing a dependency"
info "tools ready in .tools/root"
