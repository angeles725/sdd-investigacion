//go:build linux

package adapter

import (
	"bytes"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func testEnv(cwd string) Env {
	return Env{Cwd: cwd, Get: func(string) string { return "" }}
}

func TestFileIdentityRejectsADescriptorThatChangesWhileHashed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.bin")
	if err := os.WriteFile(path, []byte("input\x00bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	real := fstatFn
	defer func() { fstatFn = real }()
	calls := 0
	fstatFn = func(fd int) (statTuple, error) {
		st, err := real(fd)
		calls++
		if calls == 2 {
			st.mtimeNs++
		}
		return st, err
	}
	_, err := fileIdentity(path, nil, testEnv(dir))
	if pe, ok := err.(*PyError); !ok || pe.Class != "ManifestError" || pe.Msg != "file changed while hashing" {
		t.Fatalf("got %v, want ManifestError %q", err, "file changed while hashing")
	}
	// The same file with an unchanged descriptor hashes cleanly: the rejection above is the stat compare.
	fstatFn = real
	id, err := fileIdentity(path, nil, testEnv(dir))
	if err != nil || id.size != 11 || id.lines != 1 {
		t.Fatalf("stable file: %+v %v", id, err)
	}
}

func TestFileIdentityRejectsASizeThatDisagreesWithTheBytesRead(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "f")
	if err := os.WriteFile(path, []byte("abc\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	real := fstatFn
	defer func() { fstatFn = real }()
	fstatFn = func(fd int) (statTuple, error) {
		st, err := real(fd)
		st.size++ // both stats agree with each other, but not with the bytes that were read
		return st, err
	}
	if _, err := fileIdentity(path, nil, testEnv(dir)); err == nil || err.Error() != "file changed while hashing" {
		t.Fatalf("got %v", err)
	}
}

func TestResolveToolRejectsALauncherReplacedAfterItWasHashed(t *testing.T) {
	root := t.TempDir()
	tool := filepath.Join(root, "bin/tool")
	if err := os.MkdirAll(filepath.Dir(tool), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tool, []byte("#!/bin/false\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	replaced := false
	afterIdentityHook = func(path string) {
		if replaced {
			return
		}
		replaced = true
		repl := filepath.Join(root, "bin/replacement")
		_ = os.WriteFile(repl, []byte("#!/bin/false\n"), 0o700)
		_ = os.Rename(repl, path)
	}
	defer func() { afterIdentityHook = nil }()
	_, err := resolveTool(tool, tool, root, map[string]string{}, testEnv(root))
	if pe, ok := err.(*PyError); !ok || pe.Msg != "tool launcher changed while resolving identity" {
		t.Fatalf("got %v", err)
	}
	if !replaced {
		t.Fatal("the hook never ran: the replacement was not exercised")
	}
}

func TestAtomicWriteIsPrivateAtomicAndLeavesNoTemporary(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "out.json")
	env := testEnv(dir)
	if err := atomicWrite(out, []byte("first\n"), false, env); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(out); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode: %v %v", fi, err)
	}
	err := atomicWrite(out, []byte("second\n"), false, env)
	if pe, ok := err.(*PyError); !ok || pe.Class != "ManifestError" || pe.Msg != "manifest exists; use --overwrite to replace it" {
		t.Fatalf("second write without overwrite: %v", err)
	}
	if b, _ := os.ReadFile(out); string(b) != "first\n" {
		t.Fatalf("refused write changed the file: %q", b)
	}
	if err := atomicWrite(out, []byte("third\n"), true, env); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(out); string(b) != "third\n" {
		t.Fatalf("overwrite: %q", b)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 || entries[0].Name() != "out.json" {
		t.Fatalf("leftovers: %v", entries)
	}
}

func TestAtomicWriteResolvesRelativeOutputAgainstTheInjectedCwd(t *testing.T) {
	dir := t.TempDir()
	if err := atomicWrite("sub/../out.json", []byte("x"), false, testEnv(dir)); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(dir, "out.json")); err != nil || string(b) != "x" {
		t.Fatalf("%q %v", b, err)
	}
}

func TestTempNameShape(t *testing.T) {
	re := regexp.MustCompile(`\A\.out\.json\.[a-z0-9_]{8}\.tmp\z`)
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		n := tempName("out.json")
		if !re.MatchString(n) {
			t.Fatalf("bad temp name %q", n)
		}
		seen[n] = true
	}
	if len(seen) < 2 {
		t.Fatal("temp names are not random")
	}
}

func TestCommandLineForms(t *testing.T) {
	run := func(args ...string) (int, string, string) {
		var out, errb bytes.Buffer
		s := cli.Stdio{In: bytes.NewReader(nil), Out: &out, Err: &errb, Env: func(string) string { return "" }, Clock: time.Now, Cwd: t.TempDir()}
		return ManifestRun(args, s), out.String(), errb.String()
	}
	for _, args := range [][]string{{"-h"}, {"--help"}, {"validate", "--help"}, {"create", "--root", "r", "-h"}} {
		if rc, out, errs := run(args...); rc != 0 || out != usageText || errs != "" {
			t.Errorf("%v: rc=%d out=%q err=%q", args, rc, out, errs)
		}
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{nil, "the following arguments are required: command"},
		{[]string{"bogus"}, "argument command: invalid choice: 'bogus' (choose from 'create', 'validate', 'verify')"},
		{[]string{"validate"}, "the following arguments are required: manifest"},
		{[]string{"validate", "a", "b"}, "unrecognized arguments: b"},
		{[]string{"validate", "--root", "r", "a"}, "unrecognized arguments: --root"},
		{[]string{"verify", "m"}, "the following arguments are required: --root"},
		{[]string{"verify", "--root"}, "argument --root: expected one argument"},
		{[]string{"create", "--root", "r"}, "the following arguments are required: --spec, --output"},
		{[]string{"create", "--root", "r", "--spec", "s", "--output", "o", "--bogus"}, "unrecognized arguments: --bogus"},
		{[]string{"verify", "--overwrite", "--root", "r", "m"}, "unrecognized arguments: --overwrite"},
		{[]string{"create", "--root=r", "--spec", "s", "--output", "o"}, "unrecognized arguments: --root=r"},
	} {
		rc, out, errs := run(c.args...)
		if rc != 2 || out != "" || errs != usageText+"analysis_manifest.py: error: "+c.want+"\n" {
			t.Errorf("%v: rc=%d out=%q err=%q, want error %q", c.args, rc, out, errs, c.want)
		}
	}
}

func TestCommandLineAcceptsOptionsInAnyOrderAndTheirValuesVerbatim(t *testing.T) {
	ns, help, err := parseArgs([]string{"create", "--output", "o//x", "--overwrite", "--spec", "./s", "--root", "r"})
	if err != nil || help || ns != (parsed{command: "create", root: "r", spec: "s", output: "o/x", overwrite: true}) {
		t.Fatalf("%+v %v %v", ns, help, err)
	}
	ns, _, err = parseArgs([]string{"verify", "m.json", "--root", "r"})
	if err != nil || ns != (parsed{command: "verify", root: "r", manifest: "m.json"}) {
		t.Fatalf("%+v %v", ns, err)
	}
}

func TestFileIdentityCountsLinesLikePython(t *testing.T) {
	dir := t.TempDir()
	for body, want := range map[string]int64{"": 0, "x": 1, "\n": 1, "x\n": 1, "a\nb": 2, "a\nb\n": 2, "\n\n": 2} {
		p := filepath.Join(dir, "f")
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		id, err := fileIdentity(p, nil, testEnv(dir))
		if err != nil || id.lines != want || id.size != int64(len(body)) {
			t.Errorf("%q: %+v %v, want %d lines", body, id, err, want)
		}
	}
}

func TestResolveFDWithoutProcResolvesThePathItself(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "real/f"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real", filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	want, _ := filepath.EvalSymlinks(filepath.Join(dir, "real/f"))
	real := readlinkFn
	defer func() { readlinkFn = real }()
	readlinkFn = func(string) (string, error) { return "", os.ErrNotExist }
	if got := resolveFD(0, "link/f", testEnv(dir)); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	readlinkFn = func(string) (string, error) { return filepath.Join(dir, "gone/x"), nil } // deleted after opening
	if got := resolveFD(0, "elsewhere", testEnv(dir)); got != filepath.Join(dir, "gone/x") {
		t.Fatalf("a missing target must resolve to itself, got %q", got)
	}
	readlinkFn = func(string) (string, error) { return filepath.Join(dir, "real/f"), nil }
	if got := resolveFD(0, "elsewhere", testEnv(dir)); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestAtomicWriteDrawsAnotherTemporaryNameWhenOneIsTaken(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".taken.tmp"), []byte("mine"), 0o600); err != nil {
		t.Fatal(err)
	}
	names := []string{".taken.tmp", ".taken.tmp", ".fresh.tmp"}
	real := newTempName
	defer func() { newTempName = real }()
	newTempName = func(string) string { n := names[0]; names = names[1:]; return n }
	if err := atomicWrite(filepath.Join(dir, "out.json"), []byte("payload"), false, testEnv(dir)); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "out.json")); string(b) != "payload" {
		t.Fatalf("out.json = %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".taken.tmp")); string(b) != "mine" {
		t.Fatalf("the taken name was overwritten: %q", b)
	}
	if len(names) != 0 {
		t.Fatalf("expected three draws, %d left", len(names))
	}
	newTempName = func(string) string { return "no-such-dir/x.tmp" }
	if err := atomicWrite(filepath.Join(dir, "o2.json"), nil, false, testEnv(dir)); err == nil || !strings.Contains(err.Error(), "No such file") {
		t.Fatalf("a failure other than a taken name must be reported: %v", err)
	}
}

func TestPublishNewFallsBackToAHardLinkWhereNoReplaceIsUnavailable(t *testing.T) {
	dir := t.TempDir()
	real := publishFn
	defer func() { publishFn = real }()
	publishFn = func(string, string) error { return fsx.ErrUnavailable }
	tmp, final := filepath.Join(dir, "tmp"), filepath.Join(dir, "final")
	if err := os.WriteFile(tmp, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := publishNew(tmp, final); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(final); string(b) != "new" {
		t.Fatalf("final = %q", b)
	}
	err := publishNew(tmp, final) // final exists now
	if err == nil || err.Error() != "manifest exists; use --overwrite to replace it" {
		t.Fatalf("got %v", err)
	}
	if err := publishNew(filepath.Join(dir, "gone"), filepath.Join(dir, "other")); err == nil || !strings.Contains(err.Error(), "No such file") {
		t.Fatalf("a link failure must be reported: %v", err)
	}
}
