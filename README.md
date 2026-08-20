<h1 align="center">shinux</h1>

<p align="center">
  A signed package repository for <b>dnf</b> and <b>apt</b>, hosted free on GitHub Pages.<br>
  Add it once, then install and upgrade like any distribution package.
</p>

<p align="center">
  <a href="https://abdallah-shehawey.github.io/shinux/"><img alt="repository" src="https://img.shields.io/badge/repo-abdallah--shehawey.github.io%2Fshinux-38bdf8"></a>
  <img alt="formats" src="https://img.shields.io/badge/formats-rpm%20%7C%20deb-f59e0b">
  <img alt="signed" src="https://img.shields.io/badge/packages-GPG%20signed-22c55e">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-64748b">
</p>

---

## Install

One command, any distribution:

```bash
curl -fsSL https://abdallah-shehawey.github.io/shinux/install.sh | sudo sh
```

<details>
<summary>Prefer to do it by hand?</summary>

**Fedora · RHEL · CentOS · Rocky · Alma**

```bash
sudo dnf install -y https://abdallah-shehawey.github.io/shinux/rpm/shinux-release-1.0-1.noarch.rpm
```

**Debian · Ubuntu · Mint**

```bash
curl -fsSL https://abdallah-shehawey.github.io/shinux/shinux-keyring.deb -o /tmp/shinux-keyring.deb \
  && sudo apt install -y /tmp/shinux-keyring.deb && sudo apt update
```
</details>

Then install whatever you want:

```bash
sudo dnf install vidtime          # or: sudo apt install vidtime
sudo dnf install shinux-scripts   # everything at once
```

## Uninstall

```bash
curl -fsSL https://abdallah-shehawey.github.io/shinux/uninstall.sh | sudo sh
```

That removes the repository and its key but leaves installed packages alone.
Add `-s -- --purge` to remove those too:

```bash
curl -fsSL https://abdallah-shehawey.github.io/shinux/uninstall.sh | sudo sh -s -- --purge
```

<details>
<summary>By hand</summary>

**Fedora · RHEL**

```bash
sudo dnf remove shinux-release
sudo rpm -e $(rpm -qa 'gpg-pubkey*' --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n' \
              | grep -i shinux | cut -d' ' -f1)
sudo dnf clean all
```

**Debian · Ubuntu**

```bash
sudo apt purge shinux-archive-keyring
sudo rm -f /etc/apt/sources.list.d/shinux.sources /etc/apt/keyrings/shinux.gpg
sudo apt update
```
</details>

## What is in it

| Package | Command | What it does |
|---|---|---|
| `vidtime` | `vidtime` | How long media files run, and their total |
| `padnum` | `padnum` | Zero-pad numeric filename prefixes, with undo |
| `hashnum` | `hashnum` | Move a `#N` tag to the front of a filename |
| `meet` | `meet` | Open a saved meeting link by name |
| `dlup` | `dlup` | Download with yt-dlp, upload to an rclone remote |
| `antigravity-update` | `antigravity-update` | Update a local Antigravity IDE install |
| `update-every-thing` | `update-every-thing` | Every Fedora update in one pass (rpm only) |
| `shinux-scripts` | — | Metapackage pulling in all of the above |

Every command ships a man page, `-h/--help`, `--version` and bash completion,
and declares its dependencies, so `dnf install meet` pulls in `fzf` and
`xdg-utils` on its own.

---

## Maintaining the repository

### Layout

| Path | What it is |
|---|---|
| `packages/<name>/` | One source package: `metadata.env` + a `src/` tree rooted at `/` |
| `scripts/` | Build, sign and publish. Nothing else needs editing |
| `docs/` | **The repository itself.** Committed, served by GitHub Pages |
| `.github/workflows/publish.yml` | Rebuilds and re-signs `docs/` on every push |

One source tree produces both an `.rpm` and a `.deb`, so the two can never
drift apart: `src/usr/bin/foo` becomes `/usr/bin/foo` in either format.

`docs/` is committed on purpose. GitHub Pages serves it straight from `main`,
and old package versions have to stay reachable so `dnf downgrade` and version
pinning keep working.

### One-time setup

```bash
make key          # create the GPG signing key (docs/ gets the public half)
make publish      # build, sign, generate metadata
git add -A && git commit -m "initial repository" && git push -u origin main
```

Then in the GitHub repository settings:

1. **Settings → Pages** → Source: *Deploy from a branch* → `main`, folder `/docs`.
2. **Settings → Secrets and variables → Actions** → new secret `GPG_PRIVATE_KEY`,
   pasting all of `private-key.asc`. Delete that file afterwards.

Back up `.gnupg/`. Losing the signing key means every existing user has to
re-trust a new one.

### Shipping an update

Bump the version, publish, push. Everyone who added the repo picks it up with a
normal `dnf upgrade` / `apt upgrade`.

