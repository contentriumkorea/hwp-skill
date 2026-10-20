"""Offline stored-layout HWPX PDF worker. Never starts Hancom or a browser."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

MAX_BYTES = 100 * 1024 * 1024


def main():
    parser = argparse.ArgumentParser()
    for name in ("input", "output", "scratch", "report"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--font-dir", action="append", default=[])
    args = parser.parse_args()
    scratch = Path(args.scratch).resolve(strict=True)
    source, output, report_path = [Path(p) for p in (args.input, args.output, args.report)]
    for path in (source, output, report_path):
        if path.is_symlink() or path.resolve().parent != scratch:
            raise ValueError("PDF worker paths must be direct files in its workspace.")
    if output.exists() or report_path.exists():
        raise ValueError("PDF worker never overwrites existing output.")
    report = {"status": "BLOCKED", "engine": "HwpForge", "version": "0.16.11", "warnings": []}
    try:
        spec = importlib.util.spec_from_file_location("hwp_input_engine", Path(__file__).with_name("convert_hwp.py"))
        shared = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(shared)
        engine = shared.load_engine(scratch)
        with source.open("rb") as stream:
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES or not data.startswith(b"PK\x03\x04"):
            raise ValueError("PDF input is not a bounded HWPX package.")
        fonts = []
        for folder in args.font_dir:
            if folder.startswith(("\\\\", "//")) or not Path(folder).is_dir():
                raise ValueError("Font directories must exist locally.")
            fonts.append(str(Path(folder).resolve(strict=True)))
        rendered = engine.Document.from_bytes(data).to_pdf(
            font_dirs=fonts, discovery="explicit" if fonts else "platform",
            degraded=False, partial_cache_reject=True,
        )
        warnings = rendered.report["warnings"]
        if not isinstance(warnings, list) or warnings:
            raise ValueError("PDF render diagnostics report unsupported or changed content.")
        pages = rendered.report["pages"]
        content = rendered.data
        if not isinstance(pages, int) or not 1 <= pages <= 10000:
            raise ValueError("Invalid rendered PDF page count.")
        if len(content) > MAX_BYTES or not content.startswith(b"%PDF-") or not content.rstrip().endswith(b"%%EOF"):
            raise ValueError("Renderer did not produce a bounded complete PDF.")
        with output.open("xb") as stream:
            stream.write(content)
        report.update(status="PASS", pages=pages, outputSha256=hashlib.sha256(content).hexdigest())
    except Exception as error:
        report["error"] = str(error)[:1500]
    with report_path.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, ensure_ascii=True)
    print(json.dumps({"status": report["status"]}))
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
