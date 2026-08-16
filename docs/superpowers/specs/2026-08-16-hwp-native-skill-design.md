# HWP Native Skill Design

Date: 2026-08-16  
Status: Approved for implementation planning  
Repository name: `hwp-native-skill`  
License: MIT

## 1. Purpose

Create and publish a Windows-only Codex skill that uses the locally installed
Hancom Office application as the native document engine. The skill must read,
create, edit, batch-process, compare, export, and verify `.hwp`, `.hwt`, and
`.hwpx` files without uploading document contents to an external service.

The skill is intended for Korean public-sector and professional documents where
preserving the source document, its template, and its layout is more important
than manipulating the HWP binary format directly.

## 2. Verified Environment and Assumptions

The development machine currently has:

- Windows with PowerShell.
- Hancom Office 2024 Edu installed.
- `HWPFrame.HwpObject` registered and successfully instantiated.
- A detected automation version of `13, 0, 0, 711`.

This proves that native Hancom automation can be started on the development
machine. It does not yet prove that every operation in this specification works;
those operations require integration tests against generated fixtures.

Published compatibility will be reported honestly:

- Hancom Office 2024: verified only after the full integration suite passes.
- Hancom Office 2018, 2020, and 2022: compatibility code may be included, but
  versions not run in the test environment must be labelled unverified.
- Other operating systems: unsupported for native editing.

## 3. Scope

### 3.1 Supported capability groups

The first public release covers capability groups 1 through 8 below.

1. **Safe editing**
   - Extract text and document information.
   - Find and replace exact text.
   - Insert content before or after an unambiguous anchor.
   - Fill named fields and placeholders.
   - Save only to a versioned copy.

2. **Document production**
   - Create a new HWP document from an HWT or HWP template.
   - Insert and format headings, paragraphs, tables, and images.
   - Configure page numbers, headers, and footers.

3. **Structural editing**
   - Edit table cells and add rows.
   - Insert tables and page breaks.
   - Insert or replace images.
   - Change character and paragraph formatting.
   - Change section paper, margin, and column settings.
   - Add bookmarks, hyperlinks, captions, footnotes, endnotes, and table of
     contents operations where the installed automation API supports them.

4. **Public-document automation**
   - Fill HWT/HWP templates for official letters, reports, plans, meeting
     minutes, proposals, and storyboards.
   - Repeat a template safely over structured input records.

5. **Natural-language editing**
   - Translate a user's natural-language request into a deterministic JSON edit
     plan.
   - Validate the plan before executing it.
   - Refuse ambiguous targets rather than guessing.

6. **Review and correction**
   - Compare source and result text, fields, tables, images, sections, and page
     counts.
   - Report intended and unintended differences.
   - Support rule-based Korean document checks through optional operation sets.

7. **Batch processing**
   - Inspect, edit, convert, or verify multiple files.
   - Default to dry-run mode.
   - Produce one result and one report per input file.

8. **Visual verification**
   - Export the result to PDF through Hancom Office.
   - Render PDF pages to images when an available local renderer is detected.
   - Report empty pages, unexpected page-count changes, and potential clipped
     content for human review.

### 3.2 Explicitly excluded

- Controlling or modifying a document that the user already has open in an
  interactive Hancom window.
- Overwriting the source document automatically.
- Bypassing passwords, DRM, distribution-document restrictions, or electronic
  signatures.
- Running embedded macros.
- Editing the internals of arbitrary OLE objects, complex formula objects, or
  unsupported charts.
- Claiming pixel-identical output without rendered-page review.
- Sending document contents to a remote AI API or server.

## 4. Architecture

The skill uses a plan-then-apply pipeline:

```text
Input HWP/HWT/HWPX
  -> preflight and signature detection
  -> read-only inspection snapshot
  -> deterministic JSON edit plan
  -> plan validation and ambiguity checks
  -> versioned working copy
  -> native Hancom automation edit
  -> save and close
  -> reopen result
  -> extract and compare
  -> export PDF and render pages
  -> JSON report plus human-readable summary
```

