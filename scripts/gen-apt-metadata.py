#!/usr/bin/env python3
"""Generate apt repository metadata (Packages / Release) for a flat pool.

Written by hand instead of shelling out to apt-ftparchive so the build works on
a Fedora host, where apt-utils is not packaged. Only dpkg-deb is required, and
Fedora ships that.

Layout produced:
    <root>/pool/<component>/<letter>/<pkg>/*.deb
    <root>/dists/<suite>/<component>/binary-<arch>/Packages{,.gz}
    <root>/dists/<suite>/Release

With --flat-out, a second copy of the same index is written as a *flat*
repository -- Packages, Packages.gz and Release in one directory, every
Filename a bare basename. That is the shape a GitHub release can serve: asset
names cannot contain a slash, so `dists/stable/main/binary-amd64/Packages` is
unreachable there but `Packages` is, and apt resolves a flat repo's Filename
against the same directory it read the index from. It is what moves apt's
downloads onto a counter GitHub keeps; Pages counts nothing.
"""
from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import gzip
import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

CHECKSUMS = (("MD5Sum", "md5"), ("SHA1", "sha1"), ("SHA256", "sha256"))


def digest(path: Path, algo: str) -> str:
    h = hashlib.new(algo)
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def control_of(deb: Path) -> dict[str, str]:
    """Parse the deb's control stanza, preserving multi-line Description."""
    raw = subprocess.run(
        ["dpkg-deb", "-f", str(deb)], check=True, capture_output=True, text=True
    ).stdout
    fields: dict[str, str] = {}
    key = None
    for line in raw.splitlines():
        if line.startswith((" ", "\t")) and key:
            fields[key] += "\n" + line
        elif ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            fields[key] = value.strip()
    return fields


def stanza_for(deb: Path, root: Path, flat: str | None = None) -> str:
    fields = control_of(deb)
    order = [
        "Package", "Source", "Version", "Architecture", "Maintainer",
        "Installed-Size", "Depends", "Pre-Depends", "Recommends", "Suggests",
        "Conflicts", "Breaks", "Replaces", "Provides", "Section", "Priority",
        "Homepage",
    ]
    out = [f"{k}: {fields[k]}" for k in order if k in fields]
    # In a flat repository apt joins Filename onto the *base* URI -- what
    # `URIs:` says -- and NOT onto the directory it read the index from.
    # Measured: with `URIs: http://host` + `Suites: pool/`, a bare basename was
    # fetched from http://host/<name> and 404'd. So the directory has to be in
    # the field itself, which is what puts the release tag back in the URL:
    # .../releases/download + pool/<asset> is the asset's own address, and the
    # slash lives in this field rather than in any asset name.
    out.append(f"Filename: {flat + '/' + deb.name if flat else deb.relative_to(root).as_posix()}")
    out.append(f"Size: {deb.stat().st_size}")
    for _, algo in CHECKSUMS:
        label = {"md5": "MD5sum", "sha1": "SHA1", "sha256": "SHA256"}[algo]
        out.append(f"{label}: {digest(deb, algo)}")
    if "Description" in fields:
        out.append(f"Description: {fields['Description']}")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="the deb/ directory")
    ap.add_argument("--suite", default="stable")
    ap.add_argument("--component", default="main")
    ap.add_argument("--archs", default="amd64 arm64")
    ap.add_argument("--origin", default="shinux")
    ap.add_argument("--label", default="Shinux Repository")
    ap.add_argument("--description", default="Third-party packages")
    ap.add_argument("--flat-out", type=Path, default=None,
                    help="also write a flat Packages/Release here, for release assets")
    ap.add_argument("--flat-prefix", default="pool",
                    help="the directory the flat index is served from, e.g. the release tag")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    archs = args.archs.split()
    pool = root / "pool" / args.component
    debs = sorted(pool.rglob("*.deb")) if pool.is_dir() else []
    if not debs:
        print("gen-apt-metadata: no .deb files under", pool, file=sys.stderr)

    dists = root / "dists" / args.suite
    # Drop stale per-architecture metadata so a removed package cannot linger in
    # Packages. Release and its signatures are left alone: they are compared and
    # rewritten below only when something actually changed.
    component_dir = dists / args.component
    if component_dir.exists():
        for stale in component_dir.rglob("*"):
            if stale.is_file():
                stale.unlink()

    by_arch: dict[str, list[str]] = {a: [] for a in archs}
    for deb in debs:
        arch = control_of(deb).get("Architecture", "all")
        stanza = stanza_for(deb, root)
        # "all" packages are listed in every advertised architecture.
        targets = archs if arch == "all" else ([arch] if arch in by_arch else [])
        if not targets:
            print(f"gen-apt-metadata: skipping {deb.name} (arch {arch} not advertised)",
                  file=sys.stderr)
        for a in targets:
            by_arch[a].append(stanza)

    release_files: list[tuple[str, Path]] = []
    for arch in archs:
        d = dists / args.component / f"binary-{arch}"
        d.mkdir(parents=True, exist_ok=True)
        text = "\n".join(by_arch[arch])
        plain = d / "Packages"
        plain.write_text(text, encoding="utf-8")
        gz = d / "Packages.gz"
        # mtime=0 keeps the gzip byte-identical between runs, so a rebuild with
        # no package change produces no git diff.
        with gzip.GzipFile(filename="", fileobj=gz.open("wb"), mode="wb", mtime=0) as fh:
            fh.write(text.encode("utf-8"))
        rel_dir = d / "Release"
        rel_dir.write_text(
            f"Archive: {args.suite}\n"
            f"Component: {args.component}\n"
            f"Origin: {args.origin}\n"
            f"Label: {args.label}\n"
            f"Architecture: {arch}\n",
            encoding="utf-8",
        )
        for f in (plain, gz, rel_dir):
            release_files.append((f.relative_to(dists).as_posix(), f))

    stamp = os.environ.get("SOURCE_DATE_EPOCH")
    now = dt.datetime.fromtimestamp(int(stamp) if stamp else time.time(), dt.timezone.utc)
    date = email.utils.format_datetime(now.replace(microsecond=0), usegmt=True)

    lines = [
        f"Origin: {args.origin}",
        f"Label: {args.label}",
        f"Suite: {args.suite}",
        f"Codename: {args.suite}",
        f"Version: 1.0",
        f"Architectures: {' '.join(archs)}",
        f"Components: {args.component}",
        f"Description: {args.description}",
        f"Date: {date}",
        "Acquire-By-Hash: no",
    ]
    for header, algo in CHECKSUMS:
        lines.append(f"{header}:")
        for rel, path in release_files:
            lines.append(f" {digest(path, algo)} {path.stat().st_size:>16} {rel}")
    if args.flat_out is not None:
        write_flat(args.flat_out, debs, archs, args, args.flat_prefix)

    release = dists / "Release"
    new_text = "\n".join(lines) + "\n"

    # Rewriting Release purely to move its Date forward would invalidate the two
    # signatures over it on every publish, for no benefit. Keep the old bytes
    # when nothing but the date differs, so an unchanged repo produces no diff.
    def without_date(text: str) -> str:
        return "\n".join(l for l in text.splitlines() if not l.startswith("Date:"))

    if release.exists() and without_date(release.read_text(encoding="utf-8")) == without_date(new_text):
        print(f"gen-apt-metadata: {len(debs)} package(s), unchanged")
        return 0

    release.write_text(new_text, encoding="utf-8")
    print(f"gen-apt-metadata: {len(debs)} package(s), suite {args.suite}, archs {' '.join(archs)}")
    return 0


