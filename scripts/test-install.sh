#!/usr/bin/env bash
# End-to-end proof: publish the repository to a throwaway tree served over
# HTTP, then let a real dnf/apt container add it, install, and upgrade.
#
#   scripts/test-install.sh fedora
#   scripts/test-install.sh debian
#   scripts/test-install.sh arch
#
# Nothing here touches docs/ or the committed pool.
set -euo pipefail
family="${1:-fedora}"
PORT="${PORT:-8099}"

source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-tools.sh"

eng="$(container_engine)" || die "podman or docker is required for the install test"
export BASE_URL="http://127.0.0.1:${PORT}"
export OUT_DIR="${BUILD_DIR}/testsite"
# Its own build tree as well: the packages built here bake the throwaway
# BASE_URL into shinux-release and shinux-archive-keyring, and leaving those in
# the shared build/out means the next real publish ships a .repo pointing at
# localhost.
export BUILD_DIR="${BUILD_DIR}/testbuild"
source "$(dirname "$0")/config.sh"   # re-derive RPM_DIR/DEB_DIR under the new OUT_DIR

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
# The exported public key lives in docs/; the throwaway tree needs its own copy
# before the release packages can be generated against it.
cp "${ROOT_DIR}/docs/RPM-GPG-KEY-${REPO_ID}" "${OUT_DIR}/" 2>/dev/null \
  || die "no exported key in docs/; run scripts/gpg-setup.sh first"
cp "${ROOT_DIR}/docs/${REPO_ID}.gpg" "${OUT_DIR}/"

info "publishing a throwaway repository at ${BASE_URL}"
"${ROOT_DIR}/scripts/build.sh"    >/dev/null
"${ROOT_DIR}/scripts/make-repo.sh" >/dev/null

python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${OUT_DIR}" >/dev/null 2>&1 &
server=$!
trap 'kill "${server}" 2>/dev/null || true' EXIT
sleep 1
curl -fsS "${BASE_URL}/index.html" >/dev/null || die "local http server did not come up"

# A warm image with the test's own prerequisites already installed, if one has
# been built. The plain base image works exactly the same, it just spends
# several minutes re-downloading distribution metadata on every run:
#   podman build -t localhost/shinux-test-fedora -f scripts/Containerfile.test-fedora .
warm="localhost/${REPO_ID}-test-${family}"
if "$eng" image exists "$warm" 2>/dev/null; then
  info "using the warm test image ${warm}"
else
  warm=""
fi

