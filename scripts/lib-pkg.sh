#!/usr/bin/env bash
# Generic RPM + DEB builders.
#
# A package is a directory containing:
#   metadata.env   - name/version/summary/deps, see packages/hello-shinux
#   src/           - a filesystem tree rooted at / (src/usr/bin/foo -> /usr/bin/foo)
#   rpm/           - optional scriptlet bodies: pre post preun postun posttrans
#   debian/        - optional maintainer scripts: preinst postinst prerm postrm
#   LICENSE        - optional
#   README.md      - optional
#
# Both builders consume the same staged tree, so the two package formats can
# never drift apart in file layout.

# Directories that belong to the base distribution: a package must not claim
# ownership of them, only of what it puts inside.
SYSTEM_DIRS="
/etc /etc/apt /etc/apt/keyrings /etc/apt/sources.list.d /etc/apt/trusted.gpg.d
/etc/yum.repos.d /etc/pki /etc/pki/rpm-gpg /etc/profile.d /etc/xdg
/usr /usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/libexec /usr/include
/usr/share /usr/share/applications /usr/share/bash-completion
/usr/share/bash-completion/completions /usr/share/doc /usr/share/icons
/usr/share/licenses /usr/share/man /usr/share/man/man1 /usr/share/man/man2
/usr/share/man/man3 /usr/share/man/man4 /usr/share/man/man5 /usr/share/man/man6
/usr/share/man/man7 /usr/share/man/man8 /usr/share/metainfo /usr/share/pixmaps
/usr/share/polkit-1 /usr/share/zsh /usr/share/zsh/site-functions
/var /var/lib /var/log /opt
"

is_system_dir() {
  local d="$1"
  case " $(echo $SYSTEM_DIRS) " in *" $d "*) return 0 ;; esac
  return 1
}

# stage_package <pkgdir> -> echoes the staged directory
# Copies src/ verbatim and expands @TOKEN@ placeholders in every text file.
stage_package() {
  local pkgdir="$1"
  # shellcheck disable=SC1091
  source "${pkgdir}/metadata.env"
  local stage="${BUILD_DIR}/stage/${PKG_NAME}"
  rm -rf "$stage"
  mkdir -p "$stage"
  # A metapackage ships no files at all, and git cannot track an empty
  # directory, so src/ is allowed to be absent.
  if [ -d "${pkgdir}/src" ]; then
    cp -a "${pkgdir}/src" "$stage/"
  else
    mkdir -p "$stage/src"
  fi
  [ -f "${pkgdir}/LICENSE" ]   && cp "${pkgdir}/LICENSE"   "$stage/"
  [ -f "${pkgdir}/README.md" ] && cp "${pkgdir}/README.md" "$stage/"

  local fpr=""; [ -f "${ROOT_DIR}/.gpg-fingerprint" ] && fpr="$(cat "${ROOT_DIR}/.gpg-fingerprint")"
  while IFS= read -r -d '' f; do
    grep -Iq . "$f" 2>/dev/null || continue   # skip binaries
    sed -i \
      -e "s|@VERSION@|${PKG_VERSION}|g" \
      -e "s|@RELEASE@|${PKG_RELEASE}|g" \
      -e "s|@BASE_URL@|${BASE_URL}|g" \
      -e "s|@REPO_ID@|${REPO_ID}|g" \
      -e "s|@REPO_NAME@|${REPO_NAME}|g" \
      -e "s|@DEB_SUITE@|${DEB_SUITE}|g" \
      -e "s|@DEB_COMPONENT@|${DEB_COMPONENT}|g" \
      -e "s|@KEY_FPR@|${fpr}|g" \
      -e "s|@MAINTAINER@|${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>|g" \
      "$f"
  done < <(find "$stage/src" -type f -print0)

  echo "$stage"
}

# ---------------------------------------------------------------- RPM --------

