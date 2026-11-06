### fetch-doc

- `fetch-doc: DEGRADED: neither curl nor wget is installed — cannot download; nothing registered` (fetch-doc.sh, now `rsdd sources fetch-doc`,
  engine `internal/sources/fetchdoc`): stderr, exit 3, nothing written or registered. `ocr` mode prints `tesseract not installed` (exit 3)
  or a `pdftoppm failed` notice (also exit 3, as the script) instead. The sha256 degraded state of the script no longer exists (the hash is computed in
  process). Continuation: install `curl` or `wget` (`tesseract` and `pdftoppm` for `ocr`) and re-run.
- `fetch-doc: REFUSED: destination already exists: <path> ...` (exit 4) and `fetch-doc: REFUSED: destination is a symlink: <path> ...`
  (exit 5): the overwrite policy, not a failure of the tool; also `destination appeared during the download` (exit 4) and `destination became a
  symlink during the download` (exit 5) when the race happens after the preflight. A taken versioned name under `--replace` is
  `REFUSED: versioned name already holds DIFFERENT bytes` or `is a symlink` (exit 1). Continuation: re-run with `--replace`, or choose another
  name or remove the symlink.
- `fetch-doc: REFUSED: cannot read <target>/sources/SOURCES.md: <reason> — <what was not done>` (exit 1): the registry exists but cannot be
  read (permission, or a directory in its place), so the stale-part sweep and the `--replace` archive step refuse and nothing is deleted or
  renamed. An absent `SOURCES.md` is not this state (no rows yet). Continuation: fix the permission or the path and re-run.
- `fetch-doc: <reason>` followed by a `usage:` line (exit 2): a missing mode, url, target directory or pdf, a URL that starts
  with `-` or has control characters, or a name or sub-directory that would leave `sources/` or contains `|` or a control character.
  There is no unknown-option state: every word except `--replace` is positional, so an unrecognised first word (a flag-shaped one such as
  `--x` included) prints the single line `unknown mode: <word> (doc|web|ocr)` (exit 2, no `fetch-doc:` prefix and no usage line), as the script does.
  A `--replace` given to `ocr` is accepted and ignored.
  Absent-input stays distinct from empty-input: a download with an empty body is exit 1 `empty body` and registers nothing; OCR with no
  pages is exit 1 with a notice.
