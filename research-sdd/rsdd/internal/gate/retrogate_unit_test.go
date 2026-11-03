package gate

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Unit tests of the pieces of the retro gate that no scenario reaches by name.

func TestRetroEscapeReason(t *testing.T) { // #1167-2 ESC1, #1301-6 ESC2b: every byte round-trips through a JSON parser
	cases := map[string]string{
		"": "", `a"b`: `a\"b`, `a\b`: `a\\b`, "a\nb": `a\nb`, "a\tb": `a\tb`, "a\rb": `a\rb`, "a&b": "a&b", `\"`: `\\\"`,
		"\x01": `\u0001`, "\x1b": `\u001b`, "\x1f": `\u001f`, "é ": "é ", "\x0b\x0c": `\u000b\u000c`,
	}
	for in, want := range cases {
		if got := escapeReason(in); got != want {
			t.Errorf("escapeReason(%q) = %q, want %q", in, got, want)
		}
	}
	var all strings.Builder
	for c := 1; c < 0x80; c++ {
		all.WriteByte(byte(c))
	}
	var back string
	if err := json.Unmarshal([]byte(`"`+escapeReason(all.String())+`"`), &back); err != nil || back != all.String() {
		t.Errorf("round trip failed: %v", err)
	}
}

func TestRetroJQString(t *testing.T) { // the envelope text is jq's, byte for byte (the run is skipped without jq)
	if _, err := exec.LookPath("jq"); err != nil {
		t.Skip("jq not on PATH")
	}
	for _, in := range []string{"", "plain", "q\"b\\s", "a\nb\tc\rd\be\ff", "\x01\x1f", "é ü 世界   \U0001F600", "a/b&c<d>e"} {
		cmd := exec.Command("jq", "-Rs", ".")
		cmd.Stdin = strings.NewReader(in)
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		if got, want := rgJQString(in), strings.TrimSuffix(string(out), "\n"); got != want {
			t.Errorf("rgJQString(%q) = %s, jq prints %s", in, got, want)
		}
	}
	if got := rgJQString("a\xffb"); got != "\"a�b\"" {
		t.Errorf("an invalid byte must become U+FFFD, got %q", got)
	}
	if rgJQString("\x7f") != `"\u007f"` {
		t.Errorf("DEL: %s", rgJQString("\x7f"))
	}
}

func TestRetroTailLines(t *testing.T) { // `tail -n N`, with and without the final newline
	for _, c := range []struct {
		in   string
		n    int
		want string
	}{
		{"a\nb\nc\n", 2, "b\nc\n"}, {"a\nb\nc", 2, "b\nc"}, {"a\nb\n", 5, "a\nb\n"}, {"", 3, ""}, {"a\n", 1, "a\n"}, {"a\nb\n", 1, "b\n"},
	} {
		if got := string(tailLines([]byte(c.in), c.n)); got != c.want {
			t.Errorf("tailLines(%q, %d) = %q, want %q", c.in, c.n, got, c.want)
		}
	}
}

func TestRetroMatchers(t *testing.T) { // the predicates of the old find / grep / case commands
	for p, want := range map[string]bool{
		"/t/retros/a.md": true, "/t/retros/.md": true, "/t/a/retros/b/c.md": true, "/t/retros/a.txt": false, "/t/xretros/a.md": false,
		"/t/retros/": false, "/t/retros/x.MD": false, "retros/a.md": false, "/retros/a.md": true,
	} {
		if got := matchRetroPath(p); got != want {
			t.Errorf("matchRetroPath(%q) = %v", p, got)
		}
	}
	for p, want := range map[string]bool{
		"retros/a.md": true, "a/b/retros/c/d.md": true, "retros/.md": false, "retros/ab.md": true, "retros/a.txt": false, "xretros/a.md": false, "retros/": false, "retros//a.md": false,
	} {
		if got := retroPathOK(p); got != (want && !strings.Contains(strings.ToLower(p), "index")) {
			t.Errorf("retroPathOK(%q) = %v", p, got)
		}
	}
	for name, want := range map[string]bool{"index.md": true, "INDEX.MD": true, "myIndexes.md": true, "x-index-y.md": true, "index.txt": false, "idx.md": false, "indx.md": false} {
		if got := matchIndexName(name); got != want {
			t.Errorf("matchIndexName(%q) = %v", name, got)
		}
	}
	if retroPathOK("retros/INDEX.txt") || retroPathOK("retros/Index.md") {
		t.Errorf("an index file never qualifies, whatever its suffix (the guard is a basename glob)")
	}
	if baseName("/a/b/") != "b" || baseName("/") != "/" || baseName("") != "" || path0Base("/") != "" || path0Base("/a/b") != "b" {
		t.Errorf("basename helpers")
	}
	if !hasGitSegment("/a/.git/x") || hasGitSegment("/a/.git") || hasGitSegment("/a/.gitx/y") {
		t.Errorf("hasGitSegment")
	}
}

