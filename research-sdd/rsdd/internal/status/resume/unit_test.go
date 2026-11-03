package resume

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Unit tests: what the goldens do not pin by themselves (the arguments gh is called with, GIT_OPTIONAL_LOCKS, the
// boundaries of the 1000-PR page, the jq number syntax, the sibling resume-state of resume-render) and the places where
// the port deliberately differs from the scripts. They never run the frozen scripts, so they hold under -tags nodiff.

// adHocPath puts a gh program with the given body first on PATH and returns the scenario environment for it.
func adHocPath(t *testing.T, body string) map[string]string {
	t.Helper()
	d := t.TempDir()
	must0(t, os.WriteFile(filepath.Join(d, "gh"), []byte("#!/bin/sh\n"+body+"\n"), 0o755))
	return map[string]string{"PATH": d + ":" + realPath}
}

func stateJSON(t *testing.T, o outcome) map[string]any {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal([]byte(o.out), &doc); err != nil {
		t.Fatalf("stdout is not one JSON document: %v\n%s", err, o.out)
	}
	return doc
}

func TestGhIsCalledWithTheListArgumentsInTheRepository(t *testing.T) {
	w := getWorld(t, "basic")
	rec := w.root + "/gh-rec.txt"
	_ = os.Remove(rec)
	o := runGo(t, scn{name: "rec", cmd: "resume-state", path: "gh:rec"})
	if o.rc != 0 {
		t.Fatalf("rc %d: %s", o.rc, o.err)
	}
	got, err := os.ReadFile(rec)
	must0(t, err)
	want := "pr list --state open --limit 1000 --json number,headRefName,state,url\n" + w.repo + "\n"
	if string(got) != want {
		t.Errorf("gh saw %q, want %q", got, want)
	}
	if doc := stateJSON(t, o); doc["prs_status"] != "ok" || doc["prs_truncated"] != false {
		t.Errorf("an empty list from gh is ok and not truncated: %v %v", doc["prs_status"], doc["prs_truncated"])
	}
}

func TestGhEnvironmentIsTheCallersWithoutGitRedirection(t *testing.T) {
	env := adHocPath(t, "echo \"$GIT_OPTIONAL_LOCKS|${GIT_DIR-unset}\" > \"$GH_OUT\"\necho '[]'")
	out := filepath.Join(t.TempDir(), "env")
	env["GH_OUT"], env["GIT_DIR"], env["GIT_OPTIONAL_LOCKS"] = out, "/nonexistent", "1"
	if o := runGo(t, scn{name: "env", cmd: "resume-state", env: env}); o.rc != 0 {
		t.Fatalf("rc %d: %s", o.rc, o.err)
	}
	got, err := os.ReadFile(out)
	must0(t, err)
	if string(got) != "0|unset\n" {
		t.Errorf("gh saw %q, want GIT_OPTIONAL_LOCKS=0 and no GIT_DIR", got)
	}
}

// TestEveryGitCallSeesOptionalLocksOff: a git that logs the variable shows it is 0 on every call, whatever the caller had.
func TestEveryGitCallSeesOptionalLocksOff(t *testing.T) {
	w := getWorld(t, "basic")
	_ = os.Remove(w.gitLog())
	sc := scn{name: "gitlog", cmd: "resume-state", path: "gitlog", args: []string{"--no-gh"}, env: map[string]string{"GIT_OPTIONAL_LOCKS": "1"}}
	if o := runGo(t, sc); o.rc != 0 {
		t.Fatalf("rc %d: %s", o.rc, o.err)
	}
	b, err := os.ReadFile(w.gitLog())
	must0(t, err)
	lines := strings.Fields(string(b))
	if len(lines) < 10 {
		t.Fatalf("expected a call per worktree and branch, the git wrapper logged %d", len(lines))
	}
	for _, l := range lines {
		if l != "0" {
			t.Fatalf("a git call saw GIT_OPTIONAL_LOCKS=%s", l)
		}
	}
}

func prCount(t *testing.T, n int) string {
	return "jq -nc '[range(" + strconv.Itoa(n) + ")|{number:.,headRefName:\"b\\(.)\",state:\"OPEN\",url:\"u\"}]'"
}

// TestTruncationBoundary: a page of exactly the limit may be incomplete, one less is complete.
func TestTruncationBoundary(t *testing.T) {
	for _, tc := range []struct {
		n    int
		want bool
	}{{999, false}, {1000, true}} {
		o := runGo(t, scn{name: "n", cmd: "resume-state", env: adHocPath(t, prCount(t, tc.n))})
		doc := stateJSON(t, o)
		if got := doc["prs_truncated"]; got != tc.want || len(doc["prs"].([]any)) != tc.n {
			t.Errorf("%d PRs: prs_truncated=%v len=%d, want %v", tc.n, got, len(doc["prs"].([]any)), tc.want)
		}
	}
}

// Several documents from gh are not one list: the first is used, completeness reads false, and (unlike the script, whose
// `[` prints a bash error naming its own path) nothing extra is written to stderr.
func TestGhWithTwoDocuments(t *testing.T) {
	o := runGo(t, scn{name: "two", cmd: "resume-state", env: adHocPath(t, "echo '[{\"number\":1}] []'")})
	doc := stateJSON(t, o)
	if o.rc != 0 || o.err != "" || doc["prs_status"] != "ok" || doc["prs_truncated"] != false || len(doc["prs"].([]any)) != 1 {
		t.Errorf("rc=%d stderr=%q status=%v truncated=%v prs=%v", o.rc, o.err, doc["prs_status"], doc["prs_truncated"], doc["prs"])
	}
}

// A hung gh is stopped at the bound and reported as a timeout. The bound is 30 s, as in the script; RSDD_RESUME_GH_TIMEOUT
// shortens it for this test.
func TestGhTimeout(t *testing.T) {
	env := adHocPath(t, "sleep 20")
	env["RSDD_RESUME_GH_TIMEOUT"] = "1"
	start := time.Now()
	o := runGo(t, scn{name: "hung", cmd: "resume-state", env: env})
	if doc := stateJSON(t, o); doc["prs_status"] != "degraded:gh-timeout" || doc["prs"] != nil || doc["prs_truncated"] != nil {
		t.Errorf("a hung gh: %v %v %v", doc["prs_status"], doc["prs"], doc["prs_truncated"])
	}
	if d := time.Since(start); d > 15*time.Second {
		t.Errorf("gh was not stopped at the bound: %v", d)
	}
}

// A gh that exits 137 reads as gh-failed in the script; core/gh reads it as the bound's KILL and says timeout. The port
// follows core/gh: a deliberate difference, pinned here.
func TestGhKilledReadsAsTimeout(t *testing.T) {
	o := runGo(t, scn{name: "k", cmd: "resume-state", env: adHocPath(t, "exit 137")})
	if doc := stateJSON(t, o); doc["prs_status"] != "degraded:gh-timeout" {
		t.Errorf("prs_status = %v", doc["prs_status"])
	}
}

// The envelope renderer prints integers only: a non-integer PR number cannot be carried and fails the build (the script's
// jq would print it). The default document keeps the literal.
func TestFractionalPRNumber(t *testing.T) {
	env := adHocPath(t, `echo '[{"number":7.50,"headRefName":"b","state":"OPEN","url":"u"}]'`)
	o := runGo(t, scn{name: "frac", cmd: "resume-state", env: env})
	if doc := stateJSON(t, o); doc["prs"].([]any)[0].(map[string]any)["number"] != 7.5 || !strings.Contains(o.out, `"number": 7.50`) {
		t.Errorf("default document: %s", o.out)
	}
	o = runGo(t, scn{name: "frac-json", cmd: "resume-state", args: []string{"--json"}, env: env})
	if o.rc != 2 || o.out != "" || o.err != "resume-state.sh: --json envelope build failed\n" {
		t.Errorf("--json: rc=%d stdout=%q stderr=%q", o.rc, o.out, o.err)
	}
}

func TestGeneratedAtIsTheClock(t *testing.T) {
	o := runGo(t, scn{name: "t", cmd: "resume-state", args: []string{"--no-gh"}})
	if doc := stateJSON(t, o); doc["generated_at"] != "2026-01-02T03:04:05Z" {
		t.Errorf("generated_at = %v", doc["generated_at"])
	}
}

func TestEnvelopeCountsAndItems(t *testing.T) {
	o := runGo(t, scn{name: "env", cmd: "resume-state", path: "gh:ok", args: []string{"--json"}})
	doc := stateJSON(t, o)
	counts := doc["counts"].(map[string]any)
	want := map[string]float64{"worktrees": 6, "worktrees_missing": 1, "worktrees_dirty": 1, "prs": 2, "prs_unknown": 0}
	for k, v := range want {
		if counts[k] != v {
			t.Errorf("counts.%s = %v, want %v", k, counts[k], v)
		}
	}
	kinds := map[string]int{}
	for _, it := range doc["items"].([]any) {
		kinds[it.(map[string]any)["kind"].(string)]++
	}
	if kinds["repo"] != 1 || kinds["worktree"] != 6 || kinds["pr"] != 2 || kinds["branch"] != int(counts["branches"].(float64)) {
		t.Errorf("item kinds %v do not match the counts %v", kinds, counts)
	}
	if doc["state"] != "ok" || doc["reason"] != nil {
		t.Errorf("state=%v reason=%v", doc["state"], doc["reason"])
	}
	o = runGo(t, scn{name: "env-unknown", cmd: "resume-state", args: []string{"--no-gh", "--json"}})
	if c := stateJSON(t, o)["counts"].(map[string]any); c["prs_unknown"] != 1.0 || c["prs"] != 0.0 {
		t.Errorf("an unknown PR list is counted as unknown beside zero PRs: %v", c)
	}
}

// A Stdio without an environment still runs (git and jq are looked up on the default PATH).
func TestNoEnvironmentIsNotAPanic(t *testing.T) {
	w := getWorld(t, "plain")
	sc := scn{name: "noenv", cmd: "resume-state", world: "plain", args: []string{"--no-gh"}}
	o := runGoIn(sc, w, w.repo, nil)
	if o.rc != 0 && o.rc != 3 {
		t.Errorf("rc %d: %s", o.rc, o.err)
	}
}

func TestDecNumber(t *testing.T) {
	for in, want := range map[string]string{
		"0": "0", "7": "7", "-7": "-7", "-0": "-0", "1.0": "1.0", "7.0": "7.0", "0.5": "0.5", "0.0001": "0.0001",
		"0.0000001": "1E-7", "1e2": "1E+2", "1E2": "1E+2", "1e+2": "1E+2", "1.5e-7": "1.5E-7", "10E-3": "0.010",
		"12345678901234567890123": "12345678901234567890123", "100": "100", "1.50": "1.50", "0.00": "0.00",
		"0e5": "0E+5", "2.5e3": "2.5E+3", "123e-2": "1.23", "-1.5e300": "-1.5E+300", "1e-6": "0.000001",
	} {
		if got := decNumber(in); got != want {
			t.Errorf("decNumber(%s) = %s, want %s", in, got, want)
		}
	}
}

func TestToString(t *testing.T) {
	docs, err := parseDocs([]byte(`["a\u007f\"\\\n\t\r\b\f\u0001é ", 1E2, null, true, {"b":1,"a":[],"b":{}}, [], {}]`))
	if err != nil || len(docs) != 1 {
		t.Fatalf("parse: %v %d", err, len(docs))
	}
	var got []string
	for _, v := range docs[0].([]jv) {
		got = append(got, tostring(v))
	}
	want := []string{"a\u007f\"\\\n\t\r\b\f\u0001é ", "1E+2", "null", "true", `{"b":{},"a":[]}`, "[]", "{}"}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("tostring #%d = %q, want %q", i, got[i], want[i])
		}
	}
	var b strings.Builder
	writeString(&b, "a\u007f\"\\\n\t\r\b\f\u0001é \xff")
	if want := `"a\u007f\"\\\n\t\r\b\f\u0001é` + " �" + `"`; b.String() != want {
		t.Errorf("writeString = %s, want %s", b.String(), want)
	}
}

