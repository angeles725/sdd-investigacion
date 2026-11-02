//go:build unix

package verify

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Differential tests for `rsdd verify state`: the frozen legacy verify-state.sh (testdata/state-legacy, the bytes
// of the script and the libraries it sources before the port) and the Go command must print the same stdout,
// the same stderr and exit with the same code from the same fixture. A missing bash, awk, jq, xargs or realpath
// FAILS: a skipped differential proves nothing.

func sdLegacyDir(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", "state-legacy"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func sdEnviron(home string) []string {
	return []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "LC_ALL=C.UTF-8", "RSDD_CLAUDE_PROJECTS_DIR=/nonexistent/rsdd-claude-history"}
}

// sdLegacy runs the frozen script in cwd.
func sdLegacy(t *testing.T, cwd string, args ...string) observed {
	t.Helper()
	cmd := exec.Command("bash", append([]string{filepath.Join(sdLegacyDir(t), "verify-state.sh")}, args...)...)
	cmd.Dir = cwd
	cmd.Env = sdEnviron(t.TempDir())
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("bash: %v", err)
		}
		rc = ee.ExitCode()
	}
	return observed{out.String(), errb.String(), rc}
}

// sdGo runs the Go command in cwd with the same environment and the legacy toolbelt (for check-gap-drift.sh).
func sdGo(t *testing.T, cwd string, toolbelt bool, args ...string) observed {
	t.Helper()
	env := sdEnviron(t.TempDir())
	if toolbelt {
		env = append(env, "RSDD_TOOLBELT_DIR="+sdLegacyDir(t))
	}
	get := func(k string) string {
		for _, e := range env {
			if v, ok := strings.CutPrefix(e, k+"="); ok {
				return v
			}
		}
		return ""
	}
	var out, errb bytes.Buffer
	rc := RunState(args, cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: get, Environ: func() []string { return env },
		Clock: func() time.Time { return time.Time{} }, Cwd: cwd})
	if rc == Stale {
		rc = 1
	}
	return observed{out.String(), errb.String(), rc}
}

// sdCompare runs both on the same arguments and reports any difference.
func sdCompare(t *testing.T, what, cwd string, args ...string) observed {
	t.Helper()
	want := sdNormalize(t, sdLegacy(t, cwd, args...))
	got := sdGo(t, cwd, true, args...)
	same(t, what, want, got)
	return want
}

// sdNormalize applies the intended differences to the legacy observation: bash names the script as it was
// invoked in its own error lines (the Go command prints "verify-state.sh"), and the "[: N: integer expression
// expected" errors of a test over an integer beyond int64 are not reproduced (the comparison is false in both).
func sdNormalize(t *testing.T, o observed) observed {
	t.Helper()
	script := filepath.Join(sdLegacyDir(t), "verify-state.sh")
	var keep []string
	for _, l := range strings.SplitAfter(o.stderr, "\n") {
		if strings.Contains(l, ": line ") && strings.HasSuffix(l, ": integer expression expected\n") {
			continue
		}
		keep = append(keep, strings.Replace(l, script+": line ", "verify-state.sh: line ", 1))
	}
	o.stderr = strings.Join(keep, "")
	return o
}

func sdWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// sdEnvelope renders a research-state.v1 block from key/value pairs.
func sdEnvelope(kv ...string) string {
	var b strings.Builder
	b.WriteString("<!-- research-state.v1 -->\nschema: research-state.v1\n")
	for i := 0; i+1 < len(kv); i += 2 {
		fmt.Fprintf(&b, "%s: %s\n", kv[i], kv[i+1])
	}
	b.WriteString("<!-- /research-state.v1 -->\n")
	return b.String()
}

func sdJoin(parts ...string) string { return strings.Join(parts, "\n") + "\n" }

const sdTable4 = "| Priority | Gap | Type | Status |\n|---|---|---|---|\n"

// sdConsistent is a state whose envelope agrees with an empty corpus.
func sdConsistent(extra ...string) string {
	return sdJoin(append([]string{"# Research State", "", sdEnvelope("covered_blocks", "0", "gaps_closed", "0", "known_gaps", "0", "investigable_open", "0", "requires_execution_open", "0", "blocked_open", "0"),
		"coverage metric: 0 / 0 declared gaps closed", "", "## Gap-backlog (prioritized)", "", sdTable4, "## Blocked gaps", "- none", ""}, extra...)...)
}

