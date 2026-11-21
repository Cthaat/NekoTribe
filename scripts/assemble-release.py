"""Combine verified platform artifacts into the public per-stack ZIPs."""

import argparse
import copy
import hashlib
import re
from pathlib import Path
from shutil import copyfileobj
from zipfile import ZIP_DEFLATED, ZipFile


LAYOUT = {
    "nuxt": {"nuxt-node-windows-x64": "windows-x64", "nuxt-node-linux-x64": "linux-x64"},
    "go": {"native-go-windows-x64": "windows-x64", "native-go-linux-x64": "linux-x64"},
    "rust": {"native-rust-windows-x64": "windows-x64", "native-rust-linux-x64": "linux-x64"},
    "flutter": {"flutter-windows-x64": "windows", "flutter-android": "android", "flutter-web": "web"},
}

INSTRUCTIONS = {
    "nuxt": (
        "Choose windows-x64 or linux-x64. Install Node.js 22 and Oracle/Redis as described in the README.\n"
        "Copy .env.example to .env and set the production values. Apply the schema with "
        "node scripts/migrate-db.mjs --apply. Start with start.cmd or bash start.sh.\n"
    ),
    "go": (
        "Choose windows-x64 or linux-x64. Install Node.js 22 to use the launchers. "
        "Prepare the shared Oracle schema and Redis.\n"
        "Copy env.example to .env and configure dependencies. Start with start.cmd or bash start.sh.\n"
    ),
    "rust": (
        "Choose windows-x64 or linux-x64. Install Node.js 22 to use the launchers and Oracle Instant Client "
        "for database access. Prepare the shared Oracle schema and Redis.\n"
        "Copy env.example to .env and configure dependencies. Start with start.cmd or bash start.sh.\n"
    ),
    "flutter": (
        "Windows: Run the installer in windows/ or launch portable/nekotribe.exe inside that directory.\n"
        "Android: Open the signed APK in android/ and allow installation from your file manager when prompted.\n"
        "Set a reachable NekoTribe backend address in the app.\n"
        "Web: See web/README.md to configure the backend and serve web/site/ over HTTP(S).\n"
    ),
}

BRANCHES = {"nuxt": "master", "go": "codex/go", "rust": "Rust", "flutter": "Flutter"}


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_platform(source, destination, platform, required):
    expected = source.with_suffix(".zip.sha256").read_text(encoding="ascii").split()
    if expected != [sha256(source), source.name]:
        raise ValueError(f"Invalid checksum: {source}")

    files = set()
    members = set()
    with ZipFile(source) as archive:
        for entry in archive.infolist():
            root, _, tail = entry.filename.partition("/")
            parts = tail.removesuffix("/").split("/")
            if root != source.stem or not entry.filename.startswith(f"{root}/"):
                raise ValueError(f"Invalid package root in {source}: {entry.filename}")
            if tail and any(part in ("", ".", "..") or "\\" in part or ":" in part for part in parts):
                raise ValueError(f"Invalid package member in {source}: {entry.filename}")
            name = f"{platform}/{tail}"
            if name in members:
                raise ValueError(f"Duplicate package member: {name}")
            members.add(name)
            target = copy.copy(entry)
            target.filename = name
            if entry.is_dir():
                destination.writestr(target, b"")
                continue

            if entry.file_size:
                files.add(tail)
            with archive.open(entry) as reader, destination.open(target, "w") as writer:
                copyfileobj(reader, writer)

    missing = required - files
    if missing:
        raise ValueError(f"Incomplete platform package {source.name}: {sorted(missing)}")


def required_files(stack, platform, version):
    if stack == "nuxt":
        return {"start.cmd", "start.sh", ".env.example", "nuxt-package.json",
                "scripts/migrate-db.mjs", ".output/server/index.mjs"}
    if stack in ("go", "rust"):
        executable = f"nekotribe-{stack}" + (".exe" if platform == "windows-x64" else "")
        return {"start.cmd", "start.sh", "env.example", "native-package.json", executable}
    if platform == "windows":
        return {f"NekoTribe-{version}-windows-x64-setup.exe", "portable/nekotribe.exe",
                "portable/flutter_windows.dll", "portable/data/flutter_assets/AssetManifest.bin"}
    if platform == "android":
        return {f"NekoTribe-{version}-android.apk"}
    return {"site/index.html", "site/app_config.json", "configure-web.mjs", "nginx.conf.example"}


def assemble(stack, version, source, output):
    path = output / f"NekoTribe-{version}-{stack}.zip"
    temporary = path.with_suffix(".zip.tmp")
    try:
        with ZipFile(temporary, "x", compression=ZIP_DEFLATED) as bundle:
            for stem, platform in LAYOUT[stack].items():
                copy_platform(source / f"{stem}-{version}.zip", bundle, platform,
                              required_files(stack, platform, version))
            bundle.writestr(
                "README.txt",
                f"NekoTribe {version} — {stack}\n\n{INSTRUCTIONS[stack]}\n"
                f"https://github.com/Cthaat/NekoTribe/tree/{BRANCHES[stack]}\n",
            )
        with ZipFile(temporary) as bundle:
            if damaged := bundle.testzip():
                raise ValueError(f"Invalid archive member: {damaged}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--stack", choices=LAYOUT)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.version):
        parser.error("invalid version")
    args.output.mkdir(parents=True, exist_ok=True)

    stacks = [args.stack] if args.stack else sorted(LAYOUT)
    lines = []
    for stack in stacks:
        path = assemble(stack, args.version, args.source, args.output)
        digest = sha256(path)
        lines.append(f"{digest}  {path.name}\n")
        print(f"| {path.name} | {path.stat().st_size} | `{digest}` |")
    if not args.stack:
        (args.output / "SHA256SUMS.txt").write_text("".join(lines), encoding="ascii", newline="\n")


if __name__ == "__main__":
    main()
