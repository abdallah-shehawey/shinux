#!/bin/sh
# Shinux Repository -- remove the repository from this machine.
#   curl -fsSL https://abdallah-shehawey.github.io/shinux/uninstall.sh | sudo sh
#
# By default this removes only the repository configuration and its key; any
# packages you installed from it stay. Pass --purge to remove those too.
set -eu

REPO_ID="shinux"

PURGE=no
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=yes ;;
    -h|--help)
      echo "usage: uninstall.sh [--purge]"
      echo "  --purge  also remove every package installed from the repository"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This removes files under /etc, run it with sudo." >&2
  exit 1
fi

if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  pm="$(command -v dnf || command -v yum)"

  if [ "$PURGE" = yes ]; then
    # Column 3 of `list --installed` is the repository a package came from.
    pkgs="$("$pm" list --installed 2>/dev/null \
            | awk -v r="@${REPO_ID}" '$3 == r && $1 != "'"${REPO_ID}"'-release" {print $1}')"
    if [ -n "$pkgs" ]; then
      echo "==> removing packages installed from ${REPO_ID}: $pkgs"
      # shellcheck disable=SC2086
      "$pm" remove -y $pkgs
    else
      echo "==> no packages from ${REPO_ID} are installed"
    fi
  fi

  if rpm -q "${REPO_ID}-release" >/dev/null 2>&1; then
    echo "==> removing ${REPO_ID}-release"
    "$pm" remove -y "${REPO_ID}-release"
  fi
  rm -f "/etc/yum.repos.d/${REPO_ID}.repo" "/etc/pki/rpm-gpg/RPM-GPG-KEY-${REPO_ID}"

  # Drop the trusted key from the rpm database.
  for k in $(rpm -qa 'gpg-pubkey*' --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n' 2>/dev/null \
             | grep -i "${REPO_ID}" | cut -d' ' -f1); do
    echo "==> forgetting signing key $k"
    rpm -e --allmatches "$k" || true
  done

  "$pm" clean all >/dev/null 2>&1 || true
  echo "==> ${REPO_ID} removed"

elif command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive

  if [ "$PURGE" = yes ]; then
    # Every package name the repository advertises, from apt's cached index.
    names="$(cat /var/lib/apt/lists/*${REPO_ID}*_Packages 2>/dev/null \
             | awk '/^Package: /{print $2}' | sort -u)"
    pkgs=""
    for n in $names; do
      [ "$n" = "${REPO_ID}-archive-keyring" ] && continue
      if dpkg-query -W -f='${Status}' "$n" 2>/dev/null | grep -q '^install ok installed$'; then
        pkgs="$pkgs $n"
      fi
    done
    if [ -n "$pkgs" ]; then
      echo "==> removing packages installed from ${REPO_ID}:$pkgs"
      # shellcheck disable=SC2086
      apt-get purge -y $pkgs
    else
      echo "==> no packages from ${REPO_ID} are installed"
    fi
  fi

  if dpkg-query -W -f='${Status}' "${REPO_ID}-archive-keyring" 2>/dev/null \
       | grep -q '^install ok installed$'; then
    echo "==> removing ${REPO_ID}-archive-keyring"
    apt-get purge -y "${REPO_ID}-archive-keyring"
  fi
  rm -f "/etc/apt/sources.list.d/${REPO_ID}.sources" \
        "/etc/apt/sources.list.d/${REPO_ID}.list" \
        "/etc/apt/keyrings/${REPO_ID}.gpg"

  apt-get update -qq || true
  echo "==> ${REPO_ID} removed"

else
  echo "Unsupported system: no dnf, yum or apt-get found." >&2
  exit 1
fi