The core implementation is PowerShell using the registered
`HWPFrame.HwpObject.2` or `HWPFrame.HwpObject` COM interface. PowerShell avoids
a mandatory Python or `pywin32` dependency and uses the real installed Hancom
engine.

Each document job runs in an isolated worker process. The controller owns the
job timeout, captures logs, and knows which automation session it created. It
must not terminate unrelated Hancom processes that predated the job.

## 5. Components

### 5.1 Public entry point

`Invoke-HwpNative.ps1` exposes these commands:

- `preflight`
- `inspect`
- `validate-plan`
- `apply`
- `generate`
- `batch`
- `compare`
- `verify`
- `export`

Every command supports machine-readable JSON output. Commands that create files
also write a short human-readable summary.

### 5.2 Session management

`HwpSession.psm1` is responsible for:

- Detecting Hancom installation and automation ProgIDs.
- Creating and closing an owned COM session.
- Recording the exact application version.
- Checking whether an approved file-path security module is already registered.
- Handling timeouts without broadly killing `Hwp.exe` processes.
- Releasing COM references in `finally` blocks.

The repository will not redistribute an unofficial or third-party security DLL.
If unattended file opening requires a module that is not configured, preflight
returns a blocked result and instructions for an explicit user-controlled setup.

### 5.3 Inspection

`HwpInspect.psm1` performs read-only extraction of:

- Actual file signature and declared extension.
- Text, paragraphs, and contextual anchors.
- Tables, rows, columns, and cell text.
- Named fields and placeholders.
- Image and embedded-object inventory.
- Sections, headers, footers, and page information available through automation.
- Document metadata and protection state available through automation.

Inspection output follows `inspection.schema.json`.

### 5.4 Editing and generation

`HwpEdit.psm1` executes only validated operations. `HwpGenerate.psm1` creates a
new document from a template or a new blank document. HWT input is always saved
as a separate HWP output.

Supported operation names are:

- `replace-text`
- `insert-before`
- `insert-after`
- `delete-range`
- `set-field`
- `set-table-cell`
- `add-table-row`
- `insert-table`
- `insert-image`
- `replace-image`
- `apply-char-style`
- `apply-para-style`
- `insert-page-break`
- `set-section`
- `set-header-footer`
- `add-bookmark`
- `add-hyperlink`
- `add-caption`
- `add-footnote`
- `add-endnote`
- `build-toc`
- `merge-documents`
- `export`

Operations that delete ranges, change table structure, change sections, or merge
documents are marked `advanced` and require explicit approval in the plan.

### 5.5 Batch processing

`HwpBatch.psm1` enumerates only explicit file inputs or files under an explicit
input directory. It never scans an entire drive or user profile. Dry-run is the
default. Apply mode creates a separate output directory and never mixes partial
results with completed results.

### 5.6 Verification

`HwpVerify.psm1`:

- Reopens the saved result through Hancom Office.
- Extracts a second inspection snapshot.
- Compares expected edit counts and values.
- Checks for unintended loss of tables, images, fields, or sections.
- Exports PDF.
- Uses an available local PDF renderer to create page images.
- Produces final status and warnings.

If no page renderer is available, PDF creation may pass but the result cannot
receive a full visual-verification pass. The status must be
`PASS_WITH_WARNINGS`, not `PASS`.

## 6. Edit Plan Contract

Every edit operation records:

- Stable operation ID.
- Operation type.
- Risk class: `safe` or `advanced`.
- Target anchor and surrounding text.
- Table, field, section, or object locator when applicable.
- Expected match count.
- Before value.
- After value or inserted content.
- Failure policy: stop or skip.
- Postcondition to verify.

Page number alone is not a valid edit locator. Natural-language requests must be
resolved using content anchors, surrounding context, and structural location.
When more than one target remains possible, planning returns candidates and does
not create an executable operation.

## 7. Source Preservation and File Lifecycle

