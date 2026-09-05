# Comprehensive Project Audit

## Audit context

- Product / repository: ClipOCR-Pro, a portable AutoHotkey v2 capture, annotation, local OCR, and translation utility.
- Primary user and job to be done: office users who compare evidence, ERP, email, and document content while keeping capture and privacy decisions explicit.
- Audit goal: decide whether the five-stage improvement is safe to commit, push, and prepare as the next release.
- Version / branch / baseline: target `1.5.0`, `main`, Stage 4 baseline `e64a514` plus the Stage 5 change set.
- Date: 2026-09-05.
- Auditor assumptions: company deployment supplies its own approved portable Tesseract runtime; public distribution remains the Light package.

## Verdict

Ready with conditions. The Light build, source/compiled health checks, Korean Windows OCR path, settings startup, registry precedence, and packaging guards pass. A production Full ZIP still requires the company's approved Tesseract runtime, and a public release requires the configured private-key signing certificate unless the maintainer deliberately opts into an unsigned release.

## Evidence collected

| Area | Evidence | Result | Limitation |
| --- | --- | --- | --- |
| Worktree/change history | Reviewed Stage 1–4 commits, current diff, app and registry repositories | Separate stage commits; no unrelated worktree changes found | Registry repository has no remote by design |
| Automated tests | Source and compiled `--health-check`; `scripts/static-check.ps1` | PASS | Tests are integration-oriented rather than exhaustive GUI unit tests |
| Build/release checks | Local `scripts/build.ps1`; manifest/checksum generation; Full-package structural test; missing-runtime rejection | PASS | No company-approved real Tesseract runtime or signing PFX was available on this host |
| Main user journey | Compiled `--ocr-file` against generated Korean text image | PASS; exact Korean sentence and amount extracted with Windows OCR tag `ko` | Right-click invocation was code-reviewed, not mouse-automated |
| Setup/recovery journey | Suite registry queried; local registry contained only personal consent; missing Tesseract path exercised | PASS; local settings retain priority and recovery guidance points to Windows language or Full package | English-Windows-without-Korean-pack was not available as a separate test machine |
| UI rendering/accessibility | Compiled settings window launched and stayed responsive with title `ClipOCR-Pro Settings` | Runtime PASS | Native visual inspection surface was unavailable, so pixel-level layout and keyboard traversal remain manual QA |

## Findings

| Priority | Area | Evidence/location | Impact | Smallest safe fix | Status |
| --- | --- | --- | --- | --- | --- |
| P1 | Release identity | `v1.4.0` already exists while the app still reported 1.4.0 | Publishing would be rejected or could mislabel materially different code | Advance synchronized app/file version to 1.5.0 | Fixed |
| P1 | Korean OCR recovery | `src/OcrService.ahk` local-engine fallback and user error path | Locked-down English Windows could not extract Korean without a clear supported alternative | Add portable `kor+eng` fallback, Full packaging guard, and bilingual recovery message | Fixed |
| P2 | Regression policy | Build previously depended mainly on runtime health checks | Privacy or build/publish responsibility boundaries could regress unnoticed | Add static policy checks and run them in CI | Fixed |
| P2 | Maintainability | `src/ClipOCR-Pro.ahk` exceeded 4,300 lines and owned its test fixtures | Feature edits had a broad merge and review surface | Extract health checks to `src/HealthCheck.ahk`; continue incremental extraction rather than rewrite | Mitigated |
| P2 | User guidance | Embedded multilingual manual described capture as always auto-copying and omitted local OCR | Users could misunderstand clipboard and privacy behavior | Correct auto-copy wording and add local OCR/settings guidance in every embedded language | Fixed |

## Recommended change set

1. **Now** — commit and push the tested Stage 5 set; keep publishing separate from building.
2. **Before Full release** — provide the company-approved portable Tesseract directory and run the Full build so the executable, DLLs, `kor`, and `eng` are exercised together.
3. **Before public release** — configure the private-key PFX and timestamp service, then run `publish.ps1` from a clean `main` branch.
4. **Next focused iteration** — extract GitHub update handling and multilingual manual content from the main script when either area next changes.
5. **Later** — add a Windows UI smoke runner for right-click OCR, result copy, settings keyboard navigation, and mixed-DPI capture when a native UI automation surface is available.

## Retain

- App-local settings and privacy consent take precedence and are never written into the Suite registry.
- Local OCR is a distinct action from external Google translation and has no network call or consent bypass.
- Public Light artifacts stay small; Full packaging is explicit and validates the approved runtime.
- Build, publish, and GitHub CI responsibilities remain separate; publish refuses dirty trees and existing releases.
- Release downloads are constrained to the expected repository/name and verified by size, executable header, embedded version, and SHA-256.

## Audit boundary and residual risk

The host had Windows OCR languages `en-GB`, `en-US`, `ko`, and `pl`, so fallback behavior for a machine with no Korean OCR pack was verified by logic/error-path testing rather than by removing system language features. A real portable Tesseract distribution and Authenticode private key were intentionally not sourced or stored in the repository. The live Suite key still contains ignored schema-2.0 values (`HotKeyCapture`, `OcrLanguage`) from an older import; the 2.1 adapter reads only the new names, so this is cleanup debt rather than a release blocker.