// T-SEEDABLE: which retros the seeder is called on, decided by the shared grammar.
func TestRetroSeedable(t *testing.T) {
	for _, c := range []struct {
		id, body string
		want     bool
		warn     bool
	}{
		{"1 'shipped:' without PARTIAL is partial → seedable (#1093 item 3)", "<!-- review-status: applied · abc1234 · shipped: row 1 -->\n# Retro\n", true, false},
		{"2 dismissed", "<!-- review-status: dismissed -->\n# Retro\n", false, false},
		{"3 H1 + blank + applied marker (#945)", "# Retro\n\n<!-- review-status: applied -->\n", false, false},
		{"4 dismissed after a second heading → out of scope (#1099)", "# Retro\n\n## Next\n\n<!-- review-status: dismissed -->\n", false, true},
		{"5 no marker at all", "# Retro\nbody\n", true, false},
		{"6 applied after a second heading → out of scope", "# Retro\n\n## Next\n\n<!-- review-status: applied -->\n", false, true},
		{"7 out of scope, LAST line without newline", "# Retro\n\n## Next\n<!-- review-status: dismissed -->", false, true},
		{"8 pending", "<!-- review-status: pending -->\n# Retro\n", true, false},
		{"9 applied PARTIAL", "<!-- review-status: applied PARTIAL -->\n# Retro\n", true, false},
		{"10 applied", "<!-- review-status: applied · deadbee -->\n# Retro\n", false, false},
	} {
		var errb bytes.Buffer
		g := &retroGate{s: cli.Stdio{Err: &errb}}
		p := t.TempDir() + "/2026-09-05-x.md"
		if err := os.WriteFile(p, []byte(c.body), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := g.retroSeedable(p); got != c.want {
			t.Errorf("%s: seedable = %v, want %v", c.id, got, c.want)
		}
		wantWarn := ""
		if c.warn { // T-SEEDABLE-PFX: the typed token every consumer leads with
			wantWarn = "retro-gate: WARN: out-of-scope-marker: 2026-09-05-x.md — a review-status marker exists but sits outside the leading-block scope; refusing to seed (kit issue #1099)\n"
		}
		if errb.String() != wantWarn {
			t.Errorf("%s: stderr = %q, want %q", c.id, errb.String(), wantWarn)
		}
	}
	g := &retroGate{s: cli.Stdio{Err: &bytes.Buffer{}}}
	if !g.retroSeedable("/nonexistent/x.md") || !g.retroSeedable(t.TempDir()) {
		t.Errorf("a retro that cannot be read reads as markerless: seedable, like the bash")
	}
}

func TestRetroNestedRootsLieInsideTarget(t *testing.T) { // #1404 S17: every root, a real linked worktree included
	w := newRGWorld(t, false)
	d := w.mkgit("t")
	w.git(d, "worktree", "add", "-q", d+"/nested", "-b", "wtb")
	roots, err := kit.NestedWorktreeRoots(d)
	if err != nil || len(roots) != 2 || roots[0] != d+"/.claude/worktrees" || roots[1] != d+"/nested" {
		t.Fatalf("roots = %v, %v", roots, err)
	}
	for _, r := range roots {
		if !strings.HasPrefix(r, d+"/") {
			t.Errorf("root %s lies outside the target", r)
		}
	}
}

// SL11b: concurrent Stops never leave the log empty, even when they rotate it at the same time.
func TestRetroConcurrentStopsKeepTheLog(t *testing.T) {
	w := newRGWorld(t, false)
	d := w.fresh("t", "s1")
	var b strings.Builder
	for i := 1; i <= 450; i++ {
		b.WriteString("old\n")
	}
	w.write(d+"/.claude/.rsdd-retro-gate-stops.log", b.String())
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w.runGo(gate(d, "s1"))
		}()
	}
	wg.Wait()
	got, err := os.ReadFile(d + "/.claude/.rsdd-retro-gate-stops.log")
	if err != nil || len(got) == 0 || !strings.Contains(string(got), "branch=no-change") {
		t.Fatalf("log after concurrent Stops: %q, %v", got, err)
	}
	if n := strings.Count(string(got), "\n"); n > rgStopLogMax {
		t.Errorf("log is not bounded: %d lines", n)
	}
	ents, _ := os.ReadDir(d + "/.claude")
	for _, e := range ents {
		if strings.Contains(e.Name(), ".tmp.") {
			t.Errorf("rotation temp file left behind: %s", e.Name())
		}
	}
}