// sdRangeCorpus is the corpus of focus-prefix-range.test.sh section 8: FOCUSES.md scopes the root state to the block
// range rng, a second focus owns the prefix ops-, and six x-bloque files, ops-block1 and y-block2 (which shares id B2
// with x-bloque2) sit on disk. cb is the root's declared covered_blocks; extra lines are appended to the root state.
func sdRangeCorpus(t *testing.T, d, cb, rng string, extra ...string) {
	t.Helper()
	sdWrite(t, filepath.Join(d, "FOCUSES.md"), sdJoin("# Focus index", "", "| Focus | Estado | RESEARCH-STATE | Ámbito | Bloques |", "|---|---|---|---|---|",
		"| (base) | stopped | `RESEARCH-STATE.md` | base | "+rng+" |", "| ops | active | `RESEARCH-STATE-ops.md` | ops | ops- |"))
	for i := 1; i <= 6; i++ {
		sdWrite(t, filepath.Join(d, fmt.Sprintf("x-bloque%d.md", i)), "")
	}
	sdWrite(t, filepath.Join(d, "ops-block1.md"), "")
	sdWrite(t, filepath.Join(d, "y-block2.md"), "")
	for _, f := range []struct{ name, covered string }{{"RESEARCH-STATE.md", cb}, {"RESEARCH-STATE-ops.md", "1"}} {
		body := sdJoin("# T — Research State", "", sdEnvelope("covered_blocks", f.covered, "gaps_closed", "0", "known_gaps", "0", "investigable_open", "0", "requires_execution_open", "0", "blocked_open", "0", "deferred_open", "0"),
			"## Gap-backlog (prioritized)", "", sdTable4, "## Stop control", "")
		if f.name == "RESEARCH-STATE.md" {
			body += strings.Join(extra, "\n")
		}
		sdWrite(t, filepath.Join(d, f.name), body)
	}
}

type sdCase struct {
	name  string
	setup func(t *testing.T, d string)
	args  func(d string) []string // default: the corpus dir
}

func (c sdCase) argv(d string) []string {
	if c.args != nil {
		return c.args(d)
	}
	return []string{d}
}

func state(content string) func(t *testing.T, d string) {
	return func(t *testing.T, d string) { sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), content) }
}

