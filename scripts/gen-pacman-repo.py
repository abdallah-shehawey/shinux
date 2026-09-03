#!/usr/bin/env python3
"""Build a flat, signed pacman repository from .pkg.tar.zst files."""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile


def pkginfo(package: pathlib.Path) -> dict[str, list[str]]:
    for member in (".PKGINFO", "./.PKGINFO"):
        try:
            raw = subprocess.check_output(
                ["tar", "--zstd", "-xOf", str(package), member],
                text=True, stderr=subprocess.DEVNULL
            )
            break
        except subprocess.CalledProcessError:
            continue
    else:
        raise SystemExit(f"cannot read .PKGINFO from {package}")

    fields: dict[str, list[str]] = {}
    for line in raw.splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        fields.setdefault(key, []).append(value)
    return fields


def value(fields: dict[str, list[str]], key: str, default: str = "") -> str:
    return fields.get(key, [default])[0]


def desc(fields: dict[str, list[str]], package: pathlib.Path, signature: pathlib.Path) -> str:
    data = package.read_bytes()
    signature_b64 = base64.b64encode(signature.read_bytes()).decode("ascii")
    lines = [
        ("FILENAME", package.name),
        ("NAME", value(fields, "pkgname")),
        ("BASE", value(fields, "pkgbase", value(fields, "pkgname"))),
        ("VERSION", value(fields, "pkgver")),
        ("DESC", value(fields, "pkgdesc")),
        ("CSIZE", str(len(data))),
        ("ISIZE", value(fields, "size", "0")),
        ("MD5SUM", hashlib.md5(data).hexdigest()),
        ("SHA256SUM", hashlib.sha256(data).hexdigest()),
        ("PGPSIG", signature_b64),
        ("ARCH", value(fields, "arch")),
        ("BUILDDATE", value(fields, "builddate")),
        ("PACKAGER", value(fields, "packager")),
        ("URL", value(fields, "url")),
        ("LICENSE", value(fields, "license")),
    ]
    # .PKGINFO names these in the singular; a sync database names them in the
    # plural, and pacman answers anything else with "unknown key '%DEPEND%' in
    # sync database" and then ignores the dependency entirely. Mapped rather
    # than upper()d, because the two vocabularies do not line up: "provides" is
    # already plural on both sides.
    db_key = {
        "depend": "DEPENDS", "conflict": "CONFLICTS", "provides": "PROVIDES",
        "replaces": "REPLACES", "optdepend": "OPTDEPENDS",
        "makedepend": "MAKEDEPENDS", "checkdepend": "CHECKDEPENDS",
        "group": "GROUPS",
    }
    for key, header in db_key.items():
        values = fields.get(key, [])
        if values:
            lines.append((header, "\n".join(values)))

    return "".join(f"%{key}%\n{item}\n\n" for key, item in lines)


def files_desc(fields: dict[str, list[str]], package: pathlib.Path) -> str:
    names = []
    listing = subprocess.check_output(
        ["tar", "--zstd", "-tf", str(package)], text=True
    )
    for name in listing.splitlines():
        if name in {".PKGINFO", "./.PKGINFO", ".MTREE", "./.MTREE", ".INSTALL", "./.INSTALL"}:
            continue
        names.append("/" + name.removeprefix("./"))
    return "%FILES%\n" + "\n".join(names) + "\n\n"


def newest_per_name(
    packages: list[pathlib.Path],
) -> list[tuple[pathlib.Path, dict[str, list[str]]]]:
    """One entry per package name, newest kept.

    A pacman sync database is an index of what is available now, not an archive
    of everything the pool holds. dnf and apt are handed every version and pick
    for themselves; pacman reads the first entry it finds for a name, keeps
    that one and says nothing -- so the moment a second version of the same
    package reached the pool, `pacman -Si whatsapp` started answering with the
    OLDER of the two and an upgrade was never offered. Verified against the
    live repository, not reasoned about.

    Older versions stay in the pool and in the release, installable with
    `pacman -U <url>`, exactly as the rpms stay for `dnf downgrade`.

    Ordered by `sort -V` over the file names, which is what prune.sh uses to
    decide what leaves the pool: if the two disagreed this would index a
    version the prune is about to delete.
    """
    order = subprocess.run(
        ["sort", "-V"],
        input="\n".join(p.name for p in packages),
        text=True, capture_output=True, check=True,
    ).stdout.splitlines()
    rank = {name: i for i, name in enumerate(order)}

    best: dict[str, tuple[pathlib.Path, dict[str, list[str]]]] = {}
    for package in packages:
        fields = pkginfo(package)
        name = value(fields, "pkgname")
        current = best.get(name)
        if current is None or rank[package.name] > rank[current[0].name]:
            best[name] = (package, fields)
    return [best[name] for name in sorted(best)]


