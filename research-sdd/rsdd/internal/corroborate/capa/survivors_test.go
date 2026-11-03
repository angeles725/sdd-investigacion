package capa

// Unit tests for the branches neither the goldens nor the end-to-end tests pin: boundaries of the rules
// plausibility walk, the environment lookup, the run record and the timestamp format. The mutation run
// (make teeth, built with -tags nodiff) has no Python oracle, so each of these was a surviving mutant.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func writeFiles(t *testing.T, dir string, names ...string) {
	t.Helper()
	for _, n := range names {
		p := filepath.Join(dir, n)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func ymlNames(prefix string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("%s%03d.yml", prefix, i)
	}
	return out
}

func TestCountRulesThreshold(t *testing.T) {
	for _, tc := range []struct {
		name  string
		files []string
		links map[string]string // name -> target (relative to the root)
		ymls  int
		strct bool
	}{
		{"empty", nil, nil, 0, false},
		{"one below the threshold", ymlNames("r", minYMLCount-1), nil, minYMLCount - 1, false},
		{"exactly the threshold", ymlNames("r", minYMLCount), nil, minYMLCount, false},
		{"stops at the threshold", append(ymlNames("r", minYMLCount), "sub/extra1.yml", "sub/extra2.yml"), nil, minYMLCount, false},
		{"nested files count", append(ymlNames("r", 10), "a/b/c.yml", "a/d.yml"), nil, 12, false},
		{"structural directory", []string{"lib/x.txt"}, nil, 0, true},
		{"structural name on a file", []string{"lib"}, nil, 0, false},
		{"a file symlink named .yml counts", []string{"real.txt"}, map[string]string{"l.yml": "real.txt"}, 1, false},
		{"a dangling .yml symlink counts", nil, map[string]string{"l.yml": "nowhere"}, 1, false},
		{"a symlinked directory is structural, found before anything is entered", []string{"other/a.yml", "other/b.yml"}, map[string]string{"lib": "other"}, 0, true},
		// d.yml is a directory (not a rule file) that the walk skips because it is a symlink; other/ is walked
		{"a symlinked directory named .yml is a directory", []string{"other/a.yml"}, map[string]string{"d.yml": "other"}, 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeFiles(t, dir, tc.files...)
			for name, target := range tc.links {
				if err := os.Symlink(target, filepath.Join(dir, name)); err != nil {
					t.Fatal(err)
				}
			}
			ymls, strct := countRules(dir)
			if ymls != tc.ymls || strct != tc.strct {
				t.Errorf("got ymls=%d structural=%v, want %d %v", ymls, strct, tc.ymls, tc.strct)
			}
		})
	}
}

func TestCountRulesNeverEntersASymlinkedDirectory(t *testing.T) {
	dir := t.TempDir()
	outside := t.TempDir()
	writeFiles(t, outside, ymlNames("o", 5)...)
	if err := os.Symlink(outside, filepath.Join(dir, "linked")); err != nil {
		t.Fatal(err)
	}
	if ymls, strct := countRules(dir); ymls != 0 || strct {
		t.Errorf("walked through a symlink: ymls=%d structural=%v", ymls, strct)
	}
}