```bash
$EDITOR packages/vidtime/src/usr/bin/vidtime
make bump PKG=vidtime LEVEL=patch     # 1.1.0-1  ->  1.1.1-1
make publish
git add -A && git commit -m "vidtime 1.1.1" && git push
```

| `LEVEL` | `1.2.3-4` becomes | Use when |
|---|---|---|
| `release` *(default)* | `1.2.3-5` | only the packaging changed |
| `patch` | `1.2.4-1` | bug fix |
| `minor` | `1.3.0-1` | new feature, still compatible |
| `major` | `2.0.0-1` | breaking change |
| `2.5.0` | `2.5.0-1` | an exact version you pick |

dnf and apt order these identically, so any bump triggers an upgrade. The old
build stays in the pool; `make prune KEEP=3` trims the history when it gets long.

How fast users see it: dnf re-checks after `metadata_expire=6h`, or immediately
with `dnf --refresh upgrade`; apt on the next `apt update`.

> **Change a package without bumping it and clients that already cached the old
> version will never see the change.** `make publish` warns when it spots this.

### Adding a package

```bash
mkdir -p packages/mytool/src/usr/bin
install -m 0755 /path/to/mytool packages/mytool/src/usr/bin/
cp packages/vidtime/metadata.env packages/mytool/metadata.env
$EDITOR packages/mytool/metadata.env      # name, version, summary, dependencies
make publish
```

Anything under `src/` is packaged at the matching absolute path:

| Put it here | It lands at |
|---|---|
| `src/usr/bin/mytool` | `/usr/bin/mytool` |
| `src/usr/share/man/man1/mytool.1` | compressed man page, both formats |
| `src/usr/share/bash-completion/completions/mytool` | shell completion |
| `src/etc/mytool.conf` | config file — user edits survive upgrades |

These placeholders are expanded in every text file under `src/` at build time:
`@VERSION@`, `@RELEASE@`, `@BASE_URL@`, `@REPO_ID@`, `@REPO_NAME@`,
`@KEY_FPR@`, `@MAINTAINER@`.

For a compiled program set `RPM_ARCH="x86_64"` and `DEB_ARCH="amd64"`. To ship
only one format, set `PKG_FORMATS="rpm"`. Debian maintainer scripts go in
`packages/<name>/debian/{preinst,postinst,prerm,postrm}`.

### Testing before you push

```bash
make test          # both families
make test-fedora   # add repo + install + run, inside a real Fedora container
make test-debian   # the same against Debian 12
make serve         # browse docs/ at http://127.0.0.1:8099
```

The tests publish to a throwaway tree served on `127.0.0.1`; `docs/` is never
touched.

### Requirements

`rpmbuild`, `dpkg-deb`, `gnupg2`, `python3`, plus `createrepo_c` and `rpmsign`.
Fedora ships neither of the last two by default:

```bash
sudo dnf install createrepo_c rpm-sign
```

If you would rather not, the scripts fetch them into `.tools/` with
`dnf download` and unpack them there — no root needed. Failing that, they fall
back to a rootless `podman` container.

`apt-ftparchive` is deliberately not used: `scripts/gen-apt-metadata.py` writes
the `Packages` and `Release` files directly, so the apt half builds on a Fedora
host with nothing but `dpkg-deb`.

### Reproducibility

`make publish` is idempotent — run it twice with no source change and `docs/`
comes out byte-identical, so CI never commits noise. That needs care in three
places, all of which are already handled and worth not undoing:

- Package identity is fingerprinted from NEVRA, dependencies, scriptlets and
  per-file digests, **not** the rpm header digest, which covers `BUILDTIME`.
- `Installed-Size` is summed from apparent file sizes, not `du -sk`, which
  counts allocated blocks and so differs between filesystems.
- Every `sort` that feeds package contents runs under `LC_ALL=C`, and each
  rpm's mtime is pinned to its own `BUILDTIME`.

### Security

- Every `.rpm` is signed and the `.repo` file sets `gpgcheck=1`, so nothing
  installs without a matching signature. `shinux-release` imports the public
  key from `%posttrans`, which is why the first install never stops to ask.
- `repodata/repomd.xml` is signed too, but the shipped `.repo` sets
  `repo_gpgcheck=0` — as Fedora, RPM Fusion, EPEL and every COPR do. dnf keeps
  its metadata keyring per cache directory, and shell completion runs dnf as
  your own user against `~/.cache/libdnf5`, where no key was ever imported;
  with the check on, `dnf install <TAB>` quietly drops the repository. Set it
  back to `1` if you would rather have the check than the completion.
- The apt `Release` file is signed detached (`Release.gpg`) and inline
  (`InRelease`), and the sources entry pins the key with `Signed-By:`, so it can
  only ever vouch for this one repository.
- The private key never leaves `.gnupg/` locally and the `GPG_PRIVATE_KEY`
  secret in CI. Both are git-ignored.

## License

MIT.
