#!/usr/bin/env bash
# Publish build/out into docs/ and regenerate + sign all repository metadata.
#
# docs/ is what GitHub Pages serves, and it is no longer in git: pool-fetch.sh
# restores the published packages from the release assets before this runs, and
# the tree it produces is uploaded as the Pages artifact. This script only ever
# adds to the pool -- old versions have to survive for `dnf downgrade`, version
# pinning, and clients that have not upgraded yet.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-tools.sh"
source "$(dirname "$0")/lib-pool.sh"

[ -d "${BUILD_DIR}/out" ] || die "nothing built; run scripts/build.sh first"

# The release packages bake BASE_URL in at build time, so publishing artefacts
# that were built for a different URL ships a .repo pointing somewhere else.
# That is exactly what a leftover test build does, and it is silent, so check.
release_rpm="$(ls -1 "${BUILD_DIR}/out/rpm/${REPO_ID}-release-"*.rpm 2>/dev/null || true)"
release_rpm="$(printf '%s\n' "${release_rpm}" | sort -V | tail -1)"
if [ -n "${release_rpm}" ]; then
  built_url="$(rpm2cpio "${release_rpm}" 2>/dev/null \
                | cpio -i --to-stdout --quiet "./etc/yum.repos.d/${REPO_ID}.repo" 2>/dev/null \
                | awk -F= '/^baseurl=/ { print $2; exit }')"
  case "${built_url}" in
    "${BASE_URL}/rpm/") ;;
    "") ;;   # older build without the source repo stanza; let it through
    *) die "build/out was built for ${built_url%/rpm/}, not ${BASE_URL} - run scripts/build.sh again" ;;
  esac
fi

export GNUPGHOME="${SIGN_GNUPGHOME:-${GNUPGHOME_DIR}}"
FPR="$(gpg_fpr || true)"
[ -n "${FPR}" ] || die "no signing key; run scripts/gpg-setup.sh first"
info "signing with ${FPR}"

mkdir -p "${RPM_DIR}" "${DEB_DIR}/pool/${DEB_COMPONENT}" "${ARCH_DIR}"
touch "${OUT_DIR}/.nojekyll"

# Not committed any more, so every tree this writes has to carry its own copy.
"${ROOT_DIR}/scripts/export-key.sh"

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

arch_content_id() {
  # These archives are already byte-reproducible -- mtimes pinned to the epoch,
  # members sorted, owner 0 -- so the only field that moves on its own is
  # .PKGINFO's builddate, which follows the package directory's last commit and
  # says nothing about what ships. Same exclusion as rpm_content_id makes for
  # BUILDTIME. size is derived from the payload and comes with it.
  { tar --use-compress-program=unzstd -xOf "$1" .PKGINFO | grep -Ev '^(builddate|size) ='
    tar --use-compress-program=unzstd -tvf "$1" | grep -v '\.PKGINFO$'
    tar --use-compress-program=unzstd -xOf "$1" --exclude=.PKGINFO
  } 2>/dev/null | sha256sum | cut -d' ' -f1
}

