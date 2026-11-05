package verify

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// runHook runs `rsdd verify registry-hook --kit <kit> args...` in process and returns the envelope's
// additionalContext (or the raw stdout when it is not an envelope).
func (k *vrKit) runHook(env map[string]string, args ...string) (ctx, raw string, rc int) {
	k.t.Helper()
	var out, errb bytes.Buffer
	e := k.env(env)
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:     func(key string) string { return e[key] },
		Environ: func() []string { return nil },
		Clock:   func() time.Time { return time.Unix(0, 0) },
		Cwd:     k.root,
	}
	rc = RunRegistryHook(append([]string{"--kit", k.kit}, args...), s)
	if errb.Len() != 0 {
		k.t.Errorf("hook stderr %q, want none (a hook speaks only through its envelope)", errb.String())
	}
	var env2 struct {
		H struct {
			Event string `json:"hookEventName"`
			Ctx   string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal(out.Bytes(), &env2); err != nil || env2.H.Event != "SessionStart" {
		return "", out.String(), rc
	}
	return env2.H.Ctx, out.String(), rc
}

func TestRegistryHookHeadersAndExit(t *testing.T) {
	t.Parallel()
	t.Run("ok", func(t *testing.T) {
		k := newVRKit(t)
		k.blocks("alpha", 3)
		k.put("alpha/retros/r.md", "x\n")
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(3 blocks)")))
		ctx, raw, rc := k.runHook(nil)
		if rc != 0 {
			t.Fatalf("rc = %d, want 0 (a hook never fails the session)", rc)
		}
		if !strings.HasPrefix(ctx, hdrRegistryOK+"\n") || !strings.Contains(ctx, "Registry consistent with reality") ||
			!strings.HasSuffix(ctx, "Full detail: toolbelt/verify-registry.sh (or this hook with --full).") {
			t.Errorf("context %q (raw %q)", ctx, raw)
		}
		wantNot(t, ctx, "Could not run")
	})
	t.Run("operational-failure", func(t *testing.T) {
		k := newVRKit(t) // no TARGETS.md
		ctx, _, rc := k.runHook(nil)
		if rc != 0 {
			t.Fatalf("rc = %d, want 0", rc)
		}
		want(t, ctx, "Research-SDD registry check could not run (exit 1 — check TARGETS.md and lib/ helper):\nverify-registry: cannot find ")
		wantNot(t, ctx, hdrRegistryOK)
	})
	t.Run("unknown-argument-is-ignored", func(t *testing.T) {
		k := newVRKit(t)
		k.targets(vrTable())
		var out bytes.Buffer
		s := cli.Stdio{Out: &out, Err: &out, Env: func(string) string { return "" }, Cwd: k.root}
		// --kit without a value is dropped by the hook (the script ignored unknown arguments); the registry then
		// resolves the kit itself and, with no kit around, fails operationally rather than printing nothing.
		if rc := RunRegistryHook([]string{"--bogus"}, s); rc != 0 {
			t.Errorf("rc = %d, want 0", rc)
		}
		want(t, out.String(), "could not run (exit ")
	})
}

func TestRegistryHookFullPassesTheReportThrough(t *testing.T) {
	t.Parallel()
	k := newVRKit(t)
	k.blocks("alpha", 5)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(40 md)")))
	full, _, _ := k.runHook(nil, "--full")
	compact, _, _ := k.runHook(nil)
	rep := k.run(nil)
	if full != hdrRegistryOK+"\n"+strings.TrimRight(rep.stdout+rep.stderr, "\n") {
		t.Errorf("--full context:\n%s\nwant the header and the report unchanged:\n%s", full, rep.stdout)
	}
	if !strings.Contains(compact, "Full detail: toolbelt/verify-registry.sh") || strings.Contains(full, "Full detail: toolbelt/verify-registry.sh") {
		t.Errorf("compact must end with the pointer and --full must not:\ncompact=%q\nfull=%q", compact, full)
	}
}

func TestCompactRegistryRules(t *testing.T) {
	t.Parallel()
	const tail = "Full detail: toolbelt/verify-registry.sh (or this hook with --full)."
	compact := func(s string) string { return compactRegistry(s, false) }
	warn := func(i int) string { return fmt.Sprintf("WARN  t%d — drift", i) }
	t.Run("summary-and-unknown-lines-pass-whole", func(t *testing.T) {
		got := compact("Summary: reconciled 2 target(s) · 0 absent\nsomething new\n\n   \nFor each count drift: x\nINFO  row 1 fine\nINFO  row 2 fine")
		want := "Summary: reconciled 2 target(s) · 0 absent\nsomething new\nINFO: 2 per-row INFO line(s) omitted\n" + tail
		if got != want {
			t.Errorf("got:\n%s\nwant:\n%s", got, want)
		}
	})
	t.Run("a-single-row-info-is-still-counted", func(t *testing.T) {
		if got := compact("INFO  row 1 fine"); got != "INFO: 1 per-row INFO line(s) omitted\n"+tail {
			t.Errorf("got %q", got)
		}
	})
	t.Run("warn-cap-ranks-fleet-level-first", func(t *testing.T) {
		var in []string
		for i := 1; i <= 5; i++ {
			in = append(in, warn(i))
		}
		in = append(in, "WARN: kit-level one", "WARN  kit repo is NOT in its own TARGETS.md", "WARN  x — PARTIAL reconcile", "WARN  y — master cell is 300 chars (> 200)")
		got := strings.Split(compact(strings.Join(in, "\n")), "\n")
		wantLines := []string{"WARN: kit-level one", "WARN  kit repo is NOT in its own TARGETS.md", "WARN  x — PARTIAL reconcile",
			"WARN  y — master cell is 300 chars (> 200)", warn(1), warn(2), "WARN: +3 more WARN line(s) omitted (9 total)", tail}
		if strings.Join(got, "\n") != strings.Join(wantLines, "\n") {
			t.Errorf("got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(wantLines, "\n"))
		}
	})
	t.Run("exactly-at-the-cap-has-no-overflow-line", func(t *testing.T) {
		var in []string
		for i := 1; i <= compactMaxWarn; i++ {
			in = append(in, warn(i))
		}
		wantNot(t, compact(strings.Join(in, "\n")), "more WARN line(s) omitted")
	})
	t.Run("warn-lines-are-cut-at-100-bytes", func(t *testing.T) {
		long := "WARN  " + strings.Repeat("a", 94)
		if len(long) != 100 {
			t.Fatal("fixture")
		}
		if got := compact(long); !strings.HasPrefix(got, long+"\n") {
			t.Errorf("a 100-byte WARN must pass whole: %q", got)
		}
		got := compact(long + "b")
		if !strings.HasPrefix(got, long[:97]+"...\n") {
			t.Errorf("a 101-byte WARN must be cut to 97 bytes and ...: %q", got)
		}
	})
	t.Run("info-keeps-head-and-last-sentence", func(t *testing.T) {
		long := "INFO: " + strings.Repeat("p ", 120) + "first sentence. Example paths a b c. Run the fix."
		got := strings.Split(compact(long), "\n")[0]
		wantHead := long[:107] + "..."
		if got != wantHead+" Run the fix." {
			t.Errorf("got %q, want head %q + the last sentence", got, wantHead)
		}
		short := "INFO: " + strings.Repeat("s", 224) // 230 bytes: unchanged
		if got := strings.Split(compact(short), "\n")[0]; got != short {
			t.Errorf("a 230-byte INFO must pass whole: %q", got)
		}
		noSentence := "INFO: " + strings.Repeat("n", 230) // 236 bytes, no ". "
		if got := strings.Split(compact(noSentence), "\n")[0]; got != noSentence[:227]+"..." {
			t.Errorf("without a sentence break the line is cut at 230: %q", got)
		}
	})
}

func TestUTF8TrimDropsOnlyIncompleteSequences(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ in, out string }{
		{"abc\xe2\x80...", "abc..."},                 // 3-byte lead + 1 continuation, cut before the dots
		{"abc\xe2...", "abc..."},                     // lead alone
		{"abc\xc3...", "abc..."},                     // 2-byte lead alone
		{"abc\xf0\x9f\x98...", "abc..."},             // 4-byte lead + 2 continuations
		{"abc\xe2\x80", "abc"},                       // incomplete at end of line
		{"abc\xe2\x80\x94...", "abc\xe2\x80\x94..."}, // a complete em dash stays
		{"abc\xc3\xa9", "abc\xc3\xa9"},               // a complete e-acute at the end stays
		{"a\xf0\x9f\x98\x80", "a\xf0\x9f\x98\x80"},   // a complete 4-byte sequence stays
		{"plain...", "plain..."},
		{"", ""},
	} {
		if got := utf8Trim(c.in); got != c.out {
			t.Errorf("utf8Trim(%q) = %q, want %q", c.in, got, c.out)
		}
	}
}

// panicHooks panics as soon as the run hands it the toolbelt, standing in for any bug inside the registry run.
type panicHooks struct{ fakeHooks }

func (panicHooks) setToolbelt(string) { panic("boom in the registry run") }

// A panic inside the registry run must still reach the session as the could-not-run envelope (CLAUDE.md §7):
// without the hook's own recover, cli.Run's recover prints to stderr and the SessionStart hook says nothing.
func TestRegistryHookPanicStillEmitsEnvelope(t *testing.T) {
	withHooks(t, panicHooks{})
	k := newVRKit(t)
	k.blocks("alpha", 3)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(3 blocks)")))
	ctx, raw, rc := k.runHook(nil)
	if rc != 0 {
		t.Fatalf("rc=%d, want 0 (a hook never fails the session)", rc)
	}
	want(t, ctx, fmt.Sprintf(hdrRegistryCouldNo, cli.ExitOperational), "internal-error: boom in the registry run")
	if ctx == "" {
		t.Fatalf("no SessionStart envelope; stdout %q", raw)
	}
}