def write_db(arch_dir: pathlib.Path, repo_id: str, key_id: str) -> None:
    def is_versioned(p: pathlib.Path) -> bool:
        stem = p.name.removesuffix(".pkg.tar.zst")
        parts = stem.rsplit("-", 2)
        return len(parts) == 3 and parts[1].isdigit() and any(c.isdigit() for c in parts[0])

    packages = sorted(p for p in arch_dir.glob("*.pkg.tar.zst") if is_versioned(p))
    if not packages:
        raise SystemExit(f"no versioned Arch packages found in {arch_dir}")

    for package in packages:
        signature = package.with_name(package.name + ".sig")
        if not signature.exists():
            subprocess.run(
                ["gpg", "--batch", "--yes", "--detach-sign", "--local-user", key_id,
                 "-o", str(signature), str(package)],
                check=True,
            )

    with tempfile.TemporaryDirectory(prefix="pacman-db-") as temp:
        root = pathlib.Path(temp)
        dbroot = root / "db"
        filesroot = root / "files"
        dbroot.mkdir()
        filesroot.mkdir()
        for package, fields in newest_per_name(packages):
            name = value(fields, "pkgname")
            version = value(fields, "pkgver")
            # <pkgname>-<pkgver>-<pkgrel>, and .PKGINFO's pkgver already ends
            # in -<pkgrel>. The architecture does NOT belong here: pacman
            # splits this directory name from the right and compares the halves
            # against %NAME% and %VERSION%, so "vidtime-1.2.0-any" was read as
            # version 1.2.0 with pkgrel "any" and every package in the database
            # came back as "shinux database is inconsistent: name mismatch".
            # That made `pacman -S` fail for the whole repository.
            entry = f"{name}-{version}"
            (dbroot / entry).mkdir()
            (dbroot / entry / "desc").write_text(
                desc(fields, package, package.with_name(package.name + ".sig")), encoding="utf-8"
            )
            (filesroot / entry).mkdir()
            (filesroot / entry / "files").write_text(files_desc(fields, package), encoding="utf-8")

        db = arch_dir / f"{repo_id}.db.tar.gz"
        files_db = arch_dir / f"{repo_id}.files.tar.gz"
        for output, source in ((db, dbroot), (files_db, filesroot)):
            with tarfile.open(output, "w:gz", compresslevel=9) as archive:
                for path in sorted(source.rglob("*")):
                    info = archive.gettarinfo(str(path), arcname=str(path.relative_to(source)))
                    info.uid = info.gid = 0
                    info.uname = info.gname = "root"
                    info.mtime = 0
                    if path.is_file():
                        with path.open("rb") as stream:
                            archive.addfile(info, stream)
                    else:
                        archive.addfile(info)

        for base in (db, files_db):
            signature = base.with_name(base.name + ".sig")
            subprocess.run(
                ["gpg", "--batch", "--yes", "--detach-sign", "--local-user", key_id,
                 "-o", str(signature), str(base)],
                check=True,
            )
            # Pacman requests the short .db/.files names from Server URLs.
            short = arch_dir / base.name.removesuffix(".tar.gz")
            short_sig = short.with_name(short.name + ".sig")
            shutil.copyfile(base, short)
            shutil.copyfile(signature, short_sig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch-dir", type=pathlib.Path, required=True)
    parser.add_argument("--repo-id", required=True)
    parser.add_argument("--key-id", required=True)
    args = parser.parse_args()
    write_db(args.arch_dir, args.repo_id, args.key_id)
    print(f"pacman repository ready: {args.arch_dir}/{args.repo_id}.db")
