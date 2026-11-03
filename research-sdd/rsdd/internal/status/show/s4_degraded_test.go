package show

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The intended divergences of the port from the script (tool-registry.d/research-sdd-status.md): where the script
// swallowed a failure and went on with a partial or unverified picture, the port stops with a typed line on stderr,
// exit 1, no verdict on stdout, and leaves the corpus as it found it. The frozen scripts have no scenario for these.

// degradedWorld runs the public entry over files (relative to the target) with the given toolbelt directory.
func degradedWorld(t *testing.T, toolbelt string, f files, args ...string) (rc int, out, errb, root string) {
	t.Helper()
	root = t.TempDir()
	for rel, body := range f {
		p := filepath.Join(root, strings.TrimPrefix(rel, "corpus/"))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var o, e bytes.Buffer
	s := cli.Stdio{Out: &o, Err: &e, Cwd: root, Env: func(k string) string {
		if k == "RSDD_TOOLBELT_DIR" {
			return toolbelt
		}
		return ""
	}}
	rc = Run(append([]string{root}, args...), s)
	return rc, o.String(), e.String(), root
}

func readTree(t *testing.T, root string) string {
	t.Helper()
	var b strings.Builder
	_ = filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() {
			body, _ := os.ReadFile(p)
			b.WriteString(p + "\x00" + string(body) + "\x00")
		}
		return nil
	})
	return b.String()
}

func TestListingFailureStopsTheRun(t *testing.T) {
	old := listStateFiles
	t.Cleanup(func() { listStateFiles = old })
	state := st4("", "0", -1, "", row("high", "G1 live", "pending"))
	for _, mode := range []string{"--next", "--sync-state"} {
		t.Run(mode, func(t *testing.T) {
			listStateFiles = func(dir string) ([]string, error) {
				return []string{dir + "/RESEARCH-STATE.md"}, errors.New("boom")
			}
			verifyWith(t, 0, "")
			dir := t.TempDir()
			path := filepath.Join(dir, "RESEARCH-STATE.md")
			if err := os.WriteFile(path, []byte(state), 0o644); err != nil {
				t.Fatal(err)
			}
			var o, e bytes.Buffer
			s := cli.Stdio{Out: &o, Err: &e, Cwd: dir, Env: func(string) string { return "" }}
			rc := Run([]string{dir, mode}, s)
			if rc != 1 || o.Len() != 0 || e.String() != "research-sdd-status: degraded: cannot list the state files under "+dir+": boom\n" {
				t.Errorf("rc=%d stdout=%q stderr=%q", rc, o.String(), e.String())
			}
			if got, _ := os.ReadFile(path); string(got) != state {
				t.Errorf("the state file changed:\n%s", got)
			}
		})
	}
}

func TestVerifyStateUnavailableIsNoVerdict(t *testing.T) {
	state := st4("", "0", -1, "", row("high", "G1 live", "pending"))
	empty, noexec := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(noexec, "verify-state.sh"), []byte("#!/bin/sh\nexit 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(noexec, "verify-state.sh"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ name, toolbelt, reason string }{
		{"unset", "", "RSDD_TOOLBELT_DIR is not set"},
		{"missing", empty, empty + "/verify-state.sh not found"},
		{"not executable", noexec, noexec + "/verify-state.sh is not executable"},
	} {
		t.Run(c.name, func(t *testing.T) {
			rc, out, errb, root := degradedWorld(t, c.toolbelt, files{"corpus/RESEARCH-STATE.md": state}, "--next")
			if rc != 1 || out != "" || errb != "research-sdd-status: degraded: verify-state unavailable ("+c.reason+")\n" {
				t.Errorf("rc=%d stdout=%q stderr=%q", rc, out, errb)
			}
			if got, _ := os.ReadFile(filepath.Join(root, "RESEARCH-STATE.md")); string(got) != state {
				t.Errorf("the state file changed")
			}
		})
	}
}

// A corpus whose only failing focus is stopped is forgiven by the bypass; with verify-state itself unavailable the
// bypass must not hand out a NEXT nobody verified.
func TestVerifyStateUnavailableDoesNotFeedTheStoppedFocusBypass(t *testing.T) {
	verifyWith(t, 127, "")
	f := files{
		"corpus/RESEARCH-STATE-a.md": st4("", "0", -1, "", row("high", "G1 live", "pending")),
		"corpus/RESEARCH-STATE-b.md": st4("", "0", -1, "", row("high", "G2 parked", "pending")),
		"corpus/FOCUSES.md":          focusRows("b", "stopped"),
	}
	rc, out, errb, root := degradedWorld(t, "/tb", f, "--next")
	if rc != 1 || out != "" || errb != "research-sdd-status: degraded: verify-state unavailable (/tb/verify-state.sh not found)\n" {
		t.Errorf("rc=%d stdout=%q stderr=%q", rc, out, errb)
	}
	if !strings.Contains(readTree(t, root), "G1 live") {
		t.Errorf("the corpus was altered")
	}
}

// verify-state.sh is a shim that re-hashes the Go sources on every call unless it is given RSDD_BIN: the child gets
// this binary, and a caller's own choice stays.
func TestExecVerifyHandsOverItsBinary(t *testing.T) {
	tb := t.TempDir()
	stub := "#!/bin/sh\necho \"bin=$RSDD_BIN\"\n"
	if err := os.WriteFile(filepath.Join(tb, "verify-state.sh"), []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	for _, c := range []struct{ name, callerBin, want string }{
		{"unset", "", "bin=" + exe + "\n"},
		{"caller's own", "/custom/rsdd", "bin=/custom/rsdd\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			var o bytes.Buffer
			s := cli.Stdio{Out: &o, Err: &bytes.Buffer{}, Cwd: tb,
				Env: func(k string) string {
					return map[string]string{"RSDD_TOOLBELT_DIR": tb, "RSDD_BIN": c.callerBin}[k]
				},
				Environ: func() []string {
					env := []string{"PATH=" + os.Getenv("PATH")}
					if c.callerBin != "" {
						env = append(env, "RSDD_BIN="+c.callerBin)
					}
					return env
				}}
			if rc := execVerify([]string{"t"}, s); rc != 0 || o.String() != c.want {
				t.Errorf("rc=%d out=%q, want %q", rc, o.String(), c.want)
			}
		})
	}
}
