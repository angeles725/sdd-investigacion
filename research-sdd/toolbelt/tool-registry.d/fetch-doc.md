### fetch-doc

| Tool | Description |
|---|---|
| `rsdd sources fetch-doc [--replace] doc <url> <target-dir> [datasheets\|manuals] [name]` / `[--replace] web <url> <target-dir>` / `ocr <pdf>` | Go port of `fetch-doc.sh` (epic #2270); the row `fetch-doc.sh ...` in the web-page table above still describes the modes, the overwrite policy, the part-file name and the exit contract (0 ok, 1 failure, 2 usage, 3 degraded, 4 destination exists, 5 destination is a symlink). `fetch-doc.sh` is now a compatibility shim (`rsdd_exec sources fetch-doc "$@"`, same PID, signals reach the Go process); callers (`verify-sources.sh`, `profile-target.sh`, `lib/scripts-manifest.sh`, `research-sdd-status.sh`) are unchanged. Engine packages: `internal/sources/{fetchdoc,runner,slug,redirect,download,place}` and the core-tier `internal/core/srcregistry`. |

Packages (one responsibility each): `fetchdoc` composes the command (arguments, doc/web/ocr stages, signals, test seam);
`runner` runs an external tool in its own process group; `slug` derives the web snapshot name; `redirect` resolves permanent
301/308 redirects; `download` fetches with curl then wget through a part file; `place` installs, archives (`--replace`), retargets
and sweeps stale part files; `core/srcregistry` is the SOURCES.md table.

Exported API for other domains (the verify-sources port), package `internal/core/srcregistry` (core tier, so any domain may import it):

- Row parsing and queries: `ParseRows`, `Row` (`Line`, `File`, `Type`, `Origin`, `Date`, `SHA`, `Citing`), `Row.IsHeader`,
  `Row.IsSeparator`, `FormatRow`, `SafeCell`, `HasRow`, `Header`, `SourcesFile`.
- Pure edits: `InsertRow` (the first-table insert of the old awk), `RetargetFile` (sha-scoped).
- Edits on disk: `Append`, `Retarget`, `Has`.
- Hashing and identity: `SHA256Hex`, `FileSHA256`, `Identity` (document identity, no size cap).

Intended divergences from the retired script (each pinned from both sides: `TestIntendedDivergences` for the new behaviour and
`TestDivergencesPinnedAgainstLegacy` for the old one, in `internal/sources/fetchdoc`):

- **Missing arguments are usage errors.** A missing mode, url, target directory or pdf is exit 2 with `fetch-doc: <reason>` and the
  usage line; the script died with bash's `line N: 2: url` message and exit 1.
- **A name or sub-directory cannot leave `sources/`.** `../`, `/`, `.`, `..` and an absolute sub are refused; the script wrote outside.
- **A `|` or control character in the name or sub-directory is refused** (the script split the SOURCES.md row).
- **A typed URL containing `|` is percent-encoded** (`%7C`) in the Origin cell; the script cut the cell.
- **A URL that starts with `-` or holds control characters is refused** (curl option injection).
- **SOURCES.md keeps its mode** (a new file is 0644); the script left it 0600 through `mktemp`.
- **No sha256 tool is a dependency.** The hash is computed in process; the script's exit 3 `DEGRADED: no sha256 tool` is gone, and so
  is the `web_slug` degraded state. `cp` is no longer a dependency either (the web fallback copy is in process).
- **OCR is loud.** A tesseract failure prints a notice and exits 1 (the script aborted silently with the tool's status); a PDF with no
  pages prints a notice and exits 1 (the script exited 0 silently).
- **The PDF hint falls back to the `%PDF-` magic** when `file(1)` is missing.
- **A failing `mkdir` is a typed message.**
- **Test seam (test-only).** `FETCHDOC_TEST_SEAM=1` with `FETCHDOC_TEST_AT=install|after-fork` runs `FETCHDOC_TEST_CMD` with `$$`
  replaced by the pid; `HTML` is exported only in the web stages. Inert without the opt-in.

Unchanged and pinned by the differential (52 scenarios, `testdata/legacy/fetch-doc.sh` is the frozen oracle): the curl argument
shapes, the redirect rules and notices, the wget fallback, versioned `--replace` names, the stale part sweep, INT/TERM handling
(130/143, whole process group cancelled, signals ignored from install until the row is written).