1. Resolve and validate the exact source path.
2. Record source length, timestamp, and SHA-256.
3. Inspect without saving.
4. Create a working copy with a versioned name.
5. Apply changes only to the working copy.
6. Save to a temporary result path.
7. Reopen and verify the temporary result.
8. Promote the temporary result to the final result name only after verification.
9. Recompute the source SHA-256 and require it to be unchanged.

Failed temporary files are kept outside the completed-results directory and
labelled as failed artifacts. The report explains whether they are safe to
delete. No result is described as complete unless it passes the required gates.

## 8. Error Handling

The skill blocks before mutation when:

- The extension and actual format disagree unless the user explicitly approves
  handling the detected format.
- The file is password-protected, DRM-protected, signed, or distribution-only.
- The target is missing or ambiguous.
- A required table, field, image, or section cannot be identified exactly.
- The source is write-locked.
- The security module requirement prevents unattended opening.
- The edit plan fails schema or policy validation.

The skill fails the job when:

- Hancom automation cannot start, save, close, or reopen the result.
- A postcondition does not match the result.
- An unintended structural loss is detected.
- The source hash changes.

If an automation call hangs, the controller stops further mutation, releases the
worker where possible, and reports recovery instructions. It never performs a
broad process kill against all Hancom sessions.

## 9. Result Statuses

- `PASS`: all required text, structural, reopen, PDF, and page-render checks pass.
- `PASS_WITH_WARNINGS`: required edits pass, but a non-destructive optional
  check such as page rendering is unavailable or reports a review candidate.
- `BLOCKED`: the job was not mutated because a precondition or policy stopped it.
- `FAILED`: execution began but a required operation or verification gate failed.

Every result includes JSON and human-readable reports with input, output,
application version, operation outcomes, hashes, warnings, and recovery notes.

## 10. Repository and Distribution

The public repository is named `hwp-native-skill` and uses the MIT license.

```text
hwp-native-skill/
  README.md
  LICENSE
  install.ps1
  skill/hwp-native/
    SKILL.md
    agents/openai.yaml
    scripts/Invoke-HwpNative.ps1
    scripts/lib/*.psm1
    schemas/*.json
    references/*.md
  tests/
    fixtures/
    run-tests.ps1
```

The repository README documents requirements, safety behavior, installation,
examples, compatibility status, limitations, and test evidence. User documents
and the current Gyeongbuk Office of Education files are never included.

## 11. Testing Strategy

### 11.1 Static and policy tests

- Skill metadata and folder validation.
- JSON schema validation.
- Path canonicalization and output containment.
- Versioned output naming.
- Source-overwrite refusal.
- Unsupported format and mismatched-extension detection.
- Ambiguous locator rejection.
- Advanced-operation approval enforcement.

### 11.2 Native integration fixtures

Create synthetic fixtures owned by this project containing Korean text, repeated
phrases, fields, tables, sections, headers, footers, page numbers, and a generated
image. Fixtures cover `.hwp`, `.hwt`, and `.hwpx` without using user documents.

### 11.3 Native integration scenarios

- Paths containing Korean text and spaces.
- Dropbox-synchronized directories.
- A binary HWP deliberately given an HWPX extension.
- HWT-to-new-HWP generation.
- Text, field, table, image, style, page-break, and section operations.
- Ambiguous repeated text.
- Document merge.
- Multi-file dry-run and apply.
- Save and reopen failure handling.
- PDF export and page rendering.
- Source hash preservation.
- Owned automation-session cleanup.

## 12. Release Acceptance Criteria

The first GitHub release is ready only when:

1. The skill folder passes the official skill validator.
2. All static and policy tests pass.
3. The native integration suite passes on Hancom Office 2024 using synthetic
   fixtures.
4. The source file remains byte-identical in every edit test.
5. Every result is reopened and re-inspected through Hancom Office.
6. PDF export succeeds for every successful fixture.
7. Rendered page images are visually reviewed for the representative fixture.
8. A clean installation from the repository is tested in the Codex skills
   directory.
9. README compatibility claims match the evidence actually collected.
10. The public GitHub URL, installation instructions, and repository contents
    are checked after publication.