# A package whose name is already an asset in the pool is frozen. GitHub cannot
# replace a release asset in place -- deleting and re-uploading is the one way,
# and it takes the download count with it, which is why pool-assets.sh is
# add-only. Overwriting the copy in docs/ anyway would leave the metadata
# describing bytes no client can fetch: dnf and pacman both verify the checksum
# the index gives them against the file they downloaded from the release, and
# every install of that package would fail on it. So the published bytes win
# and the change waits for the bump the warning already asks for.
keep_published() {
  [ "${ASSET_POOL}" = "1" ] || return 1
  printf '         keeping the published copy; a release asset cannot be replaced.\n' >&2
  return 0
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
    keep_published && continue
  fi
  cp -f "$f" "$dest"
  info "signing $(basename "$f")"
  tool rpmsign --define "_gpg_name ${FPR}" --addsign "$dest" >/dev/null
done

# A fresh clone gives every rpm the checkout time as its mtime, and
# createrepo_c writes that into primary.xml. Pin each file's mtime to the
# BUILDTIME recorded inside it so the metadata is identical on any machine.
for f in "${RPM_DIR}"/*.rpm; do
  bt="$(rpm -qp --qf '%{BUILDTIME}' "$f" 2>/dev/null)" || continue
  [ -n "$bt" ] && touch -d "@${bt}" "$f"
done

repomd="${RPM_DIR}/repodata/repomd.xml"
before_md="$(sha256sum "${repomd}" 2>/dev/null | cut -d' ' -f1 || true)"

info "createrepo_c ${RPM_DIR#"${ROOT_DIR}/"}"
# gzip rather than the zstd default: zstd metadata is unreadable to yum on
# CentOS 7 and older RHEL, and the size difference here is irrelevant.
createrepo_args=(--quiet --update --no-database --general-compress-type=gz)

# --baseurl writes xml:base on every <location>, which is what sends dnf to the
# release assets for the package while it keeps reading the metadata from
# Pages. It applies to entries --update reuses as well, not only to newly
# scanned files, so the whole pool moves at once and no second pass is needed.
# The rpms are still published to Pages as well. They cost nothing in git now,
# and dropping them would 404 for anyone whose cached metadata still points
# there -- for as long as the .repo file's metadata_expire=6h -- and would
# break `dnf install <url>` for a link copied off the site.
if [ "${ASSET_POOL}" = "1" ]; then
  info "packages will be served from ${ASSET_BASE}/"
  createrepo_args+=(--baseurl "${ASSET_BASE}/")
fi

tool createrepo_c "${createrepo_args[@]}" "${RPM_DIR}"

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
  name="$(basename "$f")"
  # deb_pool_path() is shared with pool-fetch.sh: a package restored from the
  # release has to land on the path Packages already advertises for it.
  dest="$(deb_pool_path "${name}")"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    if [ "$(deb_content_id "$f")" = "$(deb_content_id "$dest")" ]; then
      continue
    fi
    printf '\033[33mwarning:\033[0m %s changed but its version did not; clients that already\n' "$name" >&2
    printf '         cached it will never see the change. Run: make bump PKG=<name>\n' >&2
    stale_warning=1
    keep_published && continue
  fi
  cp -f "$f" "$dest"
done

dists="${DEB_DIR}/dists/${DEB_SUITE}"
before="$(sha256sum "${dists}/Release" 2>/dev/null | cut -d' ' -f1 || true)"

apt_args=(--root "${DEB_DIR}" --suite "${DEB_SUITE}" --component "${DEB_COMPONENT}"
          --archs "${DEB_ARCHS}" --origin "${REPO_ID}" --label "${REPO_NAME}"
          --description "${REPO_NAME} for Debian and Ubuntu")

# The same index a second time, flattened, for the release assets. apt cannot
# be pointed at the packages the way dnf can -- there is no xml:base for a
# Filename -- so the whole index moves instead, and a flat repository is the
# one layout whose every path is a legal asset name. The dists/ tree above is
# untouched and still served from Pages for clients added before this.
if [ "${ASSET_POOL}" = "1" ]; then
  rm -rf "${POOL_META_DIR}"
  apt_args+=(--flat-out "${POOL_META_DIR}" --flat-prefix "${POOL_TAG}")
fi

python3 "${ROOT_DIR}/scripts/gen-apt-metadata.py" "${apt_args[@]}"

after="$(sha256sum "${dists}/Release" | cut -d' ' -f1)"
if [ "${before}" != "${after}" ] || [ ! -f "${dists}/InRelease" ] || [ ! -f "${dists}/Release.gpg" ]; then
  info "signing the apt Release file"
  rm -f "${dists}/Release.gpg" "${dists}/InRelease"
  gpg --batch --yes --detach-sign --armor --local-user "${FPR}" \
      -o "${dists}/Release.gpg" "${dists}/Release"
  gpg --batch --yes --clearsign --local-user "${FPR}" \
      -o "${dists}/InRelease" "${dists}/Release"
fi

# A stable, short path for the keyring package, so adding the repository on a
# deb system is one command instead of four. The pool path carries the version
# and the pool layout, which makes for a URL nobody can type.
# find, not `ls -1 <glob>`: nullglob is on from the rpm side up, so an
# unmatched glob leaves ls with no arguments at all and it lists the current
# directory instead of failing. That put a source-tree directory name in
# $keyring and cp died on it -- and with a file there rather than a directory
# it would have quietly published something else as the keyring.
keyring="$(find "${DEB_DIR}/pool/${DEB_COMPONENT}" -mindepth 3 -maxdepth 3 -type f \
             -path "*/${REPO_ID}-archive-keyring/*.deb" 2>/dev/null | sort -V | tail -1)"
if [ -n "${keyring}" ]; then
  cp -f "${keyring}" "${OUT_DIR}/${REPO_ID}-keyring.deb"
fi

# --------------------------------------------------------------- Arch side --
# Arch packages are self-contained signed-by-file artifacts; pacman verifies
# their internal integrity when installing a local file. Keep every version so
# users can download an exact build or use the latest release asset.
for f in "${BUILD_DIR}/out/arch"/*.pkg.tar.zst; do
  name="$(basename "$f")"
  dest="${ARCH_DIR}/${name}"
  # cmp alone used to decide this, which is stricter than the rpm and deb sides
  # and says nothing when it fails: any change to what build_arch writes into
  # .PKGINFO -- a dependency, a backup= line -- silently rewrote a package that
  # was already published under that exact name.
  if [ -f "$dest" ]; then
    cmp -s "$f" "$dest" && continue
    if [ "$(arch_content_id "$f")" = "$(arch_content_id "$dest")" ]; then
      continue
    fi
    printf '\033[33mwarning:\033[0m %s changed but its version did not; clients that already\n' "$name" >&2
    printf '         cached it will never see the change. Run: make bump PKG=<name>\n' >&2
    stale_warning=1
    keep_published && continue
  fi
  cp -f "$f" "$dest"
  info "published ${name}"
done

# Stable aliases make the terminal installer independent of package versions.
for meta in "${ROOT_DIR}"/packages/*/metadata.env; do
  [ -f "$meta" ] || continue
  unset PKG_NAME
  # shellcheck disable=SC1090
  source "$meta"
  latest="$(find "${ARCH_DIR}" -maxdepth 1 -type f -name "${PKG_NAME}-[0-9]*.pkg.tar.zst" -printf '%f\n' | sort -V | tail -1)"
  [ -n "$latest" ] || continue
  # A copy under an unversioned name, so a package can be installed with
  # `pacman -U <url>` without adding the repository. It is a convenience and it
  # is a second copy of the file, which is nothing for a shell script and 94 MB
  # for one that bundles a browser engine -- and this site is served from a
  # git repository. Past a few megabytes the versioned file and the database
  # are the only ways in.
  size="$(stat -c%s "${ARCH_DIR}/${latest}")"
  if [ "$size" -gt 8388608 ]; then
    rm -f "${ARCH_DIR}/${PKG_NAME}.pkg.tar.zst" "${ARCH_DIR}/${PKG_NAME}.pkg.tar.zst.sig"
    continue
  fi
  cp -f "${ARCH_DIR}/${latest}" "${ARCH_DIR}/${PKG_NAME}.pkg.tar.zst"
done

python3 "${ROOT_DIR}/scripts/gen-pacman-repo.py" \
  --arch-dir "${ARCH_DIR}" --repo-id "${REPO_ID}" --key-id "${FPR}"

# ------------------------------------------------- metadata for the release --
# What apt and pacman have to read from github.com rather than from Pages, so
# that the package they then fetch is an asset GitHub counts. Everything here
# is REPLACED on every publish rather than added to -- it describes the pool as
# it is now -- which is the opposite rule to the packages themselves, and
# pool-assets.sh keeps the two apart by name.
if [ "${ASSET_POOL}" = "1" ]; then
  mkdir -p "${POOL_META_DIR}"

  # Signed exactly like the dists/ one: same key, same two shapes. apt takes
  # InRelease alone, but Release + Release.gpg is what an older client asks for
  # first and a 404 there is a warning on every update.
  info "signing the flat apt Release"
  gpg --batch --yes --detach-sign --armor --local-user "${FPR}" \
      -o "${POOL_META_DIR}/Release.gpg" "${POOL_META_DIR}/Release"
  gpg --batch --yes --clearsign --local-user "${FPR}" \
      -o "${POOL_META_DIR}/InRelease" "${POOL_META_DIR}/Release"

  # pacman needs no new format at all: it already asks for these four names,
  # and for a bare %FILENAME%, off whatever single URL Server points at. Only
  # that URL changes.
  for f in "${REPO_ID}.db" "${REPO_ID}.db.sig" "${REPO_ID}.files" "${REPO_ID}.files.sig"; do
    [ -f "${ARCH_DIR}/${f}" ] || die "gen-pacman-repo.py did not write ${f}"
    cp -f "${ARCH_DIR}/${f}" "${POOL_META_DIR}/${f}"
  done

  info "pool metadata staged in ${POOL_META_DIR#"${ROOT_DIR}/"}"
fi

# ------------------------------------------------------------- landing page --
"${ROOT_DIR}/scripts/gen-site.sh"

if [ "${stale_warning}" -eq 1 ]; then
  printf '\033[33m==>\033[0m docs/ rebuilt, but see the version warnings above\n'
else
  info "docs/ is ready to commit and push"
fi
