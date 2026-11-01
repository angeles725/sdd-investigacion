package gate

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Teeth. The bash suite tests/return-token-gate.test.sh builds one mutant per guard by editing the TEXT of the
// old script (`# RTG-*` tags); the script is a shim now, so those mutants cannot apply. Each guard is pinned here
// instead, and was proven load-bearing by a manual mutation run (one mutant per row, each making `go test` red):
//
//	RTG-JQ-PROBE, RTG-TRANSCRIPT-DEGRADED, RTG-STATUS-DEGRADED, RTG-STATUS-TIMEOUT  TestDegradedAllows
//	RTG-LOOP-SAFETY, RTG-BLOCK-ONCE, RTG-ONCE-PER-TOKEN                             TestBlockOncePerSessionAndToken
//	RTG-NOT-TARGET                                                                  TestNotATargetAndTargetResolution
//	RTG-SIDECHAIN, RTG-LAST-WINS, RTG-BULLET, RTG-BACKTICK, RTG-PREFIX, RTG-TRIM,
//	RTG-STOP-PATTERN                                                                TestAllowMatchForms, TestReportTokens, TestLastReport
//	RTG-OVERRIDE, RTG-OVERRIDE-REASON, RTG-UNAVAILABLE-ALLOW                        TestOverrideAndUnavailable, TestReportTokens
//	RTG-COMPARE, RTG-MISSING-BRANCH, RTG-QUOTE-EMITTED                              TestBlockMismatchAndMissing
//	RTG-TAIL-BOUND                                                                  TestBoundedTranscript, TestTailAndTimeoutParsing
//	RTG-PRUNE-CAP, RTG-PRUNE-AGE, RTG-PRUNE-NAME                                    TestMarkerWriteAndPrune, TestPruneAgeCapIsIndependentOfTheCountCap
//
// The black-box suite keeps running unchanged against the shim; the differential cases under
// internal/testkit/parity/testdata/parity/rt-* compare the Go command with the bash original byte for byte.

// The fixtures are the bash suite's own (tests/fixtures/return-token-gate), read in place and copied per case:
// the gate writes its block-once marker under <target>/.claude.
const fixtureDir = "../../../toolbelt/tests/fixtures/return-token-gate"

const (
	nextLine = "return-token: next: reconstruct the shader pipeline"
	stopLine = "return-token: STOP: campaign — read-only-investigable exhausted (0)"
	unavail  = "return-token: unavailable (STOP with a ## Campaign queue (or unreadable state) needs next-entry vs STOP: campaign from §8c)"
)

