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
    for key in ("depend", "conflict", "provides", "replaces", "optdepend"):
        values = fields.get(key, [])
        if values:
            lines.append((key.upper() if key != "optdepend" else "OPTDEPEND", "\n".join(values)))

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
        for package in packages:
            fields = pkginfo(package)
            name = value(fields, "pkgname")
            version = value(fields, "pkgver")
            arch = value(fields, "arch")
            entry = f"{name}-{version}-{arch}"
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
