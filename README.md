<h1 align="center">shinux</h1>

<p align="center">
  A signed package repository for <b>dnf</b>, <b>apt</b>, and native <b>Arch</b> packages, hosted free on GitHub Pages.<br>
  Add it once, then install and upgrade like any distribution package.
</p>

<p align="center">
  <a href="https://abdallah-shehawey.github.io/shinux-repo/"><img alt="repository" src="https://img.shields.io/badge/repo-abdallah--shehawey.github.io%2Fshinux--repo-38bdf8"></a>
  <img alt="formats" src="https://img.shields.io/badge/formats-rpm%20%7C%20deb%20%7C%20arch-f59e0b">
  <img alt="signed" src="https://img.shields.io/badge/packages-GPG%20signed-22c55e">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-64748b">
</p>

---

## Install

One command, any distribution:

```bash
curl -fsSL https://abdallah-shehawey.github.io/shinux-repo/install.sh | sudo sh
```

Then install what you want:

```bash
sudo dnf install vidtime          # Fedora / RHEL
sudo apt install vidtime          # Debian / Ubuntu
sudo pacman -S vidtime            # Arch
sudo dnf install shinux-scripts   # everything at once
```

To remove the repository and its key, leaving installed packages alone:

```bash
curl -fsSL https://abdallah-shehawey.github.io/shinux-repo/uninstall.sh | sudo sh
```

Add `-s -- --purge` to remove the packages too.

## What is in it

| Package | What it does |
|---|---|
| `whatsapp` | WhatsApp Web client, GTK4 + WebKitGTK, ~120 KB |
| `whatsapp-desktop` | WhatsApp Web client on Chromium, with its own Electron |
| `vidtime` | How long media files run, and their total |
| `padnum` | Zero-pad numeric filename prefixes, with undo |
| `hashnum` | Move a `#N` tag to the front of a filename |
| `meet` | Open a saved meeting link by name |
| `dlup` | Download with yt-dlp, upload to an rclone remote |
| `antigravity-update` | Update a local Antigravity IDE install |
| `update-every-thing` | Every Fedora update in one pass (rpm only) |
| `shinux-scripts` | Metapackage pulling in the command-line tools |

Every command ships a man page, `-h/--help`, `--version` and bash completion,
and declares its dependencies.

---

## Maintaining the repository

### Layout

| Path | What it is |
|---|---|
| `packages/<name>/` | One source package: `metadata.env` + a `src/` tree rooted at `/` |
| `scripts/` | Build, sign and publish. Nothing else needs editing |
| `docs/` | **The repository itself.** Not in git — assembled on every publish |
| `site/` | The page's icons, the only published files that are committed |
| `.github/workflows/publish.yml` | Rebuilds, re-signs and deploys `docs/` on every push |

One source tree produces the `.rpm`, the `.deb` and the Arch package, so they
cannot drift apart: `src/usr/bin/foo` becomes `/usr/bin/foo` in all three.

### Where the packages live

**In the assets of the `pool` release, not in git.** Committing them had grown
this repository to **4.5 GB** of history — one whatsapp-desktop version is
~250 MB across the three formats, and every version ever published was still
in there, downloaded by anyone who cloned it. Publishing now goes:

1. `pool-fetch.sh` restores the newest 4 versions of every package into
   `docs/` (from the CI cache first, from the release when that misses),
2. the build adds this version and regenerates every index,
3. `pool-assets.sh` uploads whatever is new to the release,
4. `prune.sh` trims the tree to what fits, and
5. the result is uploaded as the **Pages artifact** — `docs/` is never
   committed, and **Pages must be set to build from GitHub Actions.**

Anything pruned stays in the release, installable by URL. Nothing on an
installed system changed: same URLs, same key, same `.repo` and `.sources`.

### Where dnf downloads from

Pages publishes no statistics — no logs, no counters — so an install that came
from `dnf install` was a download nobody could see. `createrepo_c --baseurl`
writes the pool release into `primary.xml` as an `xml:base`, so dnf reads the
metadata, the keys and the signatures from Pages exactly as before and fetches
the package itself from the asset, where GitHub counts it.

