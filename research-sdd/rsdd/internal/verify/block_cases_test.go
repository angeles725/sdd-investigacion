//go:build unix

package verify

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// The case table of the verify-block port. Every case is run by the golden test (against the recorded legacy
// output) and by the differential test (against the live legacy script). Literals use ~ for a backtick.
// Sections follow the script: usage and flags, marker tally, Type grammar, citation forms, short forms,
// probe/jar/synth, nonpath, roots, artifact cites, extern-check, possibility-first, OCR, empty digests,
// ephemeral paths, SCRIPTS-MANIFEST, back-pointers.

func q(s string) string { return strings.ReplaceAll(s, "~", "`") }

// lines joins lines with newlines and ends the text with one.
func lines(ls ...string) string { return q(strings.Join(ls, "\n") + "\n") }

// nLines is a file of n numbered lines.
func nLines(n int) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "line %d\n", i)
	}
	return b.String()
}

func one(name, block string, args ...string) blockCase {
	return blockCase{name: name, files: map[string]string{"b/block.md": q(block)}, args: append([]string{"b/block.md"}, args...)}
}

func withFiles(c blockCase, files map[string]string) blockCase {
	for k, v := range files {
		c.files[k] = v
	}
	return c
}

func withEnv(c blockCase, kv ...string) blockCase {
	c.env = map[string]string{}
	for i := 0; i+1 < len(kv); i += 2 {
		c.env[kv[i]] = kv[i+1]
	}
	return c
}

func gitInit(t testing.TB, dir string) {
	t.Helper()
	cmd := exec.Command("git", "init", "-q", dir)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, out)
	}
}

