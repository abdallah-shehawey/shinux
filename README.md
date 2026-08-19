# shinux

A signed third-party package repository for **dnf** (Fedora, RHEL, CentOS, Rocky,
Alma) and **apt** (Debian, Ubuntu, Mint), hosted for free on GitHub Pages.

Users add it once, then install and upgrade your software exactly like any
distribution package.

```bash
# Fedora / RHEL
sudo rpm --import https://abdallah-shehawey.github.io/shinux/RPM-GPG-KEY-shinux
sudo dnf install -y https://abdallah-shehawey.github.io/shinux/rpm/shinux-release-1.0-1.noarch.rpm
sudo dnf install hello-shinux

# Debian / Ubuntu
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://abdallah-shehawey.github.io/shinux/shinux.gpg \
     -o /etc/apt/keyrings/shinux.gpg
sudo curl -fsSL https://abdallah-shehawey.github.io/shinux/shinux.sources \
     -o /etc/apt/sources.list.d/shinux.sources
sudo apt update && sudo apt install hello-shinux
```

---

## How it is put together

| Path | What it is |
|---|---|
| `packages/<name>/` | One source package: `metadata.env` + a `src/` tree rooted at `/` |
| `scripts/` | Build, sign and publish. Nothing else needs editing |
| `docs/` | **The repository itself.** Committed, served by GitHub Pages |
| `.github/workflows/publish.yml` | Rebuilds and re-signs `docs/` on every push |

One source tree produces both an `.rpm` and a `.deb`, so the two can never
drift apart. `src/usr/bin/foo` becomes `/usr/bin/foo` in both formats.

`docs/` is committed on purpose: GitHub Pages serves it directly from `main`,
and old package versions have to stay reachable so `dnf downgrade` and version
pinning keep working.

## One-time setup

```bash
make key          # create the GPG signing key (docs/ gets the public half)
make publish      # build, sign, generate metadata
git add -A && git commit -m "initial repository" && git push -u origin main
```

Then, in the GitHub repository settings:

1. **Settings → Pages** → Source: *Deploy from a branch* → branch `main`, folder `/docs`.
2. **Settings → Secrets and variables → Actions** → new secret `GPG_PRIVATE_KEY`,
   pasting the whole contents of `private-key.asc`. Delete that file afterwards.

Back up `.gnupg/` somewhere safe. Losing the signing key means every existing
user has to re-trust a new one.

## Shipping an update

This is the part that makes it a real repository: bump the version, publish, and
everyone who added the repo picks it up with a normal `dnf upgrade` / `apt upgrade`.

```bash
vim packages/hello-shinux/src/usr/bin/hello-shinux   # change the program
make bump PKG=hello-shinux LEVEL=patch               # 1.0.0-1  ->  1.0.1-1
make publish
git add -A && git commit -m "hello-shinux 1.0.1" && git push
```

`LEVEL` is one of:

| LEVEL | 1.2.3-4 becomes | use when |
|---|---|---|
| `release` (default) | `1.2.3-5` | only the packaging changed |
| `patch` | `1.2.4-1` | bug fix |
| `minor` | `1.3.0-1` | new feature, still compatible |
| `major` | `2.0.0-1` | breaking change |
| `2.5.0` | `2.5.0-1` | an exact version you pick |

Both dnf and apt order these identically, so any bump is enough to trigger an
upgrade. The old build stays in the pool; `make prune KEEP=3` trims the history
when it gets long.

How fast users see it: dnf re-checks after `metadata_expire=6h` (or immediately
on `dnf --refresh upgrade`), apt on the next `apt update`.

## Adding a new package

```bash
mkdir -p packages/mytool/src/usr/bin
cp /path/to/mytool packages/mytool/src/usr/bin/
chmod +x packages/mytool/src/usr/bin/mytool
cp packages/hello-shinux/metadata.env packages/mytool/metadata.env
$EDITOR packages/mytool/metadata.env      # name, version, summary, deps
make publish
```

Anything you drop under `src/` is packaged at the matching absolute path:
`src/usr/share/applications/mytool.desktop`, `src/etc/mytool.conf`, and so on.
Files under `/etc` are automatically marked as config files in both formats, so
a user's edits survive upgrades.

Inside any text file under `src/`, these placeholders are expanded at build
time: `@VERSION@`, `@RELEASE@`, `@BASE_URL@`, `@REPO_ID@`, `@REPO_NAME@`,
`@KEY_FPR@`, `@MAINTAINER@`.

For a compiled program, set `RPM_ARCH="x86_64"` and `DEB_ARCH="amd64"` in
`metadata.env` and put the built binary in `src/usr/bin/`.

Optional Debian maintainer scripts go in `packages/<name>/debian/`:
`preinst`, `postinst`, `prerm`, `postrm`.

## Testing before you push

```bash
make test          # both families
make test-fedora   # add repo + install + run, inside a real Fedora container
make test-debian   # the same against Debian 12
make serve         # browse docs/ at http://127.0.0.1:8099
```

The tests publish to a throwaway tree served on `127.0.0.1`; `docs/` is never
touched.

## Requirements

`rpmbuild`, `dpkg-deb`, `gnupg2`, `python3`, and `createrepo_c` + `rpmsign`.
Fedora does not install the last two by default:

```bash
sudo dnf install createrepo_c rpm-sign
```

If you would rather not install them, the scripts fall back to a rootless
`podman`/`docker` container automatically — no sudo needed.

`apt-ftparchive` is deliberately not used: `scripts/gen-apt-metadata.py`
generates the `Packages`/`Release` files directly, so the whole apt side builds
on a Fedora host.

## Security model

- Every `.rpm` is signed, and so is `repodata/repomd.xml` — the `.repo` file
  sets both `gpgcheck=1` and `repo_gpgcheck=1`.
- The apt `Release` file is signed both detached (`Release.gpg`) and inline
  (`InRelease`), and the sources entry pins the key with `Signed-By:`, so this
  key can only ever vouch for this one repository.
- The private key never leaves `.gnupg/` locally and lives only in the
  `GPG_PRIVATE_KEY` GitHub secret in CI. Both are git-ignored.

## License

MIT.