case "$family" in
  fedora)
    image="${warm:-registry.fedoraproject.org/fedora:44}"
    script='set -eu
      # The documented by-hand order: trust the key, then add the repository.
      # A scriptlet cannot do the first step -- rpm holds its database open for
      # the whole transaction -- so whatever adds the repository has to.
      rpm --import '"${BASE_URL}"'/RPM-GPG-KEY-'"${REPO_ID}"'
      dnf install -y '"${BASE_URL}"'/rpm/'"$(cd "${RPM_DIR}" && ls -1 ${REPO_ID}-release-*.rpm | sort -V | tail -1)"'
      dnf -q repolist '"${REPO_ID}"'

      echo "### the key is trusted, so no install will stop to ask about it"
      rpm -qa gpg-pubkey --qf "%{SUMMARY}\n" | grep -i '"${REPO_ID}"'

      # The Fedora container image sets tsflags=nodocs, which strips man pages
      # on install. Turn that off so the test actually checks them.
      # shadow-utils for useradd, util-linux for runuser: the completion checks
      # below have to run as an unprivileged user to mean anything.
      dnf install -y -q --setopt=tsflags= man-db bash-completion shadow-utils util-linux >/dev/null

      echo "### antigravity-update is only suggested, never pulled in"
      if dnf install --assumeno update-every-thing 2>&1 | grep -q antigravity; then
        echo "FAIL: antigravity-update was pulled in as a dependency"; exit 1
      fi

      # Before the install, on purpose: completing a package you already have is
      # the easy half. The point of a repository is that `sudo dnf install
      # vid<TAB>` finds vidtime while it is still only available.
      #
      # Unprivileged on purpose too: completion runs dnf as your own user
      # against ~/.cache/libdnf5, which has no signing key in it. With
      # repo_gpgcheck=1 the repository is silently dropped right here and our
      # packages never appear.
      echo "### tab completion finds a package that is NOT installed yet"
      useradd -m tester
      if rpm -q vidtime >/dev/null 2>&1; then
        echo "FAIL: vidtime is already installed, this proves nothing"; exit 1
      fi
      runuser -u tester -- dnf5 --complete=2 dnf install vid | tee /tmp/comp
      grep -qx vidtime /tmp/comp
      runuser -u tester -- dnf5 --complete=2 dnf install hello- | grep -qx hello-'"${REPO_ID}"'

      echo "### installing every package from the repository"
      dnf install -y --setopt=tsflags= '"${REPO_ID}"'-scripts hello-'"${REPO_ID}"'

      echo "### the metapackage pulled in its dependencies"
      rpm -q vidtime padnum meet hashnum dlup antigravity-update update-every-thing

      echo "### signature on an installed package"
      rpm -q --qf "%{NAME}: %{RSAHEADER:pgpsig}\n" vidtime

      echo "### every command answers --version and --help"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        "$c" --version
        "$c" --help >/dev/null
      done

      echo "### man pages are installed and readable"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        man -w "$c" >/dev/null
      done

      echo "### bash completions are installed"
      ls /usr/share/bash-completion/completions/ | sort

      echo "### and completion still works now that the package is installed"
      runuser -u tester -- dnf5 --complete=2 dnf remove vid | grep -qx vidtime

      echo "### update-every-thing detects the right package manager"
      update-every-thing --help | grep -i "dnf/yum or apt"

      echo "### a command actually runs"
      hello-'"${REPO_ID}"'
      cd /tmp && mkdir -p pn && cd pn && touch "1 a.txt" "2 b.txt" "10 c.txt"
      padnum && ls -1

      echo "### the desktop application installs and is complete"
      dnf install -y --setopt=tsflags= whatsapp
      whatsapp --version
      whatsapp --help >/dev/null
      # A compiled package is the one place a missing dependency shows up at run
      # time rather than at install time, so check the linker is satisfied.
      if command -v ldd >/dev/null; then
        ldd /usr/bin/whatsapp | grep "not found" && { echo "FAIL: unresolved libraries"; exit 1; }
      fi
      test -f /usr/share/applications/io.github.shehawey.whatsapp.desktop
      test -f /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
      grep -q -- "--hidden" /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
      test -f /usr/share/icons/hicolor/48x48/apps/io.github.shehawey.whatsapp.png
      test -f /usr/share/icons/hicolor/22x22/status/io.github.shehawey.whatsapp-tray.png

      echo "### and it uninstalls cleanly"
      dnf remove -y whatsapp
      test ! -e /usr/bin/whatsapp
      test ! -e /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