func sdCases() []sdCase {
	const goodHooks = `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash $CLAUDE_PROJECT_DIR/.claude/hooks/a.sh"}]}]}}`
	bulletsEnv := func(inv, blocked string) string {
		return sdEnvelope("covered_blocks", "0", "gaps_closed", "0", "known_gaps", "0", "investigable_open", inv, "requires_execution_open", "0", "blocked_open", blocked)
	}
	return []sdCase{
		// arguments and discovery
		{name: "no-args", args: func(string) []string { return nil }, setup: func(*testing.T, string) {}},
		{name: "empty-arg", args: func(string) []string { return []string{""} }, setup: func(*testing.T, string) {}},
		{name: "not-a-dir", args: func(d string) []string { return []string{filepath.Join(d, "nope")} }, setup: func(*testing.T, string) {}},
		{name: "flag-first", args: func(d string) []string { return []string{"--focus", "x", d} }, setup: state(sdConsistent())},
		{name: "unknown-flag", args: func(d string) []string { return []string{d, "--bogus"} }, setup: state(sdConsistent())},
		{name: "focus-without-slug", args: func(d string) []string { return []string{d, "--focus"} }, setup: state(sdConsistent())},
		{name: "focus-empty-slug", args: func(d string) []string { return []string{d, "--focus", ""} }, setup: state(sdConsistent())},
		{name: "focus-absent", args: func(d string) []string { return []string{d, "--focus", "zz"} }, setup: state(sdConsistent())},
		{name: "focus-found", args: func(d string) []string { return []string{d, "--focus", "auth"} }, setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE-auth.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), "no envelope\n")
		}},
		{name: "focus-glob-slug", args: func(d string) []string { return []string{d, "--focus", "a*"} }, setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE-auth.md"), sdConsistent())
		}},
		{name: "focus-in-two-dirs", args: func(d string) []string { return []string{d, "--focus", "auth"} }, setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "b", "RESEARCH-STATE-auth.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, "a", "RESEARCH-STATE-auth.md"), sdConsistent())
		}},
		{name: "no-state", setup: func(t *testing.T, d string) { sdWrite(t, filepath.Join(d, "other.md"), "x\n") }},
		{name: "template-only", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.template.md"), sdConsistent())
		}},
		{name: "state-under-dot-git", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, ".git", "RESEARCH-STATE.md"), sdConsistent())
		}},
		{name: "state-too-deep", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "a", "b", "c", "d", "RESEARCH-STATE.md"), sdConsistent())
		}},
		{name: "state-depth-three", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "a", "b", "c", "RESEARCH-STATE.md"), sdConsistent())
		}},
		{name: "several-states", setup: func(t *testing.T, d string) {
			for _, n := range []string{"RESEARCH-STATE.md", "RESEARCH-STATE-auth.md", "RESEARCH-STATE-db.md", "sub/RESEARCH-STATE-ui.md", "sub/deeper/RESEARCH-STATE.md"} {
				sdWrite(t, filepath.Join(d, n), sdConsistent())
			}
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE-bad.md"), "plain\n")
		}},
		{name: "trailing-slash-target", args: func(d string) []string { return []string{d + "/"} }, setup: state(sdConsistent())},
		{name: "relative-target", args: func(string) []string { return []string{"."} }, setup: state(sdConsistent())},
		{name: "relative-target-sub", args: func(string) []string { return []string{"sub"} }, setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "sub", "RESEARCH-STATE.md"), sdConsistent())
		}},
		{name: "dir-named-like-state", setup: func(t *testing.T, d string) {
			if err := os.MkdirAll(filepath.Join(d, "RESEARCH-STATE.md"), 0o755); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "dangling-state-symlink", setup: func(t *testing.T, d string) {
			if err := os.Symlink("/nonexistent/x.md", filepath.Join(d, "RESEARCH-STATE.md")); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "symlinked-target", args: func(d string) []string { return []string{d + "-link"} }, setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			if err := os.Symlink(d, d+"-link"); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { os.Remove(d + "-link") })
		}},

		// envelope gate and backlog parse
		{name: "no-envelope", setup: state("# Research State\n## Gap-backlog\n")},
		{name: "empty-file", setup: state("")},
		{name: "invalid-priority", setup: state(sdJoin(sdEnvelope(), "## Gap-backlog", sdTable4+"| med | g | w | pending |", "| bogus | h | w | pending |"))},
		{name: "invalid-priority-qualifier", setup: state(sdJoin(sdEnvelope(), "## Gap-backlog", sdTable4+"| urgent (x) | g | w | pending |"))},
		{name: "backlog-heading-absent", setup: state(sdJoin(sdEnvelope(), "# nothing"))},
		{name: "backlog-near-miss-heading", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap backlog", sdTable4+"| high | g | w | pending |"))},
		{name: "backlog-legacy-heading", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Backlog", "- g"))},
		{name: "backlog-oob-rows", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", "", "## Other", sdTable4+"| high | g | w | pending |", "## End"))},
		{name: "backlog-oob-rows-eof", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", "", "## Other", sdTable4+"| high | g | w | pending |"))},
		{name: "backlog-table-without-priority-header", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", "", "## Other", "| a | b | c | d |", "|---|---|---|---|", "| high | g | w | pending |"))},
		{name: "backlog-near-miss-no-header", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog-extra", "| a | b | c | d |", "|---|---|---|---|", "| high | g | w | pending |", "| zzz | g | w | pending |"))},
		{name: "backlog-near-miss-with-header", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Backlog notes", sdTable4+"| high | g | w | pending |", "| zzz | g | w | pending |"))},
		{name: "backlog-five-columns", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "2", "blocked_open", "0"), "## Gap-backlog", "| Priority | ID | Gap | Artifact | Status |", "|---|---|---|---|---|", "| high | G1 | one | a | pending |", "| low | G2 | two | b | **pending** |", "| low | G3 | three | b |"))},
		{name: "backlog-six-columns", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", "| a | b | c | d | e | f |", "|---|---|---|---|---|---|", "| high | g | w | x | y | pending |"))},
		{name: "backlog-qualifier-priority", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high (ctx) | g | w | pending |"))},
		{name: "backlog-covered-pipe", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | g | w | covered | extra |"))},
		{name: "backlog-escaped-pipe", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+`| high | a \| b | w | pending |`))},
		{name: "backlog-deferred-escaped-pipe", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0", "deferred_open", "2"), "## Gap-backlog", sdTable4+`| deferred | a \| b | w | parked |`, `| deferred | c \\| d | w | parked |`))},
		{name: "blocks-history-escaped-pipe-before-block-column", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(strings.Replace(sdConsistent("## Iteration history", "| # | Date | Block | Gap |", "|---|---|---|---|", `| 1 | d \| e | B4 | g |`, `| 2 | d \| e | B4, B5 | g |`, "", "## Other"), "covered_blocks: 0", "covered_blocks: 2", 1), "<!-- /research-state.v1 -->", "block_scope: shared-global\n<!-- /research-state.v1 -->", 1))
			sdWrite(t, filepath.Join(d, "x-block4.md"), "b\n")
		}},
		{name: "backlog-closed-class", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0", "deferred_open", "1"), "## Gap-backlog", sdTable4+"| ~~high~~ | g | w | pending |", "| — | G9 | w | x |", "| deferred | d | w | parked |", "| deferred | ~~e~~ | w | parked |"))},
		{name: "backlog-alignment-colons", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", "| Priority | Gap | Type | Status |", "|:---|:---:|---:|---|", "| high | g | w | pending |"))},
		{name: "backlog-separator-bad-width", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", "| a | b | c |", "|---|---|---|", "| high | g | w |"))},
		{name: "backlog-prose-with-pipes", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", "- a | b | c", "|", "||", "|||", "text | text"))},
		{name: "backlog-tab-in-cells", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | a\tb | w | pending\tx |", "| high |  | w | pending |"))},
		{name: "backlog-crlf", setup: state(strings.ReplaceAll(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | g | w | pending |"), "\n", "\r\n"))},

		// envelope checks
		{name: "env-consistent", setup: state(sdConsistent())},
		{name: "env-covered-mismatch", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 3", 1))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
		}},
		{name: "env-covered-missing", setup: state(strings.Replace(sdConsistent(), "covered_blocks: 0\n", "", 1))},
		{name: "env-investigable-stale", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | g | w | pending |"))},
		{name: "env-blocked-stale", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4, "## Blocked gaps", "- g — needs: key"))},
		{name: "env-full-coverage-hazard", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "gaps_closed", "4", "known_gaps", "4", "investigable_open", "1", "blocked_open", "0", "requires_execution_open", "0"), "## Gap-backlog", sdTable4+"| high | g | w | pending |"))},
		{name: "env-requires-exec-zero-hazard", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0", "requires_execution_open", "0"), "## Gap-backlog", sdTable4+"| high | g | w | requires-execution |"))},
		{name: "env-requires-exec-mismatch", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0", "requires_execution_open", "3"), "## Gap-backlog", sdTable4+"| high | g | w | requires-execution |", "| high | h | w | **requires-execution** (x) |", "| high | i | w | requires-execution2 |", "| high | j | w | ~~requires-execution~~ |"))},
		{name: "env-requires-exec-not-int", setup: state(sdConsistent("x"))},
		{name: "env-deferred-mismatch", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0", "requires_execution_open", "0", "deferred_open", "5"), "## Gap-backlog", sdTable4+"| deferred | g | w | parked |"))},
		{name: "env-deferred-missing", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0", "requires_execution_open", "0"), "## Gap-backlog", sdTable4+"| deferred | g | w | parked |", "| deferred | h | w | parked |"))},
		{name: "env-deferred-bad-widths", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0", "requires_execution_open", "0", "deferred_open", "0"), "## Gap-backlog", "| p | a | b | c | d | e |", "|---|---|---|---|---|---|", "| deferred | g | w | x | y | parked |", "", "| P | a | b | c |", "|---|---|---|---|", "| deferred | g | w | parked | extra |", "## Other", "| P | a | b | c |", "|---|---|---|---|", "| deferred | g | w | parked |"))},
		{name: "env-identity-stale", setup: state(sdConsistent("x"))},
		{name: "env-identity-mismatch", setup: state(strings.Replace(sdConsistent(), "known_gaps: 0", "known_gaps: 9", 1))},
		{name: "env-identity-with-in-place-blocked", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "gaps_closed", "1", "known_gaps", "9", "investigable_open", "0", "blocked_open", "0", "requires_execution_open", "0"), "## Gap-backlog", sdTable4+"| high | G7 first | w | blocked (needs key) |", "| high | G8 second | w | blocked-on-hw |"))},
		{name: "env-identity-leading-zero-octal", setup: state(strings.Replace(sdConsistent(), "gaps_closed: 0", "gaps_closed: 010", 1))},
		{name: "env-identity-octal-abort", setup: state(strings.Replace(sdConsistent(), "gaps_closed: 0", "gaps_closed: 08", 1))},
		{name: "env-identity-huge", setup: state(strings.Replace(sdConsistent(), "known_gaps: 0", "known_gaps: 99999999999999999999", 1))},
		{name: "env-crlf", setup: state(strings.ReplaceAll(sdConsistent(), "\n", "\r\n"))},
		{name: "env-two-envelopes", setup: state(sdConsistent() + sdEnvelope("covered_blocks", "9"))},
		{name: "env-indented-keys", setup: state(strings.ReplaceAll(sdConsistent(), "covered_blocks:", "   covered_blocks:"))},
		{name: "env-no-space-after-colon", setup: state(strings.Replace(sdConsistent(), "blocked_open: 0", "blocked_open:0", 1))},
		{name: "env-undocumented-warn", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "undocumented_findings: 4\n<!-- /research-state.v1 -->", 1))},
		{name: "env-undocumented-fail", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "undocumented_findings: 7\n<!-- /research-state.v1 -->", 1))},
		{name: "env-undocumented-unparseable", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "undocumented_findings:7\n<!-- /research-state.v1 -->", 1))},
		{name: "env-undocumented-word", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "undocumented_findings: many\n<!-- /research-state.v1 -->", 1))},
		{name: "env-bsr-warn", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "blocks_since_retro: 11\n<!-- /research-state.v1 -->", 1))},
		{name: "env-bsr-bad", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "blocks_since_retro: x\n<!-- /research-state.v1 -->", 1))},
		{name: "env-bsr-ok", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "blocks_since_retro: 10\n<!-- /research-state.v1 -->", 1))},
		{name: "env-block-scope-bad", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "block_scope: weird\n<!-- /research-state.v1 -->", 1))},
		{name: "env-block-scope-typo", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "block_scope:shared-global\n<!-- /research-state.v1 -->", 1))},
		{name: "env-block-scope-per-focus", setup: state(strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "block_scope: per-focus\n<!-- /research-state.v1 -->", 1))},

		// coverage, prose checks
		{name: "stale-mirror", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "gaps_closed", "0", "known_gaps", "5", "investigable_open", "3", "blocked_open", "0", "requires_execution_open", "0"), "coverage metric: 5 / 5 declared gaps closed", "## Gap-backlog", sdTable4+"| high | a | w | pending |", "| high | b | w | pending |", "| high | c | w | pending |", "## Stop control", "- **Open gaps — read-only investigable**: 3"))},
		{name: "coverage-bold-label", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "**Coverage metric**: 7 /  7 gaps closed", "## Gap-backlog", sdTable4))},
		{name: "coverage-header-shadow", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "| Gap closed | 3 / 4 |", "Coverage metric: 9/10", "## Gap-backlog", sdTable4))},
		{name: "coverage-denominators", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "coverage metric: 16/16", "coverage metric: 22 / 16", "coverage metric: 26/26", "gaps closed: 05/05", "declared gaps closed 5/5", "## Iteration history", "coverage metric: 1/99", "## Gap-backlog", sdTable4))},
		{name: "coverage-denominators-same", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "coverage metric: 1/5", "coverage metric: 4/5", "## Gap-backlog", sdTable4))},
		{name: "covered-claim-mismatch", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent("Covered blocks: 9 so far"), "covered_blocks: 0", "covered_blocks: 1", 1))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
		}},
		{name: "covered-claim-suppressed", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(strings.Replace(sdConsistent("Covered blocks: 9 so far"), "covered_blocks: 0", "covered_blocks: 1", 1), "<!-- /research-state.v1 -->", "known_stale_warns: a, check-2-covered-blocks ,b\n<!-- /research-state.v1 -->", 1))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
		}},
		{name: "stop-control-forms", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4, "## Stop control", "- **Open gaps — read-only investigable**: 4   <- hits 0", "read-only investigable: **9** (G74 list) investigable: 3"))},
		{name: "stop-control-match", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4, "## Stop control", "- **Open gaps — read-only investigable**: 0"))},
		{name: "stretch-missing", setup: state(sdConsistent("## Stretch goal", "- realistic: 5", ""))},
		{name: "stretch-complete", setup: state(sdConsistent("## Stretch goal", "- **Realistic**: 5", "stretch: 9", ""))},
		{name: "stretch-empty", setup: state(sdConsistent("## Stretch goal", ""))},
		{name: "retyped-spelling-rows", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | live | w | pending |", "| medium | rt-first | w | re-typed [Block 141] — blocked-pending-native-gate |", "| low | rt-mid | w | **retyped** (moved) |", "| low | rt-last | w | Re-Typed |"))},
		{name: "retyped-rows", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | first | w | re-typed |", "| high | ~~second~~ | w | retyped |", "| high | third | w | **re-typed** (x) |", "| high | fourth | w | pending-ish |"))},
		{name: "index-placeholder", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 1", 1))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
			sdWrite(t, filepath.Join(d, "INDEX.md"), "# <SUBJECT> on <YYYY-MM-DD>\n")
		}},
		{name: "index-placeholder-suppressed", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 1", 1), "<!-- /research-state.v1 -->", "known_stale_warns: p7-index-placeholder\n<!-- /research-state.v1 -->", 1))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
			sdWrite(t, filepath.Join(d, "INDEX.md"), "# <SUBJECT>\n")
		}},
		{name: "index-clean", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 1", 1))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
			sdWrite(t, filepath.Join(d, "INDEX.md"), "# clean <lower> text\n")
		}},

		// blocked sections
		{name: "blocked-bullets", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "3"), "## Gap-backlog", sdTable4+"| high | alpha | w | pending |", "| high | beta | w | pending |", "## Blocked gaps", "- beta — needs: a key", "- gamma - needs: x; tried: y; unblock: z", "- delta needs: x", "- none", "  - epsilon — needs: nested", "-nospace — needs: q", "## Non-investigable gaps", "- zeta — needs: hw", "## Blocked / requires-execution gaps", "- eta — needs: build"))},
		{name: "blocked-prose-form", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "1"), "## Gap-backlog", sdTable4, "## Blocked gaps", "G54 — description. **needs:** the thing", "tried: nothing"))},
		{name: "blocked-child-gaps", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "2"), "## Gap-backlog", sdTable4, "## Child gaps surfaced at close", "- one — `blocked-on-x`.", "  `needs:` something", "", "- ~~two~~ — needs: gone", "- three CLOSED — needs: x", "- four NOT CLOSED — needs: y", "- five not yet closed needs: z", "- six no longer CLOSED needs: z", "- seven ✅ needs: w", "- eight [Closed] needs: w", "- nine — needs: v", "- ten NO-CLOSED needs: u", "- eleven ENCLOSED needs: u", "- twelve CERRADO needs: u", "- thirteen no repro — CLOSED needs: u", "- fourteen NOT - CLOSED needs: t", "- **~~fifteen~~** needs: s"))},
		{name: "blocked-missing-tried-unblock", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "5"), "## Gap-backlog", sdTable4, "## Blocked gaps", "- a — needs: x", "- b — needs: x; tried: y", "- c — unblock: a · owner: b · cost: c; needs: x", "  - tried: indented", "  - unblock: plan", "- d — needs: x", "", "  - unblock: after blank", "", "prose para **needs:** thing", "other line unblock: late", "", "para two **needs:** x **tried:** y unblock: ok", "- e — needs: x unblock: p"))},
		{name: "blocked-wall-rows", setup: state(sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "1"), "## Gap-backlog", sdTable4+"| high | G1 first | w | blocked-on-hw |", "| high | G2 second | w | blocked (needs key) unblock: plan |", "| high | G3 third | w | unavailable: no |", "| high | G4 fourth | w | refused, nope |", "| high | G5 fifth | w | not-extracted |", "| high | named | w | not-buildable |", "| high | G9 nine | w | **blocked** |", "| high | ~~G6~~ | w | blocked |", "| high | G7 | w | blocked ✅ |", "## Blocked gaps", "- named — needs: x", "- G5 other text — needs: y"))},

		// blocks on disk, focuses
		{name: "blocks-prefixed-by-name", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE-auth.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 2", 1))
			for _, n := range []string{"auth-block1.md", "auth-block2-extra.md", "db-block1.md", "blocked-notes.md", "auth-blockx.md", "auth-block3.txt"} {
				sdWrite(t, filepath.Join(d, n), "b\n")
			}
		}},
		{name: "blocks-cannot-see-fail", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE-auth.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 4", 1))
			sdWrite(t, filepath.Join(d, "db-block1.md"), "b\n")
		}},
		{name: "blocks-cannot-see-pass-warn", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE-auth.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, "db-block1.md"), "b\n")
		}},
		{name: "blocks-shared-global-ok", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE-auth.md"), strings.Replace(strings.Replace(sdConsistent("## Covered blocks", "B1, B2 and B2 again", ""), "covered_blocks: 0", "covered_blocks: 2", 1), "<!-- /research-state.v1 -->", "block_scope: shared-global\n<!-- /research-state.v1 -->", 1))
			for _, n := range []string{"auth-block1.md", "db-block2.md", "db-block3.md"} {
				sdWrite(t, filepath.Join(d, n), "b\n")
			}
		}},
		{name: "blocks-shared-global-mismatch", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(strings.Replace(sdConsistent("## Covered blocks", "B1 B2 B3", ""), "covered_blocks: 0", "covered_blocks: 9", 1), "<!-- /research-state.v1 -->", "block_scope: shared-global\n<!-- /research-state.v1 -->", 1))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
			sdWrite(t, filepath.Join(d, "x-block2.md"), "b\n")
			sdWrite(t, filepath.Join(d, "INDEX.md"), "<KIT>\n")
		}},
		{name: "blocks-shared-global-from-history", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(strings.Replace(sdConsistent("## Iteration history", "| # | Date | Block | Gap |", "|---|---|---|---|", "| 1 | d | B4 | g |", "| 2 | d | B4, B5 | g |", "| 3 | d | | g |", "", "## Other"), "covered_blocks: 0", "covered_blocks: 2", 1), "<!-- /research-state.v1 -->", "block_scope: shared-global\n<!-- /research-state.v1 -->", 1))
			sdWrite(t, filepath.Join(d, "x-block4.md"), "b\n")
		}},
		{name: "blocks-shared-global-unverifiable", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "<!-- /research-state.v1 -->", "block_scope: shared-global\n<!-- /research-state.v1 -->", 1))
			sdWrite(t, filepath.Join(d, "x-block4.md"), "b\n")
		}},
		{name: "focuses-prefix-cell", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 1", 1))
			sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Prefix |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | `cob-block<N>.md` |\n")
			sdWrite(t, filepath.Join(d, "cob-block1.md"), "b\n")
			sdWrite(t, filepath.Join(d, "other-block1.md"), "b\n")
		}},
		{name: "focuses-range", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 2", 1))
			sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Blocks |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | B1–B3 |\n")
			for _, n := range []string{"a-block1.md", "a-block3.md", "b-block9.md", "a-block11.md"} {
				sdWrite(t, filepath.Join(d, n), "b\n")
			}
		}},
		{name: "focuses-range-cannot-see", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 2", 1))
			sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Blocks |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | B1-B3 |\n")
			sdWrite(t, filepath.Join(d, "a-block9.md"), "b\n")
		}},
		{name: "focuses-range-pass-warn", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Blocks |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | B1–B3 |\n")
			sdWrite(t, filepath.Join(d, "a-block9.md"), "b\n")
		}},
		{name: "focuses-range-families-and-missing", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 3", 1))
			sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Blocks |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | B1–B20 |\n")
			for _, n := range []string{"a-block1.md", "b-block5.md", "a-block20.md"} {
				sdWrite(t, filepath.Join(d, n), "b\n")
			}
		}},
		{name: "range-corpus-declared-matches-ids", setup: func(t *testing.T, d string) { sdRangeCorpus(t, d, "3", "B2–B4") }},
		{name: "range-corpus-stale-corpus-wide-count", setup: func(t *testing.T, d string) { sdRangeCorpus(t, d, "7", "B2–B4") }},
		{name: "range-corpus-malformed-range", setup: func(t *testing.T, d string) { sdRangeCorpus(t, d, "7", "B9–B3") }},
		{name: "range-corpus-cannot-see", setup: func(t *testing.T, d string) { sdRangeCorpus(t, d, "4", "B50–B60") }},
		{name: "range-corpus-cannot-see-declared-zero", setup: func(t *testing.T, d string) { sdRangeCorpus(t, d, "0", "B50–B60") }},
		{name: "range-corpus-unit-in-every-message", setup: func(t *testing.T, d string) {
			sdRangeCorpus(t, d, "3", "B2–B4", "Covered blocks: 9")
			sdWrite(t, filepath.Join(d, "INDEX.md"), "# Index\n<SUBJECT> placeholder\n")
		}},
		{name: "focuses-range-malformed", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Blocks |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | B9–B2 |\n")
		}},
		{name: "symlink-and-nonregular-md", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), strings.Replace(sdConsistent(), "covered_blocks: 0", "covered_blocks: 1", 1))
			sdWrite(t, filepath.Join(d, "real", "x-block1.md"), "b\n")
			if err := os.Symlink(filepath.Join(d, "real", "x-block1.md"), filepath.Join(d, "y-block1.md")); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(d, "z-block2.md"), 0o755); err != nil {
				t.Fatal(err)
			}
			sdWrite(t, filepath.Join(d, "x-block1.md"), "b\n")
		}},

		// gap drift
		{name: "gap-drift-rows", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdJoin(sdEnvelope("covered_blocks", "1", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | B1-G1 something wholly different about cats | w | pending |"))
			sdWrite(t, filepath.Join(d, "x-block1.md"), "# b\n\n## Child gaps\n- B1-G1: how do the widgets frobnicate the sprockets under load\n")
		}},
		{name: "gap-drift-no-bullet-source", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | B7-G1 text | w | pending |"))
		}},

		// P8 hook set
		{name: "hooks-absent", setup: state(sdConsistent())},
		{name: "hooks-dir-clean", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "a.sh"), "#!/bin/bash\necho hi\n")
		}},
		{name: "hooks-dir-empty", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			if err := os.MkdirAll(filepath.Join(d, ".claude", "hooks"), 0o755); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "hooks-placeholders", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "a.sh"), "# <KIT> comment\nKIT=<KIT>/x <TARGET> <prefix>\n  # <SUBJECT>\nX=\"<path to binaries/decompiled output/source code of the system under study>\"\n")
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "b.py"), "x = '<SUBJECT>'\n")
		}},
		{name: "hooks-settings-and-dir-dedup", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), goodHooks)
			sdWrite(t, filepath.Join(d, ".claude", "settings.local.json"), `{"hooks":{"Stop":[{"command":"python3 tools/hooks/x.py --flag"},{"command":"env bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/a.sh\" arg"},{"command":"echo hi"},{"command":"cat /etc/hostname"},{"command":"./missing.sh"}]}}`)
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "a.sh"), "<TARGET>\n")
			sdWrite(t, filepath.Join(d, "tools", "hooks", "x.py"), "<prefix>\n")
		}},
		{name: "hooks-settings-malformed", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"hooks":`)
			sdWrite(t, filepath.Join(d, ".claude", "settings.local.json"), `[1,2]`)
		}},
		{name: "hooks-settings-empty-and-null", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), "")
			sdWrite(t, filepath.Join(d, ".claude", "settings.local.json"), "null")
		}},
		{name: "hooks-settings-no-commands", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"permissions":{}}`)
		}},
		{name: "hooks-settings-unresolvable-only", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"hooks":{"a":{"command":"echo hi"},"b":{"command":false},"c":{"command":""},"d":{"command":"'unclosed quote x.sh"}}}`)
		}},
		{name: "hooks-settings-quoting", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"hooks":{"a":{"command":"bash \"$CLAUDE_PROJECT_DIR/h h.sh\""},"b":{"command":"bash $CLAUDE_PROJECT_DIR/h\\ h.sh"},"c":{"command":"a b 'c d"},"d":{"command":"bash 'q.sh'\nx.sh"},"e":{"command":"-x --y z.sh"}}}`)
			sdWrite(t, filepath.Join(d, "h h.sh"), "<KIT>\n")
			sdWrite(t, filepath.Join(d, "q.sh"), "<KIT>\n")
		}},
		{name: "hooks-settings-nested-and-order", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"hooks":{"b":{"command":"b.sh","c":[{"command":"c.sh"}]},"a":{"command":"a.sh"},"z":{"command":"a.sh","command":"z.sh"}}}`)
			for _, n := range []string{"a.sh", "b.sh", "c.sh", "z.sh"} {
				sdWrite(t, filepath.Join(d, n), "<TARGET>\n")
			}
		}},
		{name: "hooks-settings-non-string-commands", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"hooks":{"a":{"command":["x.sh","y"]},"b":{"command":true},"c":{"command":{"k":[1,{"z":null}],"e":[],"o":{}}},"d":{"command":7}}}`)
		}},
		{name: "hooks-symlink-out-of-root", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			outside := t.TempDir()
			sdWrite(t, filepath.Join(outside, "evil.sh"), "<KIT>\n")
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "ok.sh"), "<KIT>\n")
			if err := os.Symlink(filepath.Join(outside, "evil.sh"), filepath.Join(d, ".claude", "hooks", "evil.sh")); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("/nonexistent/dangling.sh", filepath.Join(d, ".claude", "hooks", "dangling.sh")); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("../../tools", filepath.Join(d, ".claude", "hooks", "dirlink")); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("ok.sh", filepath.Join(d, ".claude", "hooks", "inroot-link.sh")); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("missing-inroot", filepath.Join(d, ".claude", "hooks", "dangling-inroot")); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(d, "tools"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(d, ".claude", "hooks", "subdir"), 0o755); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "hooks-dir-is-symlink", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, "real-hooks", "a.sh"), "<KIT>\n")
			if err := os.MkdirAll(filepath.Join(d, ".claude"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("../real-hooks", filepath.Join(d, ".claude", "hooks")); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "hooks-settings-dotdot-and-escape", setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"hooks":{"a":{"command":"bash ../outside.sh"},"b":{"command":"bash $CLAUDE_PROJECT_DIR/sub/../in.sh"},"c":{"command":"bash $CLAUDE_PROJECT_DIR/../outside.sh"}}}`)
			sdWrite(t, filepath.Join(d, "in.sh"), "<KIT>\n")
			sdWrite(t, filepath.Join(d, "sub", "x"), "")
			sdWrite(t, filepath.Join(filepath.Dir(d), filepath.Base(d)+"-outside.sh"), "<KIT>\n")
			sdWrite(t, filepath.Join(filepath.Dir(d), "outside.sh"), "<KIT>\n")
			t.Cleanup(func() { os.Remove(filepath.Join(filepath.Dir(d), "outside.sh")) })
		}},
		{name: "hooks-claude-in-parent", args: func(d string) []string { return []string{filepath.Join(d, "corpus")} }, setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "corpus", "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "a.sh"), "<KIT>\n")
		}},
		{name: "hooks-claude-in-parent-relative", args: func(string) []string { return []string{"corpus"} }, setup: func(t *testing.T, d string) {
			sdWrite(t, filepath.Join(d, "corpus", "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "a.sh"), "<KIT>\n")
		}},
		{name: "hooks-unreadable-settings", setup: func(t *testing.T, d string) {
			if os.Geteuid() == 0 {
				t.Skip("root reads mode-000 files")
			}
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), goodHooks)
			if err := os.Chmod(filepath.Join(d, ".claude", "settings.json"), 0); err != nil {
				t.Fatal(err)
			}
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "u.sh"), "<KIT>\n")
			if err := os.Chmod(filepath.Join(d, ".claude", "hooks", "u.sh"), 0); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "hooks-unreadable-dir", setup: func(t *testing.T, d string) {
			if os.Geteuid() == 0 {
				t.Skip("root reads mode-000 directories")
			}
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			sdWrite(t, filepath.Join(d, ".claude", "hooks", "u.sh"), "<KIT>\n")
			if err := os.Chmod(filepath.Join(d, ".claude", "hooks"), 0); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { os.Chmod(filepath.Join(d, ".claude", "hooks"), 0o755) })
		}},
		{name: "unreadable-state", setup: func(t *testing.T, d string) {
			if os.Geteuid() == 0 {
				t.Skip("root reads mode-000 files")
			}
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdConsistent())
			if err := os.Chmod(filepath.Join(d, "RESEARCH-STATE.md"), 0); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "bulk-envelope-values", setup: state(sdConsistent("x"))},
		{name: "bullets-envelope-helper", setup: state(sdJoin(bulletsEnv("0", "0"), "## Gap-backlog", sdTable4))},
	}
}

func TestDifferentialState(t *testing.T) {
	for _, c := range sdCases() {
		t.Run(c.name, func(t *testing.T) {
			d := filepath.Join(t.TempDir(), "corpus")
			if err := os.MkdirAll(d, 0o755); err != nil {
				t.Fatal(err)
			}
			c.setup(t, d)
			// relative arguments resolve against the corpus parent, absolute ones are used as written
			cwd := d
			args := c.argv(d)
			if c.name == "relative-target-sub" || c.name == "hooks-claude-in-parent-relative" {
				cwd = d
			}
			if c.name == "no-args" || c.name == "empty-arg" {
				cwd = d
			}
			sdCompare(t, c.name, cwd, args...)
		})
	}
}
