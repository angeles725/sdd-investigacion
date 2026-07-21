# Reproduce an analysis run with `analysis-manifest.v1`

`analysis_manifest.py` records artifact and tool identities from supplied files and run metadata. It never launches the input artifact or the recorded tool.

## Quick path

1. Preserve stdout, stderr, and every generated output below one analysis root.
2. Write a creation spec using artifact-relative paths.
3. Run `python3 analysis_manifest.py create --root <root> --spec <spec.json> --output <manifest.json>`. Add `--overwrite` only when replacing that path is intentional.
4. Check structure with `python3 analysis_manifest.py validate <manifest.json>`.
5. Rehash preserved files with `python3 analysis_manifest.py verify --root <root> <manifest.json>`.

## Contract

| Area | Required evidence |
|---|---|
| Input | Relative path, basename, byte size, SHA-256, and optional supplied detected type |
| Tool | Name/version, argv-zero launcher identity, plus zero or more argv-bound analysis artifacts |
| Invocation | Ordered, secret-free `argv` and sanitized environment metadata from the built-in allowlist |
| Run | UTC start/end, duration in milliseconds, and exactly one exit code or signal |
| Artifacts | stdout, stderr, and outputs with relative paths, sizes, and SHA-256 |
| Interpretation | Findings with bound `path:line` evidence locations, limitations, errors, and completeness |
| Isolation | Named profile plus static, network, and target-execution booleans |

The schema identifier is exactly `analysis-manifest.v1`. Unknown versions and unknown or missing fields fail closed. Hashes use `sha256:` followed by 64 lowercase hexadecimal characters.

An interpreter-backed creation spec keeps launcher and analyzer distinct:

```json
"tool": {"name":"Vineflower","version":"1.x","executable":"/opt/java/bin/java","artifacts":[{"path":"tools/vineflower.jar","argv_index":2}]},
"argv": ["/opt/java/bin/java","-jar","tools/vineflower.jar","input.jar"]
```

## Determinism and safety

- Canonical JSON uses UTF-8, lexicographically sorted keys, compact separators, and one trailing newline.
- `identity` hashes the canonical manifest while excluding only `identity`, `run.started_at`, `run.ended_at`, and `run.duration_ms`. Identical evidence and outcomes therefore retain one identity across timing-only reruns.
- Artifact paths must be canonical relative POSIX paths below the supplied root. Absolute paths, backslashes, `.` segments, `..` traversal, non-files, and symlink escapes are rejected.
- Validation also rejects percent-encoded traversal/absolute forms, Windows drive paths, and URI-like paths after repeated decoding and Unicode normalization.
- Environment keys must be explicitly allowlisted. Secret-like keys or values, including bearer tokens and private-key markers, are rejected rather than redacted.
- `argv` values and option names that look like secrets are rejected. Compound names such as `--client-secret`, `--access-token`, and `--password-file` fail in both `--option value` and `--option=value` forms, while unrelated prefixes such as `--tokenize` remain valid. The caller must redact secrets before capture and record the resulting loss of exactness in `limitations`; the manifest writer never stores or prints the rejected value.
- Launcher identity is bound to `argv[0]`. Analysis artifacts use canonical root-relative paths or canonical absolute external paths at unique, nonzero `argv_index` values; each path must exactly equal that argv token and is recorded with size and SHA-256. `verify --root` rehashes launcher and artifacts without executing either.
- Only analysis-tool artifacts may be absolute. Input, output, stdout, stderr, and finding-evidence paths remain root-contained.
- Absolute launchers are used directly, relative launchers resolve below `--root`, and bare launchers resolve only through the supplied allowlisted `PATH`. Every launcher must resolve to existing regular executable bytes with a non-null SHA-256. Relative `PATH` entries (including `.` and empty) are rooted and contained below `--root`; absolute entries are explicitly caller-trusted and may point outside it.
- File identities are hashed through one open descriptor and accepted only when before/after `fstat` metadata is stable. The final path component may not be a symlink when the platform supports `O_NOFOLLOW` (and is checked explicitly otherwise).
- `create` writes a same-directory temporary file, syncs it, and publishes atomically. It refuses an existing output path unless the caller explicitly supplies `--overwrite`.
- Finding IDs are unique. Evidence ranges use positive, ordered `path:start-end` line numbers; `verify --root` also requires the referenced file to exist and every end line to be within that file.
- The isolation profile must record `target_execution: false`. Creation reads files for hashing but executes nothing.

`validate` is intentionally structural: it checks the manifest contract and stable identity without requiring the original filesystem. `verify --root` additionally reopens and rehashes the recorded input, file-backed tool, stdout, stderr, and outputs; any missing or changed file fails closed. Neither mode executes a recorded command.