'
    ;;
  debian)
    image="${warm:-docker.io/library/ubuntu:24.04}"
    script='set -eu
      export DEBIAN_FRONTEND=noninteractive

      # The Ubuntu image ships /etc/apt/apt.conf.d/docker-clean, which blanks
      # Dir::Cache::pkgcache and srcpkgcache to keep image layers small. That
      # leaves apt-cache --no-generate -- exactly what apt tab completion shells
      # out to -- failing with "E: Could not open file" on a container that is
      # otherwise healthy. Remove it here rather than only in the warm image, so
      # the test behaves the same whether or not that image has been built.
      rm -f /etc/apt/apt.conf.d/docker-clean

      apt-get update -qq
      apt-get install -y -qq curl ca-certificates gnupg man-db bash-completion >/dev/null

      echo "### adding the repository the one-command way"
      curl -fsSL '"${BASE_URL}"'/'"${REPO_ID}"'-keyring.deb -o /tmp/keyring.deb
      apt-get install -y /tmp/keyring.deb
      apt-get update

      echo "### the Release file verified against the pinned key"
      apt-cache policy | grep -A1 '"${REPO_ID}"' | head -4

      echo "### antigravity-update is only suggested, never pulled in"
      if apt-get install -s update-every-thing | grep -q "^Inst antigravity"; then
        echo "FAIL: antigravity-update was pulled in as a dependency"; exit 1
      fi

      # Before the install, on purpose: completing a package you already have is
      # the easy half. apt completion shells out to exactly this, as the
      # invoking user, so run it the same way.
      echo "### tab completion finds a package that is NOT installed yet"
      useradd -m tester
      if dpkg-query -W -f="\${Status}" vidtime 2>/dev/null | grep -q "^install ok installed$"; then
        echo "FAIL: vidtime is already installed, this proves nothing"; exit 1
      fi
      runuser -u tester -- apt-cache --no-generate pkgnames vid | tee /tmp/comp
      grep -qx vidtime /tmp/comp
      runuser -u tester -- apt-cache --no-generate pkgnames hello- | grep -qx hello-'"${REPO_ID}"'

      echo "### installing every package from the repository"
      apt-get install -y '"${REPO_ID}"'-scripts hello-'"${REPO_ID}"'

      echo "### the metapackage pulled in its dependencies"
      dpkg -l vidtime padnum meet hashnum dlup antigravity-update update-every-thing \
        | awk "/^ii/ { print \$2, \$3 }"

      echo "### every command answers --version and --help"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        "$c" --version
        "$c" --help >/dev/null
      done

      echo "### man pages are installed and readable"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        man -w "$c" >/dev/null
      done

      echo "### bash completions are installed"
      ls /usr/share/bash-completion/completions/ | sort

      echo "### and completion still works now that the package is installed"
      runuser -u tester -- apt-cache --no-generate pkgnames vidtime | grep -qx vidtime

      echo "### update-every-thing picked apt, not dnf"
      update-every-thing --help | grep -i "dnf/yum or apt"

      echo "### a command actually runs"
      hello-'"${REPO_ID}"'
      cd /tmp && mkdir -p pn && cd pn && touch "1 a.txt" "2 b.txt" "10 c.txt"
      padnum && ls -1

      echo "### the desktop application installs and is complete"
      apt-get install -y -qq whatsapp >/dev/null
      whatsapp --version
      whatsapp --help >/dev/null
      # A compiled package is the one place a missing dependency shows up at run
      # time rather than at install time, so check the linker is satisfied.
      if command -v ldd >/dev/null; then
        ldd /usr/bin/whatsapp | grep "not found" && { echo "FAIL: unresolved libraries"; exit 1; }
      fi
      test -f /usr/share/applications/io.github.shehawey.whatsapp.desktop
      test -f /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
      grep -q -- "--hidden" /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
      test -f /usr/share/icons/hicolor/48x48/apps/io.github.shehawey.whatsapp.png
      test -f /usr/share/icons/hicolor/22x22/status/io.github.shehawey.whatsapp-tray.png

      echo "### and it uninstalls cleanly"
      apt-get purge -y -qq whatsapp >/dev/null
      test ! -e /usr/bin/whatsapp
      test ! -e /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