The rpms are published to Pages as well, so a client whose metadata is still
within its `metadata_expire=6h` window does not 404, and `dnf install <url>`
keeps working for a link copied off the site.

Uploads are add-only: GitHub cannot replace an asset in place, so re-uploading
one means deleting it first and its download count goes with it.
`scripts/pool-assets.sh` skips whatever is already published, and runs before
`prune.sh` so a version leaving the pool is archived on its way out. The CI
cache exists for the same reason — a job that re-downloaded its own pool every
publish would bury the handful of real installs in its own traffic.

apt and pacman stay entirely on Pages. Both resolve a package's path relative
to the repository root — `Filename:` in `Packages`, `%FILENAME%` in the pacman
database — with no equivalent of `xml:base`, so pointing them elsewhere would
mean rewriting the source line on every machine that already has it.

### Shipping an update

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

> **Change a package without bumping it and clients that cached the old version
> will never see the change.** `make publish` warns when it spots this.

`make prune KEEP=3` trims old builds. Users see an update after dnf's
`metadata_expire=6h` (or `dnf --refresh upgrade`), and on the next `apt update`.

### Adding a package

```bash
mkdir -p packages/mytool/src/usr/bin
install -m 0755 /path/to/mytool packages/mytool/src/usr/bin/
cp packages/vidtime/metadata.env packages/mytool/metadata.env
$EDITOR packages/mytool/metadata.env      # name, version, summary, dependencies
make publish
```

Anything under `src/` is packaged at the matching absolute path — `src/usr/bin/mytool`
becomes `/usr/bin/mytool`, man pages are compressed, and `src/etc/*` is marked
config so user edits survive upgrades. These placeholders are expanded in every
text file under `src/`: `@VERSION@`, `@RELEASE@`, `@BASE_URL@`, `@REPO_ID@`,
`@REPO_NAME@`, `@KEY_FPR@`, `@MAINTAINER@`.

For a compiled program set `RPM_ARCH="x86_64"` and `DEB_ARCH="amd64"`. To ship
one format only, set `PKG_FORMATS="rpm"`. Debian maintainer scripts go in
`packages/<name>/debian/{preinst,postinst,prerm,postrm}`.

### Testing and setup

```bash
make test          # add repo + install + run, in real Fedora and Debian containers
make serve         # browse docs/ at http://127.0.0.1:8099
make key           # one-time: create the GPG signing key
```

Tests publish to a throwaway tree on `127.0.0.1`; `docs/` is never touched.

First time only: **Settings → Pages** → source **GitHub Actions** (not a
branch — the job uploads the site as an artifact); and
**Settings → Secrets → Actions** → `GPG_PRIVATE_KEY` holding all of
`private-key.asc`, deleted afterwards. **Back up `.gnupg/`** — losing the key
means every user has to re-trust a new one.

Needs `rpmbuild`, `dpkg-deb`, `gnupg2`, `python3`, `createrepo_c` and `rpmsign`.
Fedora ships neither of the last two by default (`sudo dnf install createrepo_c
rpm-sign`); the scripts otherwise fetch them into `.tools/`, or fall back to a
rootless podman container.

### Two things not to undo

- **`make publish` is idempotent** — run it twice with no source change and
  `docs/` comes out byte-identical. Nothing is committed any more, but the same
  property is what stops a package already in the pool from being rewritten
  under clients that cached it, and what keeps `pool-assets.sh` from having
  anything to re-upload. That depends on
  fingerprinting packages from NEVRA and file digests rather than the rpm header
  digest, summing `Installed-Size` from apparent file sizes, and sorting under
  `LC_ALL=C`.
- **`repo_gpgcheck=0` in the shipped `.repo` is deliberate**, as it is for
  Fedora, RPM Fusion, EPEL and every COPR. Packages are still signed and
  `gpgcheck=1`; the metadata signature exists too, but dnf keeps its metadata
  keyring per cache directory, and shell completion runs dnf as your own user
  against `~/.cache/libdnf5` where no key was imported — with the check on,
  `dnf install <TAB>` quietly drops the repository.

Everything else is signed end to end: each `.rpm`, `repomd.xml`, and the apt
`Release` both detached and inline, with the sources entry pinning the key via
`Signed-By:`.

## License

MIT.