func copyDir(t *testing.T, src, dst string) {
	t.Helper()
	if err := os.MkdirAll(dst, 0o755); err != nil {
		t.Fatal(err)
	}
	ents, err := os.ReadDir(src)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if e.IsDir() {
			copyDir(t, filepath.Join(src, e.Name()), filepath.Join(dst, e.Name()))
			continue
		}
		b, err := os.ReadFile(filepath.Join(src, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dst, e.Name()), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// rig is one hermetic gate run: a fresh corpus copy, a toolbelt with a stub status script, a bin dir with a jq
// stand-in (the probe only looks for the file) and an injected Stdio.
type rig struct {
	t       *testing.T
	root    string
	corpus  string
	toolbel string
	bin     string
	env     map[string]string
	now     time.Time
}

func newRig(t *testing.T, corpus string) *rig {
	t.Helper()
	root := t.TempDir()
	r := &rig{t: t, root: root, corpus: filepath.Join(root, "corpus"), toolbel: filepath.Join(root, "tb"), bin: filepath.Join(root, "bin"), now: time.Unix(1_800_000_000, 0)}
	copyDir(t, filepath.Join(fixtureDir, corpus), r.corpus)
	for _, d := range []string{r.toolbel, r.bin} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(r.bin, "jq"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	r.env = map[string]string{"PATH": r.bin + ":/usr/bin:/bin", "LANG": "C.UTF-8"}
	r.status("printf '%s\\n' 'NEXT | high | x' '" + nextLine + "'")
	return r
}

// status installs the stub research-sdd-status.sh with the given body.
func (r *rig) status(body string) {
	r.t.Helper()
	if err := os.WriteFile(filepath.Join(r.toolbel, "research-sdd-status.sh"), []byte("#!/usr/bin/env bash\n"+body+"\n"), 0o755); err != nil {
		r.t.Fatal(err)
	}
}

func (r *rig) transcript(name string) string { return filepath.Join(fixtureDir, "transcripts", name) }

func (r *rig) hook(session, transcript string, active bool) string {
	b := &strings.Builder{}
	b.WriteString(`{"session_id":` + jsonStr(session) + `,"transcript_path":` + jsonStr(transcript) + `,"cwd":` + jsonStr(r.corpus))
	if active {
		b.WriteString(`,"stop_hook_active":true`)
	} else {
		b.WriteString(`,"stop_hook_active":false`)
	}
	b.WriteString("}")
	return b.String()
}

func jsonStr(s string) string { return string(bytes.TrimSpace([]byte(blockJSONString(s)))) }

// blockJSONString is a JSON string literal of s (test helper, independent of the code under test for ASCII input).
func blockJSONString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range []byte(s) {
		switch c {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case '\n':
			b.WriteString(`\n`)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

type result struct {
	out, err string
	rc       int
}

func (r *rig) run(stdin string, args ...string) result {
	r.t.Helper()
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(stdin), Out: &out, Err: &errb,
		Env:   func(k string) string { return r.env[k] },
		Clock: func() time.Time { return r.now },
		Cwd:   r.root,
	}
	rc := RunReturnToken(append([]string{"--toolbelt", r.toolbel}, args...), s)
	return result{out.String(), errb.String(), rc}
}

func (r *rig) gate(session, transcript string, args ...string) result {
	return r.run(r.hook(session, transcript, false), args...)
}

func (r *rig) markers() []string {
	ents, _ := os.ReadDir(filepath.Join(r.corpus, ".claude"))
	var out []string
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), markerPrefix) {
			out = append(out, e.Name())
		}
	}
	return out
}

func wantAllow(t *testing.T, label string, res result, branch string) {
	t.Helper()
	if res.rc != 0 || res.out != "" || !strings.Contains(res.err, "state=allow branch="+branch) {
		t.Errorf("%s: want allow branch=%s, got rc=%d out=%q err=%q", label, branch, res.rc, res.out, res.err)
	}
}

func wantBlock(t *testing.T, label string, res result, branch string, lines ...string) {
	t.Helper()
	if res.rc != 0 || !strings.HasPrefix(res.out, `{"decision":"block","reason":"`) || !strings.HasSuffix(res.out, "\"}\n") || !strings.Contains(res.err, "state=block branch="+branch+" target=corpus") {
		t.Fatalf("%s: want block branch=%s, got rc=%d out=%q err=%q", label, branch, res.rc, res.out, res.err)
	}
	for _, l := range lines {
		if !strings.Contains(res.out, l) {
			t.Errorf("%s: reason lacks %q: %q", label, l, res.out)
		}
	}
}

func TestAllowMatchForms(t *testing.T) {
	for _, tc := range []struct{ label, transcript string }{
		{"G-MATCH", "match.jsonl"},
		{"G-MATCH-BARE", "match-bare.jsonl"},
		{"G-MATCH-DECORATED", "match-decorated.jsonl"},
		{"G-LAST-WINS", "lastwins.jsonl"},
		{"G-TOOL-LAST", "tool-last.jsonl"},
		{"G-BADLINES", "badlines.jsonl"},
		{"G-STRING-CONTENT", "string-content.jsonl"},
		{"G-SIDECHAIN", "sidechain-mismatch.jsonl"},
	} {
		r := newRig(t, "corpus-next")
		wantAllow(t, tc.label, r.gate("s1", r.transcript(tc.transcript)), "match")
	}
	r := newRig(t, "corpus-stop-queue")
	r.status("printf '%s\\n' 'STOP | x' '" + stopLine + "'")
	wantAllow(t, "G-STOP-MATCH", r.gate("s1", r.transcript("stop-token.jsonl")), "match")
}

func TestBlockMismatchAndMissing(t *testing.T) {
	r := newRig(t, "corpus-next")
	res := r.gate("s1", r.transcript("mismatch.jsonl"))
	wantBlock(t, "G-MISMATCH", res, "mismatch", `\n\n`+nextLine+`\n\n`, "next: trivia", "(reported: 'next: trivia")
	if got := r.markers(); len(got) != 1 || got[0] != markerPrefix+"s1" {
		t.Errorf("marker = %v", got)
	}

	r = newRig(t, "corpus-next")
	wantBlock(t, "G-NOTOKEN", r.gate("s1", r.transcript("notoken.jsonl")), "missing", "no continuation token", nextLine)
	r = newRig(t, "corpus-next")
	wantBlock(t, "G-FINAL-ONLY", r.gate("s1", r.transcript("final-has-none.jsonl")), "missing", "no continuation token")
	r = newRig(t, "corpus-next")
	wantBlock(t, "G-UNAVAIL-LINE-NOT-TOKEN", r.gate("s1", r.transcript("unavailable-line-only.jsonl")), "missing", "no continuation token")
	r = newRig(t, "corpus-stop-queue")
	r.status("printf '%s\\n' '" + stopLine + "'")
	wantBlock(t, "G-STOP-MISMATCH", r.gate("s1", r.transcript("match.jsonl")), "mismatch", "STOP: campaign")
}

func TestBlockOncePerSessionAndToken(t *testing.T) {
	r := newRig(t, "corpus-next")
	mm := r.transcript("mismatch.jsonl")
	wantBlock(t, "first", r.gate("s-once", mm), "mismatch")
	wantAllow(t, "G-BLOCK-ONCE", r.gate("s-once", mm), "block-once session=s-once")
	wantBlock(t, "G-ONCE-PER-SESSION", r.gate("s-other", mm), "mismatch")
	r.status("printf '%s\\n' 'return-token: next: a different next gap'")
	wantBlock(t, "G-ONCE-PER-CANDIDATE", r.gate("s-once", mm), "mismatch", "return-token: next: a different next gap")
	wantAllow(t, "G-LOOP-SAFETY", r.run(r.hook("s1", mm, true)), "loop-safety stop_hook_active=true")
}

func TestOverrideAndUnavailable(t *testing.T) {
	r := newRig(t, "corpus-next")
	res := r.gate("s1", r.transcript("override.jsonl"))
	wantAllow(t, "G-OVERRIDE", res, "override reason=")
	if !strings.Contains(res.err, "operator asked for trivia first") {
		t.Errorf("override reason not printed: %q", res.err)
	}
	r = newRig(t, "corpus-next")
	wantBlock(t, "G-OVERRIDE-EMPTY", r.gate("s1", r.transcript("override-empty.jsonl")), "mismatch")

	r = newRig(t, "corpus-stop-queue")
	r.status("printf '%s\\n' 'STOP | x' '" + unavail + "'")
	res = r.gate("s1", r.transcript("mismatch.jsonl"))
	wantAllow(t, "G-UNAVAILABLE", res, "unavailable")
	if !strings.Contains(res.err, "Campaign queue") || strings.Contains(res.err, "return-token: unavailable") {
		t.Errorf("unavailable reason (without the token prefix) not printed: %q", res.err)
	}
	r = newRig(t, "corpus-stop-queue")
	r.status("printf '%s\\n' '" + unavail + "'")
	wantAllow(t, "G-UNAVAILABLE-NOTOKEN", r.gate("s1", r.transcript("notoken.jsonl")), "unavailable")
}

func TestNotATargetAndTargetResolution(t *testing.T) {
	r := newRig(t, "corpus-next")
	empty := filepath.Join(r.root, "empty")
	_ = os.MkdirAll(empty, 0o755)
	res := r.run(`{"session_id":"s1","transcript_path":` + jsonStr(r.transcript("mismatch.jsonl")) + `,"cwd":` + jsonStr(empty) + `}`)
	if res.rc != 0 || res.out != "" || res.err != "" {
		t.Errorf("G-NOT-TARGET: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(empty, ".claude")); err == nil {
		t.Error("G-NOT-TARGET-NOWRITE: .claude was created")
	}

	wantBlock(t, "G-CWD-TARGET", r.run(`{"session_id":"s1","transcript_path":`+jsonStr(r.transcript("mismatch.jsonl"))+`,"cwd":`+jsonStr(r.corpus)+`}`), "mismatch")
	r = newRig(t, "corpus-next")
	wantBlock(t, "arg target", r.run(`{"session_id":"s1","transcript_path":`+jsonStr(r.transcript("mismatch.jsonl"))+`}`, r.corpus), "mismatch")
	r = newRig(t, "corpus-next")
	res = r.run(`{"session_id":"s1","transcript_path":` + jsonStr(r.transcript("mismatch.jsonl")) + `}`)
	wantAllow(t, "G-NO-TARGET", res, "degraded (no target — neither an argument nor a hook cwd)")
	if !strings.HasSuffix(res.err, " target=?\n") {
		t.Errorf("label before the target resolves must be ?: %q", res.err)
	}
	res = r.run(`{"cwd":"` + r.root + `/missing"}`)
	wantAllow(t, "not a directory", res, "degraded (no target — not a directory: "+r.root+"/missing)")
	res = r.run(`{"cwd":"-x"}`)
	wantAllow(t, "option-like cwd", res, "degraded (no target — not a directory: -x)")
	// a relative cwd resolves against the process cwd (here the rig root), lexically (`..` does not follow links)
	wantBlock(t, "relative cwd", r.run(`{"session_id":"s1","transcript_path":`+jsonStr(r.transcript("mismatch.jsonl"))+`,"cwd":"tb/../corpus"}`), "mismatch")
}

func TestDegradedAllows(t *testing.T) {
	r := newRig(t, "corpus-next")
	r.env["PATH"] = filepath.Join(r.root, "nowhere")
	wantAllow(t, "G-DEGRADED-NOJQ", r.run("{}"), "degraded (jq missing — cannot read hook JSON)")

	r = newRig(t, "corpus-next")
	wantAllow(t, "G-DEGRADED-TRANSCRIPT", r.gate("s1", filepath.Join(r.root, "nope.jsonl")), "degraded (transcript unreadable: "+r.root+"/nope.jsonl)")
	wantAllow(t, "G-DEGRADED-NO-TRANSCRIPT-FIELD", r.run(`{"session_id":"s1","cwd":`+jsonStr(r.corpus)+`}`), "degraded (transcript unreadable: no transcript_path in the hook JSON)")
	res := r.gate("s1", r.transcript("no-assistant.jsonl"))
	wantAllow(t, "G-DEGRADED-NO-ASSISTANT", res, "degraded (no assistant text in the transcript: no-assistant.jsonl)")
	wantAllow(t, "G-DEGRADED-STDIN", r.run("this is not json"), "degraded (hook JSON unreadable)")
	for _, in := range []string{"", "null", "false", `{"a":1`, `{"a":1} x`, "{} null"} {
		wantAllow(t, "unreadable hook "+in, r.run(in), "degraded (hook JSON unreadable)")
	}

	r.status("echo boom >&2; exit 3")
	wantAllow(t, "G-DEGRADED-STATUS", r.gate("s1", r.transcript("mismatch.jsonl")), "degraded (status produced no return-token line (rc=3))")
	r.status("sleep 5")
	r.env["RETURN_TOKEN_GATE_TIMEOUT_SECS"] = "0.3"
	t0 := time.Now()
	wantAllow(t, "G-DEGRADED-TIMEOUT", r.gate("s1", r.transcript("mismatch.jsonl")), "degraded (status --next timed out after 0.3s)")
	if time.Since(t0) > 4*time.Second {
		t.Errorf("the bounded status run took %v", time.Since(t0))
	}
	r.env["RETURN_TOKEN_GATE_TIMEOUT_SECS"] = "bogus"
	wantAllow(t, "invalid timeout", r.gate("s1", r.transcript("mismatch.jsonl")), "degraded (status produced no return-token line (rc=125))")
	delete(r.env, "RETURN_TOKEN_GATE_TIMEOUT_SECS")
	if err := os.Remove(filepath.Join(r.toolbel, "research-sdd-status.sh")); err != nil {
		t.Fatal(err)
	}
	wantAllow(t, "missing status script", r.gate("s1", r.transcript("mismatch.jsonl")), "degraded (status produced no return-token line (rc=127))")
}

func TestBoundedTranscript(t *testing.T) {
	r := newRig(t, "corpus-next")
	pad := strings.Repeat(`{"type":"user","message":{"content":"`+strings.Repeat("x", 160)+`"}}`+"\n", 3000)
	match, _ := os.ReadFile(r.transcript("match.jsonl"))
	mismatch, _ := os.ReadFile(r.transcript("mismatch.jsonl"))
	before := filepath.Join(r.root, "before.jsonl")
	after := filepath.Join(r.root, "after.jsonl")
	_ = os.WriteFile(before, append(append([]byte{}, match...), pad...), 0o644)
	_ = os.WriteFile(after, append(append(append([]byte{}, mismatch...), pad...), match...), 0o644)
	r.env["RETURN_TOKEN_GATE_TAIL_BYTES"] = "4096"
	res := r.gate("s1", before)
	wantAllow(t, "G-TAIL-BOUND", res, "degraded (no assistant text in the transcript: before.jsonl (tail-bounded to 4096 bytes))")
	wantAllow(t, "G-TAIL-FINAL-IN-WINDOW", r.gate("s1", after), "match")
	r.env["RETURN_TOKEN_GATE_TAIL_BYTES"] = "0" // 0 means the default window, which holds the whole file
	wantAllow(t, "tail 0 = default", r.gate("s1", before), "match")
}

func TestMarkerWriteAndPrune(t *testing.T) {
	r := newRig(t, "corpus-next")
	claude := filepath.Join(r.corpus, ".claude")
	_ = os.MkdirAll(claude, 0o755)
	age := func(name string, minutes int) {
		p := filepath.Join(claude, name)
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		ts := r.now.Add(-time.Duration(minutes) * time.Minute)
		if err := os.Chtimes(p, ts, ts); err != nil {
			t.Fatal(err)
		}
	}
	for i := 1; i <= 6; i++ {
		age(markerPrefix+"old"+string(rune('0'+i)), i+1)
	}
	age(markerPrefix+"ancient", 86400)
	age("unrelated.txt", 86400)
	age(markerPrefix+"a\nvictim", 1) // a newline in the name must never steer a delete
	_ = os.Symlink("unrelated.txt", filepath.Join(claude, markerPrefix+"link"))
	victim := filepath.Join(r.root, "victim")
	_ = os.WriteFile(victim, nil, 0o644)
	r.env["RETURN_TOKEN_GATE_MARKER_KEEP"] = "3"
	wantBlock(t, "G-PRUNE", r.gate("s-prune", r.transcript("mismatch.jsonl")), "mismatch")
	got := map[string]bool{}
	for _, m := range r.markers() {
		got[m] = true
	}
	// kept: the new marker and the two newest regular candidates (old1, old2); the newline name and the link are
	// never candidates (so they take no slot of the count cap) and are never deleted
	for _, want := range []string{"s-prune", "old1", "old2", "a\nvictim", "link"} {
		if !got[markerPrefix+want] {
			t.Errorf("marker %q should survive: %v", want, got)
		}
	}
	for _, gone := range []string{"ancient", "old6", "old5"} {
		if got[markerPrefix+gone] {
			t.Errorf("marker %q should be pruned: %v", gone, got)
		}
	}
	if _, err := os.Stat(filepath.Join(claude, "unrelated.txt")); err != nil {
		t.Error("unrelated file was deleted")
	}
	if _, err := os.Stat(victim); err != nil {
		t.Error("file outside the marker set was deleted")
	}
}

func TestPruneAgeCapIsIndependentOfTheCountCap(t *testing.T) {
	r := newRig(t, "corpus-next")
	claude := filepath.Join(r.corpus, ".claude")
	_ = os.MkdirAll(claude, 0o755)
	seed := func(name string, ago time.Duration) {
		p := filepath.Join(claude, markerPrefix+name)
		_ = os.WriteFile(p, nil, 0o644)
		ts := r.now.Add(-ago)
		_ = os.Chtimes(p, ts, ts)
	}
	seed("fresh", time.Hour)
	seed("d13", 13*24*time.Hour+23*time.Hour)
	seed("d15", 15*24*time.Hour)
	wantBlock(t, "age default 14", r.gate("s-age", r.transcript("mismatch.jsonl")), "mismatch")
	got := strings.Join(r.markers(), " ")
	if strings.Contains(got, "d15") || !strings.Contains(got, "d13") || !strings.Contains(got, "fresh") {
		t.Errorf("default cap is 14 whole days: %s", got)
	}
	// find -mtime +1 means a whole-day age above 1: 36 h stays, 49 h goes
	r = newRig(t, "corpus-next")
	claude = filepath.Join(r.corpus, ".claude")
	_ = os.MkdirAll(claude, 0o755)
	seed("h36", 36*time.Hour)
	seed("h49", 49*time.Hour)
	r.env["RETURN_TOKEN_GATE_MARKER_MAX_AGE_DAYS"] = "1"
	wantBlock(t, "age 1", r.gate("s-age", r.transcript("mismatch.jsonl")), "mismatch")
	got = strings.Join(r.markers(), " ")
	if strings.Contains(got, "h49") || !strings.Contains(got, "h36") {
		t.Errorf("MAX_AGE_DAYS=1: %s", got)
	}
}

func TestMarkerWriteFailureStillBlocks(t *testing.T) {
	r := newRig(t, "corpus-next")
	if err := os.WriteFile(filepath.Join(r.corpus, ".claude"), []byte("a file, not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}
	res := r.gate("s1", r.transcript("mismatch.jsonl"))
	wantBlock(t, "unwritable marker", res, "mismatch")
	if !strings.Contains(res.err, "return-token-gate: WARN: block-once marker write failed (") || !strings.HasSuffix(res.err, "— the block is still issued\nreturn-token-gate: state=block branch=mismatch target=corpus\n") {
		t.Errorf("WARN line: %q", res.err)
	}
}

func TestHermeticOnlyTheMarkerIsWritten(t *testing.T) {
	r := newRig(t, "corpus-next")
	list := func() string {
		var out []string
		_ = filepath.WalkDir(r.corpus, func(p string, d os.DirEntry, err error) error {
			if err == nil && !d.IsDir() && !strings.Contains(p, "/.claude/") {
				out = append(out, p)
			}
			return nil
		})
		return strings.Join(out, "\n")
	}
	before := list()
	wantBlock(t, "G-HERMETIC", r.gate("s-herm", r.transcript("mismatch.jsonl")), "mismatch")
	if list() != before || len(r.markers()) != 1 {
		t.Error("the gate wrote something besides the block-once marker")
	}
}

func TestStatusChildInheritsTheProcessEnvironment(t *testing.T) {
	t.Setenv("RTG_PROBE_VAR", "visible")
	r := newRig(t, "corpus-next")
	r.status(`printf 'return-token: next: %s\n' "$RTG_PROBE_VAR"`)
	wantBlock(t, "env", r.gate("s1", r.transcript("notoken.jsonl")), "missing", "return-token: next: visible")
}

func TestToolbeltFlagForms(t *testing.T) {
	r := newRig(t, "corpus-next")
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(r.hook("s1", r.transcript("match.jsonl"), false)), Out: &out, Err: &errb,
		Env: func(k string) string { return r.env[k] }, Clock: func() time.Time { return r.now }, Cwd: r.root}
	RunReturnToken([]string{"--toolbelt=" + r.toolbel}, s)
	if out.Len() != 0 || !strings.Contains(errb.String(), "branch=match") {
		t.Errorf("--toolbelt=DIR form: out=%q err=%q", out.String(), errb.String())
	}
	// no flag and no resolvable kit: one more typed degrade, never a silent allow
	s.In = strings.NewReader(r.hook("s1", r.transcript("match.jsonl"), false))
	s.Env = func(k string) string {
		if k == "PATH" {
			return r.env["PATH"]
		}
		return ""
	}
	out.Reset()
	errb.Reset()
	RunReturnToken(nil, s)
	if out.Len() != 0 || !strings.Contains(errb.String(), "branch=degraded (status script unavailable: ") {
		t.Errorf("no toolbelt: out=%q err=%q", out.String(), errb.String())
	}
}

func TestReportTokens(t *testing.T) {
	for _, tc := range []struct{ name, report, reported, override string }{
		{"prefix", "x\nreturn-token: next: a b", "next: a b", ""},
		{"bare", "next: a b", "next: a b", ""},
		{"bullet dash", "- next: a b", "next: a b", ""},
		{"bullet star", "* next-entry: e1", "next-entry: e1", ""},
		{"quote", "> return-token: next: a b", "next: a b", ""},
		{"backtick and trailing", "  `return-token: next: a b`  \t", "next: a b", ""},
		{"stop", "STOP: campaign — done", "STOP: campaign — done", ""},
		{"stop bound", "return-token: STOP: campaign-bound-reached: rounds ", "STOP: campaign-bound-reached: rounds", ""},
		{"last wins", "next: one\nreturn-token: next: two\nprose", "next: two", ""},
		{"next needs a non-space", "next:  x\nnext: ", "", ""},
		{"unavailable is not a token", "return-token: unavailable (why)", "", ""},
		{"CRLF", "return-token: next: a\r\nmore", "next: a", ""},
		{"override", "return-token-override: because\nnext: a", "next: a", "because"},
		{"override empty", "return-token-override:   \nx", "", ""},
		{"override keeps the last non-empty", "return-token-override: one\nreturn-token-override: \nreturn-token-override: two  ", "", "two  "},
		{"override behind a bullet is not an override", "- return-token-override: x", "", ""},
		{"two bullets strip one", "- - next: a", "", ""},
		{"empty", "", "", ""},
	} {
		rep, ov := reportTokens(tc.report)
		if rep != tc.reported || ov != tc.override {
			t.Errorf("%s: got (%q, %q) want (%q, %q)", tc.name, rep, ov, tc.reported, tc.override)
		}
	}
}

func TestLastReport(t *testing.T) {
	asst := func(content string) string { return `{"type":"assistant","message":{"content":` + content + `}}` }
	for _, tc := range []struct {
		name, in, want string
		ok             bool
	}{
		{"string content", asst(`"hello"`), "hello", true},
		{"blocks joined", asst(`[{"type":"text","text":"a"},{"type":"tool_use"},{"type":"text","text":"b"}]`), "a\nb", true},
		{"last with text wins", asst(`"one"`) + "\n" + asst(`[{"type":"tool_use"}]`), "one", true},
		{"empty text skipped", asst(`"one"`) + "\n" + asst(`""`), "one", true},
		{"sidechain skipped", asst(`"one"`) + "\n" + `{"type":"assistant","isSidechain":true,"message":{"content":"two"}}`, "one", true},
		{"sidechain false is main", `{"type":"assistant","isSidechain":false,"message":{"content":"two"}}`, "two", true},
		{"user ignored", `{"type":"user","message":{"content":"u"}}`, "", true},
		{"torn line skipped", "{not json\n" + asst(`"ok"`), "ok", true},
		{"two values on a line are not a line", asst(`"a"`) + " " + asst(`"b"`), "", true},
		{"null message", `{"type":"assistant","message":null}`, "", true},
		{"no message", `{"type":"assistant"}`, "", true},
		{"message is a string: jq error", `{"type":"assistant","message":"x"}`, "", false},
		{"message is an array: jq error", `{"type":"assistant","message":[]}`, "", false},
		{"number content ignored", asst(`5`), "", true},
		{"text number and true", asst(`[{"type":"text","text":7},{"type":"text","text":true},{"type":"text","text":null},{"type":"text","text":false}]`), "7\ntrue\n\n", true},
		{"text object: jq error", asst(`[{"type":"text","text":{}}]`), "", false},
		{"non-object block ignored", asst(`["str", 3, {"type":"text","text":"t"}]`), "t", true},
		{"error aborts everything", asst(`"fine"`) + "\n" + `{"type":"assistant","message":3}`, "", false},
	} {
		got, ok := lastReport([]byte(tc.in))
		if got != tc.want || ok != tc.ok {
			t.Errorf("%s: got (%q, %v) want (%q, %v)", tc.name, got, ok, tc.want, tc.ok)
		}
	}
}

func TestHookFields(t *testing.T) {
	read := func(in string) []string {
		vals, ok := decodeStream([]byte(in))
		if !hookReadable(vals, ok) {
			return nil
		}
		return []string{hookField(vals, "session_id", ""), hookField(vals, "stop_hook_active", "false")}
	}
	for _, tc := range []struct {
		name, in string
		want     []string
	}{
		{"plain", `{"session_id":"a","stop_hook_active":true}`, []string{"a", "true"}},
		{"absent", `{}`, []string{"", "false"}},
		{"null and false", `{"session_id":null,"stop_hook_active":false}`, []string{"", "false"}},
		{"string true counts", `{"stop_hook_active":"true"}`, []string{"", "true"}},
		{"number", `{"session_id":42}`, []string{"42", "false"}},
		{"two objects join their lines", `{"session_id":"a"}{"session_id":"b"}`, []string{"a\nb", "false\nfalse"}},
		{"array is a jq error", `[1]`, []string{"", "false"}},
		{"null value in the stream", `null {"session_id":"z"}`, []string{"z", "false\nfalse"}},
		{"newline inside is kept, trailing ones go", `{"session_id":"a\nb\n\n"}`, []string{"a\nb", "false"}},
		{"duplicate key: last wins", `{"session_id":"a","session_id":"b"}`, []string{"b", "false"}},
		{"unreadable", `{"a":`, nil},
	} {
		got := read(tc.in)
		if strings.Join(got, "|") != strings.Join(tc.want, "|") || (got == nil) != (tc.want == nil) {
			t.Errorf("%s: got %q want %q", tc.name, got, tc.want)
		}
	}
}

func TestSidSafe(t *testing.T) {
	for _, tc := range []struct {
		in   string
		utf8 bool
		want string
	}{
		{"abc-1_2.3", true, "abc-1_2.3"},
		{"a/b c", true, "a_b_c"},
		{"../x", true, ".._x"},
		{"é", true, "_"},
		{"é", false, "__"},
		{"", true, ""},
	} {
		if got := sidSafe(tc.in, tc.utf8); got != tc.want {
			t.Errorf("sidSafe(%q, %v) = %q, want %q", tc.in, tc.utf8, got, tc.want)
		}
	}
}

func TestBlockJSONMatchesJq(t *testing.T) {
	got := blockJSON("a\x7fb é<>&\x01\t\"\\\xff")
	want := `{"decision":"block","reason":"a\u007fb` + " é<>&" + `\u0001\t\"\\` + "�" + `"}` + "\n"
	if got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
}

func TestTailAndTimeoutParsing(t *testing.T) {
	for in, want := range map[string]int64{"": 2097152, "0": 2097152, "abc": 2097152, "-5": 2097152, "4096": 4096, "00": 0, "99999999999999999999": 1<<63 - 1} {
		if got := tailBytes(in); got != want {
			t.Errorf("tailBytes(%q) = %d, want %d", in, got, want)
		}
	}
	w, trunc := tailWindow([]byte("l\nfull1\nfull2\n"), 14, 20) // the last 14 of 20 bytes: the cut line is dropped
	if string(w) != "full1\nfull2\n" || !trunc {
		t.Errorf("tailWindow = %q %v", w, trunc)
	}
	if w, trunc := tailWindow([]byte("no newline here"), 8, 15); w != nil || !trunc {
		t.Errorf("a tail without a newline reads as empty: %q %v", w, trunc)
	}
	if w, trunc := tailWindow([]byte("abc\n"), 4, 4); string(w) != "abc\n" || trunc {
		t.Errorf("a file that fits is read whole: %q %v", w, trunc)
	}
	for in, want := range map[string]time.Duration{"20": 20 * time.Second, "1.5": 1500 * time.Millisecond, "2m": 2 * time.Minute, "1h": time.Hour, "0": 24 * time.Hour, "5s": 5 * time.Second} {
		if got, ok := parseTimeout(in); !ok || got != want {
			t.Errorf("parseTimeout(%q) = %v %v, want %v", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "x", "-1", "+1", "s", "1x"} {
		if _, ok := parseTimeout(in); ok {
			t.Errorf("parseTimeout(%q) should be invalid", in)
		}
	}
	if envCount("", 14, true) != 14 || envCount("0", 14, true) != 0 || envCount("0", 50, false) != 50 || envCount("7", 50, false) != 7 || envCount("x", 50, false) != 50 {
		t.Error("envCount")
	}
}
