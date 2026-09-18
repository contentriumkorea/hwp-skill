"""Local, bounded raster decoding for non-Windows HWPX authoring. No writes."""
import os
import sys
import warnings


def validate(path):
    from PIL import Image

    Image.MAX_IMAGE_PIXELS = 100_000_000
    warnings.simplefilter("error", Image.DecompressionBombWarning)
    with open(path, "rb") as source:
        if not 8 <= os.fstat(source.fileno()).st_size <= 32 * 1024 * 1024:
            raise ValueError("Image must be between 8 bytes and 32 MiB")
        with Image.open(source) as probe:
            if probe.format not in {"PNG", "JPEG", "GIF", "BMP", "TIFF"}:
                raise ValueError("Unsupported raster encoding")
            probe.verify()
    with open(path, "rb") as source, Image.open(source) as image:
        pixels = 0
        for frame in range(image.n_frames if hasattr(image, "n_frames") else 1):
            image.seek(frame)
            width, height = image.size
            pixels += width * height
            if width < 1 or height < 1 or pixels > 100_000_000:
                raise ValueError("Invalid or excessive decoded image dimensions")
            image.load()


if __name__ == "__main__":
    try:
        validate(sys.argv[1])
        print("PASS")
    except Exception as exc:
        print("Raster validation failed: " + str(exc), file=sys.stderr)
        sys.exit(1)
