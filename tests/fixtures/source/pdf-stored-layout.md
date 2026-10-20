# PDF stored-layout fixture

`pdf-stored-layout.hwpx` is generated exclusively from this repository's synthetic
`native-fixture.hwp`. The known field-bearing paragraph subtree is removed using
the test-only managed compound-file writer; HwpForge 0.16.11 converts that clean
test input with `carry_layout_cache=True` solely to test stored-layout PDF replay.
It contains synthetic Korean paragraphs and an empty 2x2 table, not a user document.
This cache-bearing fixture is never an editable working template.

The fixture rendered as one A4 page without engine warnings under Windows, and
its output was inspected through Poppler text extraction and a PNG page render.
This does not establish identical Hancom typesetting or all-feature support.