func TestToValidReplacesEveryOffendingByte(t *testing.T) {
	if got := toValid("a\xff\xfeb"); got != "a��b" {
		t.Errorf("toValid = %q", got)
	}
	if got := toValid("é"); got != "é" {
		t.Errorf("toValid altered valid text: %q", got)
	}
}

func TestParseDocs(t *testing.T) {
	for in, n := range map[string]int{"": 0, "  \n": 0, "1 2": 2, "{} []": 2, "\xef\xbb\xbf{}": 1, "null": 1} {
		if docs, err := parseDocs([]byte(in)); err != nil || len(docs) != n {
			t.Errorf("parseDocs(%q) = %d docs, %v; want %d", in, len(docs), err, n)
		}
	}
	for _, in := range []string{"{", "{\"a\":1,}", "[1,]", "{\"a\" 1}", "nan", "1 {", "\"a\tb\"", "{1:2}", "[1 2]", "}"} {
		if _, err := parseDocs([]byte(in)); err == nil {
			t.Errorf("parseDocs(%q) accepted malformed input", in)
		}
	}
}

func TestMapPRs(t *testing.T) {
	for in, ok := range map[string]bool{"[]": true, "[null]": true, "[{}]": true, `{"a":{}}`: true, "[1]": false, `["x"]`: false,
		"[[1]]": false, "3": false, "null": false, "true": false, `"s"`: false, "": false, "  ": false, "{": false, `{"a":5}`: false,
		"[] []": true, "[] 1": false} {
		if _, got := mapPRs([]byte(in)); got != ok {
			t.Errorf("mapPRs(%q) ok=%v, want %v", in, got, ok)
		}
	}
	mapped, _ := mapPRs([]byte(`{"z":{"number":1,"headRefName":"h"},"a":null}`))
	var b strings.Builder
	writeJV(&b, mapped[0], false, 0)
	if want := `[{"number":1,"branch":"h","state":null,"url":null},{"number":null,"branch":null,"state":null,"url":null}]`; b.String() != want {
		t.Errorf("mapped = %s", b.String())
	}
}