func TestCountRulesDirectoryFanOutIsBounded(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < walkDirLimit-1; i++ {
		if err := os.MkdirAll(filepath.Join(dir, fmt.Sprintf("d%03d", i)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// the last directory inside the limit counts, the two beyond it are never visited
	writeFiles(t, dir, fmt.Sprintf("d%03d/in.yml", walkDirLimit-1), fmt.Sprintf("d%03d/out.yml", walkDirLimit), fmt.Sprintf("d%03d/out.yml", walkDirLimit+1))
	if ymls, _ := countRules(dir); ymls != 1 {
		t.Errorf("found %d rule files, want only the one inside the first %d directories", ymls, walkDirLimit)
	}
}

func TestValidateRulesDirThreshold(t *testing.T) {
	home := t.TempDir()
	e := rulesEnv{cwd: home, home: func() (string, bool) { return home, true }}
	short := filepath.Join(home, "short")
	writeFiles(t, short, ymlNames("r", minYMLCount-1)...)
	_, err := validateRulesDir(e, short)
	var f *fail
	if !errors.As(err, &f) || !strings.Contains(f.msg, fmt.Sprintf("found %d .yml files", minYMLCount-1)) {
		t.Fatalf("one rule short of the threshold: %v", err)
	}
	enough := filepath.Join(home, "enough")
	writeFiles(t, enough, ymlNames("r", minYMLCount)...)
	if got, err := validateRulesDir(e, enough); err != nil || got != enough {
		t.Fatalf("exactly the threshold: %q, %v", got, err)
	}
	marked := filepath.Join(home, "marked")
	writeFiles(t, marked, "lib/readme.txt")
	if _, err := validateRulesDir(e, marked); err != nil {
		t.Fatalf("a structural subdirectory is enough: %v", err)
	}
}

func TestRulesPathDigestValue(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, "a.yml", "d.yml/q.yml", "x/y/r.yml", "x/z.yml", "x/skip.txt", "top.txt")
	want := sha256.Sum256([]byte(strings.Join([]string{"a.yml", "d.yml", "d.yml/q.yml", "x/y/r.yml", "x/z.yml"}, "\n")))
	got, err := rulesPathDigest(dir)
	if err != nil || got != "sha256:"+hex.EncodeToString(want[:]) {
		t.Fatalf("digest %q, %v", got, err)
	}
}

func TestExpandUser(t *testing.T) {
	home := func() (string, bool) { return "/home/u", true }
	for in, want := range map[string]string{"~": "/home/u", "~/r": "/home/u/r", "~/a/b": "/home/u/a/b", "a/~": "a/~", "/x": "/x", ".": ".", "r": "r"} {
		if got, err := expandUser(in, home); err != nil || got != want {
			t.Errorf("expandUser(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	var c *crash
	if _, err := expandUser("~no-such-user-capa-test/r", home); !errors.As(err, &c) {
		t.Errorf("an unknown ~user must crash, got %v", err)
	}
}

func TestLookupEnv(t *testing.T) {
	onlyEnv := cli.Stdio{Env: func(k string) string { return map[string]string{"SET": "v", "EMPTY": ""}[k] }}
	if v, ok := lookupEnv(onlyEnv, "SET"); v != "v" || !ok {
		t.Errorf("Env fallback, set: %q %v", v, ok)
	}
	if v, ok := lookupEnv(onlyEnv, "EMPTY"); v != "" || ok {
		t.Errorf("Env fallback cannot tell empty from unset: %q %v", v, ok)
	}
	full := cli.Stdio{Environ: func() []string { return []string{"AB=2", "A=1", "EMPTY=", "EQ=a=b"} }, Env: func(string) string { return "wrong" }}
	for key, want := range map[string]string{"A": "1", "AB": "2", "EMPTY": "", "EQ": "a=b"} {
		if v, ok := lookupEnv(full, key); v != want || !ok {
			t.Errorf("Environ %s: %q %v", key, v, ok)
		}
	}
	if v, ok := lookupEnv(full, "MISSING"); v != "" || ok {
		t.Errorf("Environ missing: %q %v", v, ok)
	}
}

func TestCompleteness(t *testing.T) {
	if completeness(nil) != "complete" || completeness([]string{}) != "complete" {
		t.Error("no error is complete")
	}
	if completeness([]string{"timeout"}) != "failed" {
		t.Error("one error is failed")
	}
}

func TestRelativeFailure(t *testing.T) {
	err := errors.New("[Errno 2] No such file or directory: '/work/dir/sub/x'")
	for _, tc := range []struct{ p, cwd, want string }{
		{"sub/x", "/work/dir", "[Errno 2] No such file or directory: 'sub/x'"},
		{"sub/x", "/work/dir/", "[Errno 2] No such file or directory: 'sub/x'"},
		{"/work/dir/sub/x", "/work/dir", err.Error()},
		{"sub/x", "", err.Error()},
		{"sub/x", "/elsewhere", err.Error()},
	} {
		if got := relativeFailure(err, tc.p, tc.cwd); got != tc.want {
			t.Errorf("relativeFailure(%q, %q) = %q, want %q", tc.p, tc.cwd, got, tc.want)
		}
	}
}

func TestIsoformat(t *testing.T) {
	base := time.Date(2026, 11, 2, 7, 8, 9, 0, time.UTC)
	for _, tc := range []struct {
		t    time.Time
		want string
	}{
		{base, "2026-11-02T07:08:09Z"},
		{base.Add(500 * time.Nanosecond), "2026-11-02T07:08:09Z"}, // below a microsecond: Python prints no fraction
		{base.Add(999 * time.Nanosecond), "2026-11-02T07:08:09Z"},
		{base.Add(time.Microsecond), "2026-11-02T07:08:09.000001Z"},
		{base.Add(1500 * time.Microsecond), "2026-11-02T07:08:09.001500Z"},
		{base.Add(999999999 * time.Nanosecond), "2026-11-02T07:08:09.999999Z"},
		{base.In(time.FixedZone("x", 3600)), "2026-11-02T07:08:09Z"},
	} {
		if got := isoformat(tc.t); got != tc.want {
			t.Errorf("isoformat(%v) = %q, want %q", tc.t, got, tc.want)
		}
	}
}

func TestPyStrip(t *testing.T) {
	for in, want := range map[string]string{
		"  a b \t\n": "a b", "\x1c\x1d\x1ea\x1f": "a", "\x1ba\x1b": "\x1ba\x1b", "\x0b\x0ca\xc2\xa0": "a", "": "", "   ": "", "\x20a": "a",
	} {
		if got := pyStrip(in); got != want {
			t.Errorf("pyStrip(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestClampTimeout(t *testing.T) {
	const maxSeconds = int64(math.MaxInt64) / int64(time.Second)
	limit := time.Duration(maxSeconds) * time.Second
	for _, tc := range []struct {
		in   *big.Int
		want time.Duration
	}{
		{big.NewInt(0), 0},
		{big.NewInt(5), 5 * time.Second},
		{big.NewInt(maxSeconds - 1), time.Duration(maxSeconds-1) * time.Second},
		{big.NewInt(maxSeconds), limit},
		{big.NewInt(maxSeconds + 1), limit},
		{big.NewInt(math.MaxInt64), limit},
		{new(big.Int).Lsh(big.NewInt(1), 70), limit},
	} {
		if got := clampTimeout(tc.in); got != tc.want {
			t.Errorf("clampTimeout(%v) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func TestPyTruthy(t *testing.T) {
	nan := math.NaN()
	for _, tc := range []struct {
		v    any
		want bool
	}{
		{nil, false}, {true, true}, {false, false}, {"", false}, {"0", true}, {json.Number("0"), false}, {json.Number("7"), true},
		{json.Number("-1"), true}, {0.0, false}, {0.5, true}, {nan, true}, {[]any{}, false}, {[]any{0}, true},
		{map[string]any{}, false}, {map[string]any{"k": nil}, true}, {struct{}{}, true},
	} {
		if got := pyTruthy(tc.v); got != tc.want {
			t.Errorf("pyTruthy(%#v) = %v, want %v", tc.v, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------- the bounded run

func runShell(t *testing.T, script string, maxBytes int, now func() time.Time) (map[string]any, []string, string, string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "engine"), 0o755); err != nil {
		t.Fatal(err)
	}
	rec, errs, err := runBounded([]string{"/bin/sh", "-c", script}, dir, []string{"PATH=/usr/bin:/bin"}, big.NewInt(30), maxBytes, now)
	if err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(filepath.Join(dir, "engine", "stdout.txt"))
	er, _ := os.ReadFile(filepath.Join(dir, "engine", "stderr.txt"))
	return rec, errs, string(out), string(er)
}

func TestRunBoundedExitCodesAndSignals(t *testing.T) {
	rec, errs, out, _ := runShell(t, "printf hi", 1<<20, nil)
	if rec["exit_code"] != 0 || rec["signal"] != nil || len(errs) != 0 || out != "hi" {
		t.Errorf("clean exit: %v %v %q", rec, errs, out)
	}
	rec, errs, _, _ = runShell(t, "exit 3", 1<<20, nil)
	if rec["exit_code"] != 3 || rec["signal"] != nil || len(errs) != 1 || errs[0] != "analyzer-exit:3" {
		t.Errorf("exit 3: %v %v", rec, errs)
	}
	rec, _, _, _ = runShell(t, "kill -9 $$", 1<<20, nil)
	if rec["exit_code"] != nil || rec["signal"] != 9 {
		t.Errorf("killed by SIGKILL: %v", rec)
	}
}

func TestRunBoundedRecordsTimesAndDuration(t *testing.T) {
	base := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	n := 0
	now := func() time.Time {
		n++
		return base.Add(time.Duration(n-1) * 2500 * time.Millisecond)
	}
	rec, _, _, _ := runShell(t, "true", 1<<20, now)
	if rec["started_at"] != "2026-01-02T03:04:05Z" || rec["ended_at"] != "2026-01-02T03:04:07.500000Z" || rec["duration_ms"] != 2500 {
		t.Errorf("record: %v", rec)
	}
}

func TestRunBoundedTruncatesBothStreamsJointly(t *testing.T) {
	// 4 bytes on each stream against a 6 byte cap: the cap fires and stdout keeps its share first.
	_, errs, out, er := runShell(t, "printf aaaa; printf bbbb >&2; sleep 30", 6, nil)
	if out != "aaaa" || er != "bb" {
		t.Errorf("kept stdout %q stderr %q, want %q and %q", out, er, "aaaa", "bb")
	}
	if !strings.Contains(strings.Join(errs, ","), "output-cap") {
		t.Errorf("errors %v lack output-cap", errs)
	}
}

// 9997 is what the pinned Python 3.12 oracle accepts in a bare interpreter; the constant must not drift.
func TestDecodeJSONDepthLimit(t *testing.T) {
	for name, build := range map[string]func(n int) string{
		"array":  func(n int) string { return strings.Repeat("[", n) + strings.Repeat("]", n) },
		"object": func(n int) string { return strings.Repeat(`{"a":`, n) + "1" + strings.Repeat("}", n) },
	} {
		if _, err := decodeJSON([]byte(build(9997))); err != nil {
			t.Errorf("%s nested %d deep: %v", name, 9997, err)
		}
		var c *crash
		if _, err := decodeJSON([]byte(build(9998))); !errors.As(err, &c) || !strings.HasPrefix(c.msg, "RecursionError") {
			t.Errorf("%s nested %d deep: %v", name, 9998, err)
		}
	}
}

func TestReadStdoutJSONEmptyAndNonEmpty(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if v, msg, err := readStdoutJSON(empty); v != nil || msg != "" || err != nil {
		t.Errorf("empty file: %v %q %v", v, msg, err)
	}
	full := filepath.Join(dir, "full")
	if err := os.WriteFile(full, []byte(`{"a": [1]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if v, msg, err := readStdoutJSON(full); err != nil || msg != "" || v == nil {
		t.Errorf("document: %v %q %v", v, msg, err)
	}
}