build_rpm() {
  local pkgdir="$1"
  # shellcheck disable=SC1091
  source "${pkgdir}/metadata.env"
  local stage; stage="$(stage_package "$pkgdir")"

  local top="${BUILD_DIR}/rpmbuild"
  rm -rf "$top"; mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

  # Source tarball, top-level dir named <name>-<version> as %autosetup expects.
  local tarname="${PKG_NAME}-${PKG_VERSION}"
  local tmp="${BUILD_DIR}/tar/${tarname}"
  rm -rf "${BUILD_DIR}/tar"; mkdir -p "$tmp"
  cp -a "$stage/." "$tmp/"
  tar -C "${BUILD_DIR}/tar" -czf "${top}/SOURCES/${tarname}.tar.gz" "${tarname}"

  # %files list, derived from the staged tree.
  local files=""
  while IFS= read -r d; do
    local rel="${d#"$stage/src"}"
    [ -z "$rel" ] && continue
    is_system_dir "$rel" || files+="%dir \"${rel}\"
"
  done < <(find "$stage/src" -type d | LC_ALL=C sort)
  while IFS= read -r f; do
    local rel="${f#"$stage/src"}"
    case "$rel" in
      /etc/pki/*)          files+="\"${rel}\"
" ;;
      /etc/*)              files+="%config(noreplace) \"${rel}\"
" ;;
      /usr/share/man/*)    # rpm compresses man pages itself, so match any
                           # suffix. Unquoted on purpose: quoting a path in
                           # %files turns globbing off, and the glob is the
                           # whole point here.
                           files+="${rel}*
" ;;
      *)                   files+="\"${rel}\"
" ;;
    esac
  done < <(find "$stage/src" \( -type f -o -type l \) | LC_ALL=C sort)

  local lic_line="" doc_line=""
  [ -f "$stage/LICENSE" ]   && lic_line="%license LICENSE"
  [ -f "$stage/README.md" ] && doc_line="%doc README.md"

  local spec="${top}/SPECS/${PKG_NAME}.spec"
  {
    echo "Name:           ${PKG_NAME}"
    echo "Version:        ${PKG_VERSION}"
    echo "Release:        ${PKG_RELEASE}%{?dist}"
    echo "Summary:        ${PKG_SUMMARY}"
    echo "License:        ${PKG_LICENSE}"
    echo "URL:            https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo "Source0:        ${tarname}.tar.gz"
    echo "BuildArch:      ${RPM_ARCH}"
    [ -n "${RPM_REQUIRES:-}" ] && for r in ${RPM_REQUIRES}; do echo "Requires:       $r"; done
    [ -n "${RPM_RECOMMENDS:-}" ] && for r in ${RPM_RECOMMENDS}; do echo "Recommends:     $r"; done
    [ -n "${RPM_SUGGESTS:-}" ] && for r in ${RPM_SUGGESTS}; do echo "Suggests:       $r"; done
    [ -n "${RPM_PROVIDES:-}" ] && for r in ${RPM_PROVIDES}; do echo "Provides:       $r"; done
    [ -n "${RPM_OBSOLETES:-}" ] && for r in ${RPM_OBSOLETES}; do echo "Obsoletes:      $r"; done
    echo
    echo "%description"
    echo "${PKG_DESCRIPTION}" | fold -s -w 78 | sed 's/[[:space:]]*$//'
    echo
    echo "%prep"
    echo "%autosetup"
    echo
    echo "%build"
    echo
    echo "%install"
    echo 'cp -a src/. %{buildroot}/'
    echo

    # Optional scriptlets, copied straight from the package directory — the rpm
    # counterpart of debian/{preinst,postinst,...}. rpm runs the body with
    # /bin/sh and passes the install count as $1, so the files are written that
    # way rather than as standalone executables.
    for sl in pre post preun postun posttrans; do
      [ -f "${pkgdir}/rpm/${sl}" ] || continue
      echo "%${sl}"
      cat "${pkgdir}/rpm/${sl}"
      echo
    done

    echo "%files"
    [ -n "$lic_line" ] && echo "$lic_line"
    [ -n "$doc_line" ] && echo "$doc_line"
    printf '%s' "$files"
    echo
    echo "%changelog"
    echo "* $(LC_ALL=C date '+%a %b %d %Y') ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}> - ${PKG_VERSION}-${PKG_RELEASE}"
    echo "- Built from ${GITHUB_REPO}"
  } > "$spec"

  # One flat repo serves every rpm distribution, so filenames must not carry a
  # distro tag. %{nil} is how rpm spells "define this macro as empty".
  local dist_macro="${RPM_DIST:-%{nil\}}"

  info "rpmbuild ${PKG_NAME}-${PKG_VERSION}-${PKG_RELEASE}"
  tool rpmbuild --define "_topdir ${top}" \
                --define "_build_id_links none" \
                --define "dist ${dist_macro}" \
                -bb "$spec" >"${BUILD_DIR}/rpmbuild-${PKG_NAME}.log" 2>&1 \
    || { tail -40 "${BUILD_DIR}/rpmbuild-${PKG_NAME}.log"; die "rpmbuild failed for ${PKG_NAME}"; }

  mkdir -p "${BUILD_DIR}/out/rpm"
  find "${top}/RPMS" -name '*.rpm' -exec cp -f {} "${BUILD_DIR}/out/rpm/" \;
}

# ---------------------------------------------------------------- DEB --------

build_deb() {
  local pkgdir="$1"
  # shellcheck disable=SC1091
  source "${pkgdir}/metadata.env"
  local stage; stage="$(stage_package "$pkgdir")"

  local work="${BUILD_DIR}/deb/${PKG_NAME}"
  rm -rf "$work"; mkdir -p "$work/DEBIAN"
  cp -a "$stage/src/." "$work/"

  # Documentation goes where Debian policy expects it.
  # gzip -9n: no timestamp and no stored filename, so the result is identical
  # on every machine and the package stays reproducible.
  while IFS= read -r -d '' man; do
    gzip -9n "$man"
  done < <(find "$work/usr/share/man" -type f -name '*.[1-9]' -print0 2>/dev/null)

  local docdir="$work/usr/share/doc/${PKG_NAME}"
  mkdir -p "$docdir"
  [ -f "$stage/README.md" ] && cp "$stage/README.md" "$docdir/"
  [ -f "$stage/LICENSE" ]   && cp "$stage/LICENSE"   "$docdir/copyright"

  # Deliberately not `du -sk`: that counts allocated blocks, so the same files
  # yield a different size on ext4 than on the CI overlayfs, and the package
  # would be rebuilt on every machine. Sum apparent sizes, KiB-rounded per file,
  # which is what dpkg means by Installed-Size.
  # Every file counts as at least one KiB block and every directory as one,
  # which is what du would report on a 1 KiB filesystem.
  local size
  size="$(find "$work" -path "$work/DEBIAN" -prune -o \
              -type f -printf 'f %s\n' -o -type d -printf 'd 0\n' -o -type l -printf 'l 0\n' \
          | awk '$1 == "f" { total += ($2 > 1024) ? int(($2 + 1023) / 1024) : 1 }
                 $1 == "d" { total += 1 }
                 END { print total + 0 }')"

  {
    echo "Package: ${PKG_NAME}"
    echo "Version: ${PKG_VERSION}-${PKG_RELEASE}"
    echo "Architecture: ${DEB_ARCH}"
    echo "Maintainer: ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>"
    echo "Installed-Size: ${size}"
    [ -n "${DEB_DEPENDS:-}" ] && echo "Depends: ${DEB_DEPENDS}"
    [ -n "${DEB_RECOMMENDS:-}" ] && echo "Recommends: ${DEB_RECOMMENDS}"
    [ -n "${DEB_SUGGESTS:-}" ] && echo "Suggests: ${DEB_SUGGESTS}"
    [ -n "${DEB_PROVIDES:-}" ] && echo "Provides: ${DEB_PROVIDES}"
    [ -n "${DEB_REPLACES:-}" ] && echo "Replaces: ${DEB_REPLACES}"
    echo "Section: ${PKG_SECTION}"
    echo "Priority: optional"
    echo "Homepage: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo "Description: ${PKG_SUMMARY}"
    echo "${PKG_DESCRIPTION}" | fold -s -w 76 | sed 's/[[:space:]]*$//; s/^$/./; s/^/ /'
  } > "$work/DEBIAN/control"

  # Everything under /etc is a conffile, per Debian policy.
  ( cd "$work" && find etc -type f 2>/dev/null || true ) | sed 's|^|/|' | LC_ALL=C sort > "$work/DEBIAN/conffiles"
  [ -s "$work/DEBIAN/conffiles" ] || rm -f "$work/DEBIAN/conffiles"

  ( cd "$work" && find . -path ./DEBIAN -prune -o -type f -print \
      | sed 's|^\./||' | LC_ALL=C sort | xargs -r md5sum ) > "$work/DEBIAN/md5sums"

  # Optional maintainer scripts, copied straight from the package directory.
  for s in preinst postinst prerm postrm triggers; do
    [ -f "${pkgdir}/debian/${s}" ] || continue
    cp "${pkgdir}/debian/${s}" "$work/DEBIAN/${s}"
    chmod 0755 "$work/DEBIAN/${s}"
  done

  mkdir -p "${BUILD_DIR}/out/deb"
  local out="${BUILD_DIR}/out/deb/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${DEB_ARCH}.deb"
  info "dpkg-deb ${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${DEB_ARCH}"

  local deb_stage; deb_stage="$(mktemp -d)"
  cp -a "$work/." "$deb_stage/"
  chmod -R u=rwX,go=rX "$deb_stage"
  chmod 0755 "$deb_stage/DEBIAN"
  [ -f "$deb_stage/DEBIAN/control" ] && chmod 0644 "$deb_stage/DEBIAN/control"
  [ -f "$deb_stage/DEBIAN/md5sums" ] && chmod 0644 "$deb_stage/DEBIAN/md5sums"

  tool dpkg-deb --root-owner-group -Zxz --build "$deb_stage" "$out" >/dev/null
  rm -rf "$deb_stage"
}