// siblingRender runs the render with a toolbelt whose resume-state.sh has the given body.
func siblingRender(t *testing.T, body string, args ...string) outcome {
	t.Helper()
	d := t.TempDir()
	must0(t, os.WriteFile(filepath.Join(d, "resume-state.sh"), []byte("#!/bin/sh\n"+body+"\n"), 0o755))
	sc := scn{name: "sibling", cmd: "resume-render", args: args}
	return runGo(t, sc, "--toolbelt", d)
}

func TestSiblingExitCodes(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		rc         int
		err        string
	}{
		{"degraded", "echo 'DEGRADED: stub' >&2; exit 3", 3, "DEGRADED: stub\nresume-render.sh: resume-state.sh failed (rc 3)\n"},
		{"failed", "exit 4", 2, "resume-render.sh: resume-state.sh failed (rc 4)\n"},
		{"killed", "kill -9 $$", 2, "resume-render.sh: resume-state.sh failed (rc 137)\n"},
		{"silent", "exit 0", 2, "resume-render.sh: empty input (no JSON document)\n"},
		{"rc1-with-output", "echo '{}'; echo oops >&2; exit 1", 2, "oops\nresume-render.sh: resume-state.sh failed (rc 1)\n"},
	} {
		o := siblingRender(t, tc.body)
		if o.rc != tc.rc || o.out != "" || o.err != tc.err {
			t.Errorf("%s: rc=%d stdout=%q stderr=%q", tc.name, o.rc, o.out, o.err)
		}
	}
	o := siblingRender(t, "cat <<'EOF'\n"+docOK+"\nEOF")
	if o.rc != 0 || !strings.Contains(o.out, "- #7 `feat/x` OPEN") || o.err != "" {
		t.Errorf("rendered sibling document: rc=%d stderr=%q\n%s", o.rc, o.err, o.out)
	}
	o = runGo(t, scn{name: "nosibling", cmd: "resume-render"}, "--toolbelt", t.TempDir())
	if o.rc != 2 || o.out != "" || !strings.HasSuffix(o.err, "resume-render.sh: resume-state.sh failed (rc 127)\n") {
		t.Errorf("missing sibling: rc=%d stderr=%q", o.rc, o.err)
	}
}