// ── SIGTERM / SIGINT (#1404 S16, #1421): the log line says killed, the shell's exit code is kept, nothing is left ──

// TestRetroGateHelperProcess is the child of TestRetroKilled: it runs the real command on the process's stdio.
func TestRetroGateHelperProcess(t *testing.T) {
	if os.Getenv("RSDD_RETRO_HELPER") != "1" {
		t.Skip("helper process only")
	}
	s, err := cli.OSStdio()
	if err != nil {
		os.Exit(99)
	}
	os.Exit(RunRetro(strings.Fields(os.Getenv("RSDD_RETRO_ARGS")), s))
}

func TestRetroKilled(t *testing.T) {
	for _, sig := range []struct {
		name string
		s    syscall.Signal
		code int
	}{{"TERM", syscall.SIGTERM, 143}, {"INT", syscall.SIGINT, 130}} {
		t.Run(sig.name, func(t *testing.T) {
			w := newRGWorld(t, false)
			d := w.fresh("t", "s")
			must(t, os.Symlink(w.ext("ext-a", false), d+"/corpus"))
			real, _ := exec.LookPath("git")
			started, released := w.root+"/started", w.root+"/released"
			// The stub git holds inside `ls-files` (the enumeration of Part C) until released.
			w.script(w.root+"/stub/git", "case \" $* \" in *\" ls-files \"*) : > \"$STARTED\"; for _ in $(seq 1 300); do [ -e \"$RELEASED\" ] && break; sleep 0.1; done;; esac\nexec "+real+" \"$@\"\n")
			env := w.baseEnv()
			env["PATH"] = w.root + "/stub:" + env["PATH"]
			env["STARTED"], env["RELEASED"], env["RSDD_RETRO_HELPER"] = started, released, "1"
			env["RSDD_RETRO_ARGS"] = "--toolbelt " + w.tb + " " + d
			cmd := exec.Command(os.Args[0], "-test.run=^TestRetroGateHelperProcess$")
			cmd.Env = envList(env)
			cmd.Stdin = strings.NewReader(mkjson("s", false))
			must(t, cmd.Start())
			deadline := time.Now().Add(30 * time.Second)
			for {
				if _, err := os.Stat(started); err == nil {
					break
				}
				if time.Now().After(deadline) {
					_ = cmd.Process.Kill()
					t.Fatal("the gate never reached the enumeration")
				}
				time.Sleep(50 * time.Millisecond)
			}
			must(t, cmd.Process.Signal(sig.s))
			time.Sleep(100 * time.Millisecond)
			must(t, os.WriteFile(released, nil, 0o644))
			err := cmd.Wait()
			ee, ok := err.(*exec.ExitError)
			if !ok || ee.ExitCode() != sig.code {
				t.Fatalf("exit = %v, want %d", err, sig.code)
			}
			log, _ := os.ReadFile(d + "/.claude/.rsdd-retro-gate-stops.log")
			has(t, "stop log", string(log), "target=t session=s branch=killed\n")
			if left, _ := os.ReadDir(w.root + "/tmp"); len(left) != 0 {
				t.Errorf("scratch files left in TMPDIR: %v", left)
			}
		})
	}
}