func blockCases() []blockCase {
	var cs []blockCase
	add := func(c ...blockCase) { cs = append(cs, c...) }

	// ---- usage, flags, environment ----
	add(
		blockCase{name: "usage-no-args", files: map[string]string{}},
		blockCase{name: "usage-missing-file", files: map[string]string{}, args: []string{"nope.md"}},
		blockCase{name: "usage-empty-arg", files: map[string]string{}, args: []string{""}},
		blockCase{name: "usage-dir-as-block", files: map[string]string{"d/x": "x"}, args: []string{"d"}},
		blockCase{name: "flag-ephemeral-bad", files: map[string]string{"b.md": "x\n"}, args: []string{"--ephemeral=maybe", "b.md"}},
		blockCase{name: "flag-ephemeral-bare", files: map[string]string{"b.md": "x\n"}, args: []string{"--ephemeral", "b.md"}},
		blockCase{name: "flag-ephemeral-empty", files: map[string]string{"b.md": "x\n"}, args: []string{"--ephemeral=", "b.md"}},
		blockCase{name: "flag-backptr-bad", files: map[string]string{"b.md": "x\n"}, args: []string{"--backptr=none", "b.md"}},
		blockCase{name: "flag-backptr-bare", files: map[string]string{"b.md": "x\n"}, args: []string{"--backptr", "b.md"}},
		blockCase{name: "flag-bad-after-good", files: map[string]string{"b.md": "x\n"}, args: []string{"--extern-check", "--backptr=zz", "--ephemeral=bad", "b.md"}},
		blockCase{name: "flag-after-block", files: map[string]string{"b.md": "x\n"}, args: []string{"b.md", "--extern-check", "--backptr=off"}},
		blockCase{name: "target-arg-empty", files: map[string]string{"b/block.md": "x\n"}, args: []string{"b/block.md", ""}},
		blockCase{name: "target-arg-extra", files: map[string]string{"b/block.md": "x\n", "t/x": "1"}, args: []string{"b/block.md", "t", "ignored", "more"}},
		blockCase{name: "block-bare-name", files: map[string]string{"block.md": "[CERT] a\n"}, args: []string{"block.md"}},
		blockCase{name: "block-dot-slash", files: map[string]string{"block.md": "[CERT] a\n"}, args: []string{"./block.md"}},
		blockCase{name: "block-abs-dir-target-dotdot", files: map[string]string{"a/b/block.md": "[CERT] a\n"}, args: []string{"a/../a/b/block.md"}},
		blockCase{name: "block-space-name", files: map[string]string{"a b/my block.md": "[CERT] a `x.go:1`\n", "a b/x.go": "1\n"}, args: []string{"a b/my block.md"}},
		blockCase{name: "block-empty-file", files: map[string]string{"b/block.md": ""}, args: []string{"b/block.md"}},
		blockCase{name: "block-no-final-newline", files: map[string]string{"b/block.md": "[CERT] a [INFER] b"}, args: []string{"b/block.md"}},
		blockCase{name: "block-crlf", files: map[string]string{"b/block.md": "> Type: evidence\r\n---\r\n[CERT] a ~x.go:1~\r\n"}, args: []string{"b/block.md"}},
	)
	for _, v := range []string{"0", "1", "2", "", "warn", " 0", "00"} {
		add(withEnv(blockCase{name: "env-ephemeral-" + v, files: map[string]string{"b.md": "see /tmp/x.log\n"}, args: []string{"b.md"}}, "RSDD_STRICT_EPHEMERAL", v))
	}
	add(
		withEnv(blockCase{name: "env-ephemeral-0-flag-fail", files: map[string]string{"b.md": "see /tmp/x.log\n"}, args: []string{"--strict-ephemeral", "b.md"}}, "RSDD_STRICT_EPHEMERAL", "0"),
		withEnv(blockCase{name: "env-ephemeral-1-flag-warn", files: map[string]string{"b.md": "see /tmp/x.log\n"}, args: []string{"--ephemeral=warn", "b.md"}}, "RSDD_STRICT_EPHEMERAL", "1"),
		blockCase{name: "flag-ephemeral-last-wins", files: map[string]string{"b.md": "see /tmp/x.log\n"}, args: []string{"--ephemeral=warn", "--ephemeral=fail", "b.md"}},
		blockCase{name: "flag-ephemeral-last-wins-2", files: map[string]string{"b.md": "see /tmp/x.log\n"}, args: []string{"--strict-ephemeral", "--ephemeral=warn", "b.md"}},
	)

	// ---- marker tally, legend fence, ratio ----
	add(
		one("tally-legend", lines("# Block 1 — t", "", "> Method: [CERT] = verified by me; [CERT-a] = sub-agent cite; [INFER] = deduction.", "", "---", "", "## 1.1 claim one [CERT]", "The class extends BComponent [CERT].", "It probably caches [INFER].")),
		one("tally-backtick-claims", lines("# Block 2 — t", "", "> Method: ~[CERT]~ = verified; ~[INFER]~ = deduction.", "", "---", "", "## 2.1 ~[CERT]~", "Extends X ~[CERT]~.", "Wraps Y ~[CERT]~.")),
		one("tally-nofence", lines("# Block 3 — t", "Just body. Extends X [CERT]. Guesses Y [INFER].")),
		one("tally-ratio", lines("# Block 4 — t", "", "> Method: [CERT] = x; [INFER] = y.", "", "---", "", "Body: a [CERT]. b [CERT]. c [INFER].")),
		one("tally-multifence", lines("# Block 5 — t", "", "> Method: [CERT] = x.", "", "---", "", "## 5.1 first [CERT]", "---", "## 5.2 second [CERT]", "---", "## 5.3 third [CERT]")),
		one("tally-setext-before-legend", lines("# Block 6 — t", "", "Intro heading", "---", "", "> Method: [CERT] = def.", "", "---", "", "Body a [CERT]. Body b [CERT].")),
		one("tally-frontmatter", lines("---", "title: t", "---", "", "# Block 7 — t", "", "> Method: [CERT] = def.", "", "---", "", "Body a [CERT]. Body b [CERT]. Body c [CERT].")),
		one("tally-bodyquote-unfenced", lines("## 1. real [CERT]. also [CERT].", "", "> §14 quote: a prior [CERT] retracted.", "", "---", "", "## 2. more [CERT].")),
		one("tally-unfenced-legend", lines("> Method: [CERT] = x; [INFER] = y.", "", "## 1. claim [CERT]. claim [CERT].", "", "> §14 quote referencing [CERT].", "", "---", "", "## 2. more [CERT].")),
		one("tally-h2-before-quote", lines("## 0 intro", "> Method: [CERT] = x.", "---", "[CERT] body")),
		one("tally-h3-not-heading", lines("> legend [CERT]", "### sub", "---", "[CERT] a [INFER] b")),
		one("tally-fence-trailing-space", lines("> legend [CERT]", "---   ", "[CERT] a")),
		one("tally-fence-needs-dashes-only", lines("> legend [CERT]", "--- x", "---", "[CERT-hw] a [CERT-live] b [CERT-doc] c [CERT-web] d [CERT-a] e [INFER] f [INFER]")),
		one("tally-all-markers-one-line", "[CERT][CERT][CERT-hw][CERT-live][CERT-doc][CERT-web][CERT-a][INFER][INFER]\n"),
		one("tally-indented-quote", lines("  > legend [INFER]", "---", "[INFER] [INFER] [CERT]")),
		one("tally-no-markers", lines("# nothing here")),
		one("ratio-infer-only", lines("[INFER] a", "[INFER] b")),
		one("ratio-third", lines("[CERT] a", "[INFER] b", "[INFER] c")),
		one("ratio-rounding-half", lines("[CERT] a [CERT] b [CERT] c [CERT] d [CERT] e [CERT] f [CERT] g [CERT] h", "[INFER] a")),
		one("ratio-big", lines("[CERT] a [CERT] b [CERT] c", "[INFER] x [INFER] y [INFER] z [INFER] w [INFER] v [INFER] u [INFER] t")),
	)
	cs = append(cs, citeCases()...)
	cs = append(cs, scanCases()...)
	cs = append(cs, backptrCases()...)
	cs = append(cs, genCases()...)
	return cs
}

// argsOnly is a case whose files are all given by withFiles and whose arguments are exactly args.
func argsOnly(name string, args ...string) blockCase {
	return blockCase{name: name, files: map[string]string{}, args: args}
}

// deny makes path unreadable (mode 0) for the test and restores a usable mode before the temporary directory
// is removed.
func deny(t testing.TB, path string) error {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	mode := st.Mode().Perm()
	t.Cleanup(func() { _ = os.Chmod(path, mode|0o700) })
	return os.Chmod(path, 0)
}