// The sibling gets the forwarded flags in order, the caller's working directory and environment.
func TestSiblingReceivesTheForwardedFlags(t *testing.T) {
	w := getWorld(t, "basic")
	rec := filepath.Join(t.TempDir(), "rec")
	body := "echo \"$@\" > \"" + rec + "\"\npwd >> \"" + rec + "\"\necho \"$GH_REC\" >> \"" + rec + "\"\necho '{}'"
	o := siblingRender(t, body, "--base-ref", "main", "--no-gh", "--cwd", "{R}")
	if o.rc != 2 { // '{}' has no schema; only the call matters
		t.Fatalf("rc %d: %s", o.rc, o.err)
	}
	got, err := os.ReadFile(rec)
	must0(t, err)
	if want := "--base-ref main --no-gh --cwd " + w.repo + "\n" + w.repo + "\n" + w.root + "/gh-rec.txt\n"; string(got) != want {
		t.Errorf("sibling saw %q, want %q", got, want)
	}
}

func TestToolbeltFlagForms(t *testing.T) {
	d := t.TempDir()
	must0(t, os.WriteFile(filepath.Join(d, "resume-state.sh"), []byte("#!/bin/sh\necho 'DEGRADED: eq' >&2; exit 3\n"), 0o755))
	for _, args := range [][]string{{"--toolbelt=" + d + "/"}, {"--toolbelt", d + "/"}} {
		o := runGo(t, scn{name: "tb", cmd: "resume-render", args: args})
		if o.rc != 3 || !strings.HasPrefix(o.err, "DEGRADED: eq\n") {
			t.Errorf("%v: rc=%d stderr=%q", args, o.rc, o.err)
		}
	}
	if o := runGo(t, scn{name: "tb-missing", cmd: "resume-render", args: []string{"--toolbelt"}}); o.rc != 2 || o.err != renderUsage+"\n" {
		t.Errorf("--toolbelt without a value: rc=%d stderr=%q", o.rc, o.err)
	}
}