def write_flat(out: Path, debs: list[Path], archs: list[str], args, prefix: str) -> None:
    """The same index, flattened into one directory for the release assets."""
    out.mkdir(parents=True, exist_ok=True)

    # One Packages for every architecture, because a flat repository has no
    # per-arch index to split them into. apt reads the whole file and ignores
    # the stanzas whose Architecture is neither its own nor "all", so an arm64
    # machine and an amd64 one can share this.
    text = "\n".join(stanza_for(deb, out, flat=prefix) for deb in debs)

    plain = out / "Packages"
    plain.write_text(text, encoding="utf-8")
    gz = out / "Packages.gz"
    with gzip.GzipFile(filename="", fileobj=gz.open("wb"), mode="wb", mtime=0) as fh:
        fh.write(text.encode("utf-8"))

    stamp = os.environ.get("SOURCE_DATE_EPOCH")
    now = dt.datetime.fromtimestamp(int(stamp) if stamp else time.time(), dt.timezone.utc)
    lines = [
        f"Origin: {args.origin}",
        f"Label: {args.label}",
        # Suite has to be the name apt asked for, which for a flat repository
        # is the directory with its trailing slash. "stable" earns "W:
        # Conflicting distribution ... (expected pool/ but got stable)" on
        # every update, and leaving it out earns the same warning with an empty
        # "got". Both measured against apt 3.0, not guessed.
        f"Suite: {prefix}/",
        f"Architectures: {' '.join(archs)}",
        f"Description: {args.description}",
        f"Date: {email.utils.format_datetime(now.replace(microsecond=0), usegmt=True)}",
        # by-hash paths carry a slash, which no release asset name can.
        "Acquire-By-Hash: no",
    ]
    # No Components field: its presence is exactly what tells apt this is a
    # normal repository with a dists/ tree, and there is none here.
    for header, algo in CHECKSUMS:
        lines.append(f"{header}:")
        for f in (plain, gz):
            lines.append(f" {digest(f, algo)} {f.stat().st_size:>16} {f.name}")
    (out / "Release").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"gen-apt-metadata: flat index for {len(debs)} package(s) in {out}")


if __name__ == "__main__":
    raise SystemExit(main())
