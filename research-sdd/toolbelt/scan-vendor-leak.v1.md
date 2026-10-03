# scan-vendor-leak v1 — contract

Kit issue #1271 (slice 1: the scanner only; init and CI wiring are slice 2).

`scan-secrets.sh` hunts secret VALUES and excludes decompiled trees by design, so decompiled vendor source or vendor
binaries committed to a public target are invisible to it. `scan-vendor-leak.sh` is the separate guard.

```
scan-vendor-leak.sh <target-dir> [--tracked|--staged]
```

Read-only: only `git ls-files | diff --cached | show | rev-parse` run against the target. Nothing is written.

## Declaration contract (doctrine first)

A target declares its vendor code in `<TARGET>/.research-sdd/vendor-leak.conf`, one directive per line, `#` comments,
blank lines and CRLF tolerated:

| Directive | Meaning |
|---|---|
| `prefix <java.package.prefix>` | A source file (`.java .kt .scala .groovy`) whose first `package` declaration equals the prefix or starts with `<prefix>.` is a leak. `javax.baja` matches `javax.baja.sys`, never `javax.bajaextra`. |
| `path <glob>` | Any tracked file matching the glob is a leak (decompiled trees, e.g. `decompiled/**`). |
| `allow <glob>` | Explicit, reviewed allowlist. WINS over the built-in rule, `path` and `prefix`. |

Globs are bash `[[ == ]]` patterns against the repo-relative path; `*` crosses `/`, so `dir/**` covers a whole tree.

Built-in rule, independent of the conf: `*.class *.jar *.dll *.so *.exe` (case-insensitive) is a leak unless allowed.

An unknown directive or a directive without an argument is `BAD-CONF` and exit 2: a typo (`prefx`) must not read as a
clean run.

## Output and exit codes

```
LEAK <binary|path|package> <path>[:<line>] <reason>
SUMMARY scanned=N allowed=N findings=N conf=present|absent prefixes=N paths=N allows=N mode=tracked|staged
```

A file can yield more than one LEAK line (e.g. a `.class` under `decompiled/**` is `binary` and `path`).

Typed non-finding states (never a silent zero):

| Line | State |
|---|---|
| `ABSENT-CONF` | No conf: only the built-in binary rule ran. The SUMMARY repeats "path/package rules NOT evaluated". |
| `EMPTY-CONF` | Conf exists with zero directives: same limitation. |
| `EMPTY-INPUT` | Zero files in scope (empty repo / nothing staged): nothing was looked at. |
| `BAD-CONF` | Invalid declaration (exit 2). |

| Exit | Meaning |
|---|---|
| 0 | no findings |
| 1 | findings |
| 2 | usage, not a git work tree, or bad conf |
| 3 | DEGRADED (git missing or file listing failed) |

Modes: `--tracked` (default) = every file git tracks under the target; `--staged` = files added/copied/modified/renamed
in the index. Package declarations are read from the INDEX (`git show :./path`), not the worktree copy, so a staged
scan judges what a commit would send. A target that is a sub-directory of a repo is scanned relative to that
directory only.

## Limits (what a clean run does NOT prove)

- Only the FIRST `package` declaration is read, line-anchored (`^\s*package X`); a declaration inside a block comment
  is not special-cased, and a commented `// package ...` is ignored.
- Vendor-derived code in a NON-vendor package is invisible. Measured at niagara5-research `b8eebcd`:
  `evidence/b118/BDevice.cons-linemapped.java` is `package niagara.driver;` yet imports `com.tridium.*`, and
  `InitProbe.java` is in the default package; neither is flagged (imports are not scanned).
- Decompiled output is recognised only by declared prefix/path, not by decompiler-output heuristics (headers such as
  `// Decompiled by`). A decompiled tree outside a declared path and prefix passes.
- Non-source text artifacts (`.txt`, `.md`, `.ql`) are never inspected for vendor content.
- File names are matched by extension; a renamed `.jar` (e.g. `.zip`) is not a binary finding.
- History is out of scope: a file removed from HEAD but reachable in history is not reported (compare
  `scan-secrets.sh --committed`).
- Without a conf the guard degrades to the binary rule and says so.

## Fleet measurement (2026-10-03, read-only, `--tracked`, `$RESEARCH_HOME` = `$HOME`)

Every existing git target under `TARGETS.md` was scanned; none had a conf yet, so every run printed `ABSENT-CONF`.
Classification by hand:

| Target | Findings | Verdict |
|---|---|---|
| niagara5-research | 1 binary: `poc/n5-hello/gradle/wrapper/gradle-wrapper.jar` | FALSE positive: Gradle's own public wrapper jar, not vendor code. Needs an `allow poc/**/gradle/wrapper/*` line. HEAD has no vendor-package `.java` (fixed by #25 / efd7256). |
| niagara5-research @ `b8eebcd` (scratch clone + conf `prefix javax.baja` / `prefix com.tridium`) | 2 package: `evidence/b118/BQudtUnitTag.cons-linemapped.java:1`, `BSimpleSigningProfile.cons-linemapped.java:1`; plus the gradle jar | TRUE positives for the incident. FALSE negatives: `BDevice.cons-linemapped.java` (package `niagara.driver`) and `InitProbe.java` (default package) leak Tridium code but are not recognised. |
| niagara-research | 1344 binary: 1316 `.class` + 11 `.jar` + 3 `.dll` + 2 `.exe` under `sources/probes`, `.jar` under `codegen/`, `toolshost/`, `sources/sdk-dev-examples`, `.so` under `examinacion-optimizer-4.13/sources`, and `com/tridium/workbench/commands/LinkMarkCommand.class` | Mostly TRUE (vendor-derived or compiled probe artifacts tracked in a repo with a remote); whether each is publishable is a human review per path, not decidable by the tool. `com/tridium/**.class` at repo root is a TRUE vendor-binary leak. The probe jars/classes are authored artifacts: allowlist-or-untrack decision belongs to the owner. |
| niagara-help, COB-IM2, api-paneles, blender-llm, cloudflare, fluke-177x-datos, mini-pc, nave-panccadia, sdd-investigacion, sullair, panccadia-3d-viewer, hisense, three.js research, Pancaddia, HotelHilton, HotelPalace, ford | 0 | Clean on the binary rule only (`ABSENT-CONF`: prefix/path rules not evaluated). |
| module-navigator | exit 2 (not a git work tree) | Typed refusal, correct. |
| all other TARGETS rows | directory absent on this machine | Not scanned; absence is reported by the sweep harness, not by the tool. |

## Slice 2 (deferred)

`research-sdd-init.sh` seeding of the conf and the pre-commit/pre-push hook, CI wiring when `gh repo view` reports
PUBLIC, the registry row, and METHODOLOGY §15 text.