'
    ;;
  arch)
    image="${warm:-docker.io/library/archlinux:base}"
    script='set -eu
      # The archlinux image ships NoExtract rules that throw away man pages,
      # info pages, docs and every non-English locale to keep the layer small
      # -- "NoExtract = usr/share/man/*" among them. A man-page check inside a
      # container that has them is checking nothing: the file is in the package
      # and simply never lands on disk. Same reason the debian family removes
      # docker-clean. Strip them so the test sees what a real machine sees.
      sed -i "/^NoExtract/d" /etc/pacman.conf

      pacman -Sy --noconfirm --needed curl man-db bash-completion >/dev/null 2>&1

      echo "### trusting the key, then adding the repository by hand"
      curl -fsSL '"${BASE_URL}"'/'"${REPO_ID}"'.gpg -o /tmp/key.gpg
      pacman-key --init >/dev/null 2>&1
      pacman-key --add /tmp/key.gpg >/dev/null 2>&1
      fpr=$(gpg --show-keys --with-colons /tmp/key.gpg | awk -F: "\$1==\"fpr\"{print \$10;exit}")
      pacman-key --lsign-key "$fpr" >/dev/null 2>&1
      printf "Server = %s/arch\n" '"${BASE_URL}"' > /etc/pacman.d/'"${REPO_ID}"'-mirrorlist
      printf "\n[%s]\nInclude = /etc/pacman.d/%s-mirrorlist\nSigLevel = Required DatabaseOptional\n" \
        '"${REPO_ID}"' '"${REPO_ID}"' >> /etc/pacman.conf

      # The whole point of this family. A database whose entry directories do
      # not parse comes back as "database is inconsistent: name mismatch" on
      # every package, and a %DEPEND% where %DEPENDS% belongs comes back as
      # "unknown key ... in sync database" -- both of which pacman prints and
      # then carries on from, so nothing but an explicit check catches them.
      echo "### the sync database parses cleanly"
      pacman -Sy --noconfirm 2>&1 | tee /tmp/sync
      if grep -Eqi "inconsistent|unknown key" /tmp/sync; then
        echo "FAIL: pacman rejected the database"; exit 1
      fi

      echo "### and the dependencies survived the round trip"
      pacman -Si vidtime | grep -E "^Depends On" | grep -q ffmpeg

      # A package whose .PKGINFO is not the first member of the archive is
      # "missing package metadata ... invalid or corrupted package", and only a
      # real install says so.
      echo "### installing every package, with signatures required"
      pacman -S --noconfirm '"${REPO_ID}"'-scripts hello-'"${REPO_ID}"' >/dev/null

      echo "### the metapackage pulled in its dependencies"
      pacman -Q vidtime padnum meet hashnum dlup antigravity-update update-every-thing

      echo "### every command answers --version and --help"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        "$c" --version
        "$c" --help >/dev/null
      done

      echo "### man pages are installed and readable"
      for c in vidtime padnum meet hashnum dlup antigravity-update update-every-thing; do
        man -w "$c" >/dev/null
      done

      echo "### bash completions are installed"
      ls /usr/share/bash-completion/completions/ | sort

      echo "### a command actually runs"
      hello-'"${REPO_ID}"'
      cd /tmp && mkdir -p pn && cd pn && touch "1 a.txt" "2 b.txt" "10 c.txt"
      padnum && ls -1

      echo "### the desktop application installs and is complete"
      pacman -S --noconfirm whatsapp >/dev/null
      whatsapp --version
      whatsapp --help >/dev/null
      if command -v ldd >/dev/null; then
        ldd /usr/bin/whatsapp | grep "not found" && { echo "FAIL: unresolved libraries"; exit 1; }
      fi
      test -f /usr/share/applications/io.github.shehawey.whatsapp.desktop
      test -f /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
      grep -q -- "--hidden" /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
      test -f /usr/share/icons/hicolor/48x48/apps/io.github.shehawey.whatsapp.png

      echo "### and it uninstalls cleanly"
      pacman -Rns --noconfirm whatsapp >/dev/null
      test ! -e /usr/bin/whatsapp
      test ! -e /etc/xdg/autostart/io.github.shehawey.whatsapp.desktop
'
    ;;
  *) die "unknown family '${family}' (expected fedora, debian or arch)" ;;
esac

info "running the install test in ${image}"
"$eng" run --rm --network=host "$image" bash -c "$script"
info "${family}: add-repo -> install -> run all passed"
