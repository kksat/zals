"""Prepare GitHub wheels for PyPI without changing their bundled executables.

The initial v0.1.0 wheels used a non-existent Trove classifier. Correct that
metadata only for publication, retaining the original GitHub release assets.
New releases carry the valid classifier directly in pyproject.toml.
"""

from __future__ import annotations

import argparse
import base64
import csv
from email.parser import BytesParser
import hashlib
import io
from pathlib import Path
import shutil
import zipfile

INVALID_CLASSIFIER = b"Classifier: Topic :: Software Development :: Language Servers"
VALID_CLASSIFIER = b"Classifier: Topic :: Software Development"


def prepare_wheel(source: Path, destination: Path, version: str) -> bool:
    """Correct the legacy classifier and regenerate RECORD; copy valid wheels."""
    with zipfile.ZipFile(source) as wheel:
        infos = wheel.infolist()
        names = wheel.namelist()
        metadata_names = [name for name in names if name.endswith(".dist-info/METADATA")]
        if len(metadata_names) != 1 or len(names) != len(set(names)):
            raise ValueError(f"Invalid wheel structure: {source.name}")
        metadata_name = metadata_names[0]
        metadata_bytes = wheel.read(metadata_name)
        metadata = BytesParser().parsebytes(metadata_bytes)
        if metadata["Name"] != "zals" or metadata["Version"] != version:
            raise ValueError(f"Wrong wheel version or name: {source.name}")
        lines = metadata_bytes.splitlines(keepends=True)
        repaired = b"".join(
            line.replace(INVALID_CLASSIFIER, VALID_CLASSIFIER, 1)
            if line.rstrip(b"\r\n") == INVALID_CLASSIFIER else line
            for line in lines
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        if repaired == metadata_bytes:
            shutil.copy2(source, destination)
            return False
        prefix = metadata_name.removesuffix("METADATA")
        record_name = prefix + "RECORD"
        if record_name not in names or any(name in names for name in
                                           (record_name + ".jws", record_name + ".p7s")):
            raise ValueError(f"Cannot safely repair signed or missing RECORD: {source.name}")
        contents = {info.filename: wheel.read(info.filename) for info in infos}
        contents[metadata_name] = repaired
        record = io.StringIO(newline="")
        writer = csv.writer(record, lineterminator="\n")
        for name, content in contents.items():
            if name == record_name:
                writer.writerow((name, "", ""))
            else:
                digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest()).rstrip(b"=").decode()
                writer.writerow((name, f"sha256={digest}", str(len(content))))
        contents[record_name] = record.getvalue().encode()
        with zipfile.ZipFile(destination, "w") as output:
            for info in infos:
                output.writestr(info, contents[info.filename])
    return True


def main() -> None:
    # PyPI's published classifier vocabulary; fail locally before any upload.
    from trove_classifiers import classifiers

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source", type=Path, default=Path("dist"))
    parser.add_argument("--output", type=Path, default=Path("wheelhouse"))
    args = parser.parse_args()
    sources = sorted(args.source.glob("*.whl"))
    if len(sources) != 5:
        raise ValueError(f"Expected five verified wheels, got {len(sources)}")
    for source in sources:
        output = args.output / source.name
        repaired = prepare_wheel(source, output, args.tag.removeprefix("v"))
        with zipfile.ZipFile(output) as wheel:
            name = next(name for name in wheel.namelist() if name.endswith(".dist-info/METADATA"))
            metadata = BytesParser().parsebytes(wheel.read(name))
            invalid = set(metadata.get_all("Classifier", [])) - classifiers
            if invalid:
                raise ValueError(f"Invalid PyPI classifiers in {source.name}: {sorted(invalid)}")
        print(f"{'Repaired legacy classifier in' if repaired else 'Copied'} {source.name}")


if __name__ == "__main__":
    main()
