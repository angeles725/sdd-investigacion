package adapter

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func TestManifestCommandIsRegisteredAndRunsThroughTheDispatcher(t *testing.T) {
	if len(Commands) != 1 || Commands[0].Group != "adapter" || Commands[0].Name != "manifest" {
		t.Fatalf("Commands = %+v", Commands)
	}
	run := func(cwd string, args ...string) (int, string, string) {
		var out, errb bytes.Buffer
		s := cli.Stdio{In: bytes.NewReader(nil), Out: &out, Err: &errb, Env: func(string) string { return "" }, Clock: time.Now, Cwd: cwd}
		return cli.Run(Commands, args, s), out.String(), errb.String()
	}
	dir := t.TempDir()
	rc, out, errs := run(dir, "adapter", "manifest", "-h")
	if rc != 0 || !strings.HasPrefix(out, "usage: analysis_manifest.py {create,validate,verify} ...\n") || errs != "" {
		t.Fatalf("help: rc=%d out=%q err=%q", rc, out, errs)
	}
	rc, out, errs = run(dir, "adapter", "manifest", "validate", "missing.json")
	if rc != 2 || out != "" || errs != "analysis-manifest: [Errno 2] No such file or directory: 'missing.json'\n" {
		t.Fatalf("missing file: rc=%d out=%q err=%q", rc, out, errs)
	}
	if err := os.WriteFile(filepath.Join(dir, "m.json"), []byte("[1]"), 0o644); err != nil {
		t.Fatal(err)
	}
	rc, _, errs = run(dir, "adapter", "manifest", "validate", "m.json")
	if rc != 2 || errs != "analysis-manifest: JSON root must be an object\n" {
		t.Fatalf("non-object: rc=%d err=%q", rc, errs)
	}
}