// repo:false passes the shape check (as {}) and then fails at .repo.toplevel in the script's jq program: a render failure
// with nothing on stdout. The jq message names a temporary file, so only its prefix is pinned.
func TestRepoFalseIsARenderFailure(t *testing.T) {
	doc := edit(docOK, `"repo": {"toplevel": "/r/kit", "remote": null}`, `"repo": false`)
	o := runGo(t, scn{name: "repo-false", cmd: "resume-render", args: []string{"--json", "-"}, stdin: doc})
	if o.rc != 2 || o.out != "" || !strings.HasPrefix(o.err, "resume-render.sh: render failed: jq: error") {
		t.Errorf("rc=%d stdout=%q stderr=%q", o.rc, o.out, o.err)
	}
}

func TestRenderIsReadOnlyAndStdinOptional(t *testing.T) {
	o := runGoIn(scn{name: "nostdin", cmd: "resume-render", args: []string{"--json", "-"}}, getWorld(t, "plain"), t.TempDir(), []string{"PATH=" + realPath})
	if o.rc != 2 || o.err != "resume-render.sh: empty input (no JSON document)\n" {
		t.Errorf("rc=%d stderr=%q", o.rc, o.err)
	}
}

func TestShortSHAAndCounts(t *testing.T) {
	for _, tc := range []struct {
		v    jv
		want string
	}{{nil, "unknown"}, {"abcdefghij", "abcdefg"}, {"abc", "abc"}, {"é😀abcdef", "é😀abcde"}, {jnum("123456789012"), "1234567"}, {true, "true"}} {
		if got := shortSHA(tc.v); got != tc.want {
			t.Errorf("shortSHA(%v) = %q, want %q", tc.v, got, tc.want)
		}
	}
	if cnt("dirty", nil) != "dirty unknown" || cnt("dirty", jnum("0")) != "dirty 0" || orUnknown(nil) != "unknown" || orUnknown(false) != "false" {
		t.Error("null renders as unknown and a real zero or false as itself")
	}
}
