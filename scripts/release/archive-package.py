import hashlib
import sys
from pathlib import Path
from shutil import make_archive
from zipfile import ZipFile


def archive_package(package: Path, output: Path) -> None:
    output.mkdir(exist_ok=True)
    archive = Path(make_archive(str(output / package.name), "zip", root_dir=package.parent, base_dir=package.name))

    with ZipFile(archive) as zipped:
        damaged = zipped.testzip()
        if damaged is not None:
            raise RuntimeError(f"Damaged ZIP member: {damaged}")

    digest = hashlib.sha256()
    with archive.open("rb") as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b""):
            digest.update(chunk)
    archive.with_suffix(".zip.sha256").write_text(
        f"{digest.hexdigest()}  {archive.name}\n", encoding="ascii", newline="\n"
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: python scripts/release/archive-package.py PACKAGE_DIR OUTPUT_DIR")
    archive_package(Path(sys.argv[1]), Path(sys.argv[2]))
