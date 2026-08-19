#!/usr/bin/env bash
# Publish build/out into docs/ and regenerate + sign all repository metadata.
#
# docs/ is what GitHub Pages serves, and it is committed: old package versions
# have to survive, so this script only ever adds to the pool.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-tools.sh"

[ -d "${BUILD_DIR}/out" ] || die "nothing built; run scripts/build.sh first"

export GNUPGHOME="${SIGN_GNUPGHOME:-${GNUPGHOME_DIR}}"
FPR="$(gpg_fpr || true)"
[ -n "${FPR}" ] || die "no signing key; run scripts/gpg-setup.sh first"
info "signing with ${FPR}"

mkdir -p "${RPM_DIR}" "${DEB_DIR}/pool/${DEB_COMPONENT}"
touch "${OUT_DIR}/.nojekyll"

# A package already in the pool is left byte-for-byte alone: re-signing would
# rewrite it on every run and fill the git history with noise. Identity is the
# header digest, which signing does not change.
rpm_content_id() {
  # Not the header digest: that covers BUILDTIME, so it changes on every
  # rebuild even when nothing about the package did. Fingerprint what actually
  # ships instead -- identity, dependencies, scriptlets and per-file digests.
  rpm -qp --qf \
    '%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}|%{SUMMARY}|%{LICENSE}\n[%{REQUIRENEVRS}\n][%{PROVIDENEVRS}\n][%{CONFLICTNEVRS}\n][%{OBSOLETENEVRS}\n]%{PREIN}%{POSTIN}%{PREUN}%{POSTUN}\n[%{FILENAMES}|%{FILEDIGESTS}|%{FILEMODES:octal}|%{FILEFLAGS:fflags}|%{FILELINKTOS}|%{FILEUSERNAME}|%{FILEGROUPNAME}\n]' \
    "$1" 2>/dev/null | sha256sum | cut -d' ' -f1
}

deb_content_id() {
  # Deliberately ignores mtimes: the generated packages are rebuilt from
  # scratch every run, so only the control fields and the per-file checksums
  # can say whether anything really changed.
  { dpkg-deb -f "$1"
    dpkg-deb -c "$1" | awk '{print $1, $NF}'
    dpkg-deb --ctrl-tarfile "$1" | tar -xO ./md5sums 2>/dev/null
  } | sha256sum | cut -d' ' -f1
}

stale_warning=0

# --------------------------------------------------------------- RPM side ----
shopt -s nullglob
for f in "${BUILD_DIR}/out/rpm"/*.rpm; do
  dest="${RPM_DIR}/$(basename "$f")"
  if [ -f "$dest" ]; then
    if [ "$(rpm_content_id "$f")" = "$(rpm_content_id "$dest")" ]; then
      continue
    fi
    printf '\033[33mwarning:\033[0m %s changed but its version did not; clients that already\n' "$(basename "$f")" >&2
    printf '         cached it will never see the change. Run: make bump PKG=<name>\n' >&2
    stale_warning=1
  fi
  cp -f "$f" "$dest"
  info "signing $(basename "$f")"
  tool rpmsign --define "_gpg_name ${FPR}" --addsign "$dest" >/dev/null
done

repomd="${RPM_DIR}/repodata/repomd.xml"
before_md="$(sha256sum "${repomd}" 2>/dev/null | cut -d' ' -f1 || true)"

info "createrepo_c ${RPM_DIR#"${ROOT_DIR}/"}"
# gzip rather than the zstd default: zstd metadata is unreadable to yum on
# CentOS 7 and older RHEL, and the size difference here is irrelevant.
tool createrepo_c --quiet --update --no-database \
     --general-compress-type=gz "${RPM_DIR}"

# A gpg signature is never byte-identical twice, so re-sign only when the thing
# being signed actually changed.
after_md="$(sha256sum "${repomd}" | cut -d' ' -f1)"
if [ "${before_md}" != "${after_md}" ] || [ ! -f "${repomd}.asc" ]; then
  info "signing repomd.xml"
  rm -f "${repomd}.asc"
  gpg --batch --yes --detach-sign --armor --local-user "${FPR}" -o "${repomd}.asc" "${repomd}"
fi

# --------------------------------------------------------------- DEB side ----
for f in "${BUILD_DIR}/out/deb"/*.deb; do
  name="$(basename "$f")"; pkg="${name%%_*}"
  case "$pkg" in lib*) letter="${pkg:0:4}" ;; *) letter="${pkg:0:1}" ;; esac
  destdir="${DEB_DIR}/pool/${DEB_COMPONENT}/${letter}/${pkg}"
  mkdir -p "$destdir"
  dest="${destdir}/${name}"
  if [ -f "$dest" ]; then
    if [ "$(deb_content_id "$f")" = "$(deb_content_id "$dest")" ]; then
      continue
    fi
    printf '\033[33mwarning:\033[0m %s changed but its version did not; clients that already\n' "$name" >&2
    printf '         cached it will never see the change. Run: make bump PKG=<name>\n' >&2
    stale_warning=1
  fi
  cp -f "$f" "$dest"
done

dists="${DEB_DIR}/dists/${DEB_SUITE}"
before="$(sha256sum "${dists}/Release" 2>/dev/null | cut -d' ' -f1 || true)"

python3 "${ROOT_DIR}/scripts/gen-apt-metadata.py" \
  --root "${DEB_DIR}" --suite "${DEB_SUITE}" --component "${DEB_COMPONENT}" \
  --archs "${DEB_ARCHS}" --origin "${REPO_ID}" --label "${REPO_NAME}" \
  --description "${REPO_NAME} for Debian and Ubuntu"

after="$(sha256sum "${dists}/Release" | cut -d' ' -f1)"
if [ "${before}" != "${after}" ] || [ ! -f "${dists}/InRelease" ] || [ ! -f "${dists}/Release.gpg" ]; then
  info "signing the apt Release file"
  rm -f "${dists}/Release.gpg" "${dists}/InRelease"
  gpg --batch --yes --detach-sign --armor --local-user "${FPR}" \
      -o "${dists}/Release.gpg" "${dists}/Release"
  gpg --batch --yes --clearsign --local-user "${FPR}" \
      -o "${dists}/InRelease" "${dists}/Release"
fi

# ------------------------------------------------------------- landing page --
"${ROOT_DIR}/scripts/gen-site.sh"

if [ "${stale_warning}" -eq 1 ]; then
  printf '\033[33m==>\033[0m docs/ rebuilt, but see the version warnings above\n'
else
  info "docs/ is ready to commit and push"
fi
