package kitwait

import (
	"os"
	"path/filepath"
	"testing"
)

// writeScript writes an executable; these tests never run in parallel (ETXTBSY, golang/go#22315).
func writeScript(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestExecMergeGate(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"--cwd", "/w", "--merge", "7"}
	env := []string{"PATH=/usr/bin:/bin"}

	// KIT_MERGE_GATE: `bash script args`, stdout and stderr in one stream, cwd = the worktree, the script's rc
	gate := writeScript(t, dir, "mg.sh", `echo "out $* @ $PWD"; echo "err" >&2; exit 5`)
	rc, out := ExecMergeGate(env, dir, gate, "unused")(args)
	if rc != 5 || out != "out --cwd /w --merge 7 @ "+dir+"\nerr\n" {
		t.Errorf("script: rc=%d out=%q", rc, out)
	}

	// no script: the binary runs its own `gate merge`
	self := writeScript(t, dir, "rsdd", `echo "self $*"; exit 0`)
	rc, out = ExecMergeGate(env, dir, "", self)(args)
	if rc != 0 || out != "self gate merge --cwd /w --merge 7\n" {
		t.Errorf("self: rc=%d out=%q", rc, out)
	}

	// not runnable: 127, never a silent zero
	if rc, _ = ExecMergeGate(env, dir, "", filepath.Join(dir, "absent"))(args); rc != 127 {
		t.Errorf("missing binary rc=%d, want 127", rc)
	}
	if rc, _ = ExecMergeGate(env, filepath.Join(dir, "no-such-dir"), gate, "")(args); rc != 127 {
		t.Errorf("missing dir rc=%d, want 127", rc)
	}
	if exe := Self(); exe == "" || !filepath.IsAbs(exe) {
		t.Errorf("Self() = %q", exe)
	}
}
