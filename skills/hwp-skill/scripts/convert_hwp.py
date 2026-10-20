"""Offline HWP5 decoder worker. The caller owns preservation and promotion."""
import argparse
import hashlib
import json
import platform
import struct
import sys
import sysconfig
import zipfile
from pathlib import Path, PurePosixPath

MAX_BYTES = 100 * 1024 * 1024


def runtime_platform():
    if sys.implementation.name != "cpython" or sys.version_info < (3, 9):
        raise ValueError("HWP conversion requires CPython 3.9 or newer.")
    if struct.calcsize("P") != 8 or sysconfig.get_config_var("Py_GIL_DISABLED"):
        raise ValueError("HWP conversion requires a standard 64-bit CPython build.")
    machine = platform.machine().lower()
    if sys.platform == "win32" and machine in ("amd64", "x86_64"):
        return "win_amd64"
    if sys.platform == "linux" and machine in ("x86_64", "aarch64", "arm64"):
        libc, version = platform.libc_ver()
        if libc != "glibc" or tuple(map(int, version.split(".")[:2])) < (2, 28):
            raise ValueError("Bundled Linux converter requires glibc 2.28 or newer.")
        return "manylinux_2_28_" + ("aarch64" if machine == "arm64" else machine)
    if sys.platform == "darwin" and machine in ("x86_64", "arm64"):
        return "macosx_11_0_arm64" if machine == "arm64" else "macosx_10_12_x86_64"
    raise ValueError("No bundled HWP converter for this Python platform.")


def load_engine(scratch):
    vendor = Path(__file__).resolve().parent.parent / "vendor" / "hwpforge"
    manifest = json.loads((vendor / "manifest.json").read_text(encoding="utf-8"))
    choices = [w for w in manifest["wheels"] if w["platform"] == runtime_platform()]
    if len(choices) != 1:
        raise ValueError("Missing or ambiguous bundled converter platform.")
    wheel = choices[0]
    name = wheel["file"]
    if Path(name).name != name or "/" in name or "\\" in name:
        raise ValueError("Invalid bundled wheel name.")
    path = vendor / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("Invalid bundled converter artifact.")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != wheel["sha256"]:
        raise ValueError("Bundled converter SHA-256 mismatch.")
    unpacked = scratch / "engine"
    unpacked.mkdir()
    with zipfile.ZipFile(path) as archive:
        expanded = 0
        for member in archive.infolist():
            logical = PurePosixPath(member.filename)
            if logical.is_absolute() or ".." in logical.parts or "\\" in member.filename or ":" in member.filename:
                raise ValueError("Unsafe bundled wheel entry.")
            if (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("Linked bundled wheel entry.")
            expanded += member.file_size
            if expanded > 128 * 1024 * 1024:
                raise ValueError("Bundled wheel exceeds its expansion limit.")
        archive.extractall(unpacked)
    sys.path.insert(0, str(unpacked))
    import hwpforge
    if hwpforge.__version__ != manifest["version"]:
        raise ValueError("Bundled converter version mismatch.")
    return hwpforge


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    scratch = Path(args.scratch).resolve(strict=True)
    paths = [Path(p) for p in (args.input, args.output, args.report)]
    for path in paths:
        if path.is_symlink() or path.resolve().parent != scratch:
            raise ValueError("Worker paths must be direct files in its private workspace.")
    source, output, report_path = paths
    if output.exists() or report_path.exists():
        raise ValueError("Worker never overwrites existing output.")
    report = {"status": "BLOCKED", "engine": "HwpForge", "version": "0.16.11", "warnings": []}
    try:
        if source.stat().st_size > MAX_BYTES:
            raise ValueError("HWP conversion input exceeds 100 MiB.")
        engine = load_engine(scratch)
        with source.open("rb") as handle:
            data = handle.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES or not data.startswith(bytes.fromhex("d0cf11e0a1b11ae1")):
            raise ValueError("Worker input is not a bounded HWP compound file.")
        # Stored HWP line caches are not valid editing coordinates in the new package.
        converted = engine.convert_hwp5(data, carry_layout_cache=False)
        warnings = converted.report["warnings"]
        if not isinstance(warnings, list):
            raise ValueError("Unrecognised converter diagnostics.")
        report["warningCount"] = len(warnings)
        report["warnings"] = warnings[:32]
        if warnings:
            raise ValueError("Conversion diagnostics report unsupported or changed content; output refused.")
        content = converted.document.to_bytes()
        if not content.startswith(b"PK\x03\x04") or len(content) > MAX_BYTES:
            raise ValueError("Converter did not produce a bounded HWPX package.")
        with output.open("xb") as handle:
            handle.write(content)
        report.update(status="PASS", outputSha256=hashlib.sha256(content).hexdigest())
    except Exception as error:
        report["error"] = str(error)[:1500]
    with report_path.open("x", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=True)
    print(json.dumps({"status": report["status"]}))
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    sys.exit(main())
