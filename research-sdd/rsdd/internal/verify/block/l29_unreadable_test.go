package block

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// l29Evidence is a target with one evidence block citing a.sh:1 and a preserved probe script with its manifest.
var l29Evidence = map[string]string{
	"b-block1.md":                           "# Block 1 — t\n\n> Type: evidence. Method: [CERT] = x.\n\n---\n\n[CERT] See `a.sh:1` and `sources/probes/b1/p.sh:1`.\n",
	"a.sh":                                  "x\n",
	"sources/probes/b1/p.sh":                "echo\n",
	"sources/probes/b1/SCRIPTS-MANIFEST.md": "| script | sha256 |\n|---|---|\n| p.sh | " + strings.Repeat("0", 64) + " |\n",
	"sources/probes/locked/x":               "",
}

// l29Correction is a block in d/ that corrects Block 1, whose candidates are searched in d/ and the target e/.
var l29Correction = map[string]string{
	"d/x-block3.md": "# Block 3\n\nThis corrects Block 1.\n",
	"d/x-block1.md": "# Block 1\n",
	"e/keep":        "",
}

func l29Kit(t *testing.T, lock ...string) string { return l29Tree(t, l29Evidence, lock...) }

// l29Tree writes files below a fresh root and makes the paths lock names unreadable (mode 000); it skips where a
// mode-000 path stays readable (root).
func l29Tree(t *testing.T, files map[string]string, lock ...string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for rel, body := range files {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, rel := range lock {
		p := filepath.Join(root, rel)
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(p, st.Mode().Perm()) }) //nolint:errcheck // so t.TempDir can remove it
		if f, err := os.Open(p); err == nil {
			f.Close()
			t.Skip("a mode-000 path is still readable here (running as root)")
		}
	}
	return root
}

func l29Run(t *testing.T, root string, want ...string) {
	t.Helper()
	got := bkGo(root, []string{"b-block1.md", root}, []string{"HOME=" + root, "LC_ALL=C.UTF-8", "PATH=/usr/bin:/bin"})
	if got.RC != 1 {
		t.Errorf("rc = %d, want 1 (a degraded scan is never a pass)", got.RC)
	}
	for _, w := range append(want, "== exit 1 ==\n") {
		if !strings.Contains(got.Stdout, strings.ReplaceAll(w, "{T}", root)) {
			t.Errorf("stdout lacks %q\n%s", w, got.Stdout)
		}
	}
}

// A cited file that exists but cannot be read is a degraded cite, never a pass and never MISSING!.
func TestBlockUnreadableCiteIsLineCountDegraded(t *testing.T) {
	t.Parallel()
	l29Run(t, l29Kit(t, "a.sh"), "   linecount DEGRADED  a.sh:1 (line count failed)\n", "   resolved 1 of 2 (0 extern, 0 failed, 1 degraded)\n")
}

// An unreadable directory under sources/probes, or an unreadable manifest, leaves the cited scripts unchecked, and
// the report says so.
func TestBlockUnreadableProbesAreManifestDegraded(t *testing.T) {
	t.Parallel()
	l29Run(t, l29Kit(t, "sources/probes/locked"),
		"   ERROR: DEGRADED manifest scan failed (find exit 1 under {T}/sources/probes) — cited scripts NOT manifest-checked\n")
	l29Run(t, l29Kit(t, "sources/probes/b1/SCRIPTS-MANIFEST.md"),
		"   ERROR: DEGRADED manifest parse failed (shared parser, under {T}/sources/probes) — cited scripts NOT manifest-checked\n")
}

// A cited preserved script that cannot be read is MANIFEST!: its sha256 was never computed.
func TestBlockUnreadablePreservedScriptIsManifestFail(t *testing.T) {
	t.Parallel()
	l29Run(t, l29Kit(t, "sources/probes/b1/p.sh"),
		"   MANIFEST!  sources/probes/b1/p.sh  (preserved file exists but is unreadable — sha256 not computed)\n",
		"-- preserved-script manifest findings: 1 (FAIL)\n")
}

// A correction sentence whose earlier block cannot be read, or whose candidate directory cannot be listed, leaves the
// back-pointer unchecked and says why, per line. The back-pointer pass is advisory (exit unchanged), so the run exits 0; the DEGRADED line is the signal.
func TestBlockUnreadableBackptrIsDegraded(t *testing.T) {
	t.Parallel()
	run := func(root string, want string) {
		t.Helper()
		got := bkGo(root, []string{"d/x-block3.md", "e"}, []string{"HOME=" + root, "LC_ALL=C.UTF-8"})
		if got.RC != 0 {
			t.Errorf("rc = %d, want 0 (the back-pointer pass never changes the exit code)", got.RC)
		}
		if w := strings.ReplaceAll(want, "{T}", root); !strings.Contains(got.Stdout, w) {
			t.Errorf("stdout lacks %q\n%s", w, got.Stdout)
		}
	}
	run(l29Tree(t, l29Correction, "d/x-block1.md"),
		"   DEGRADED backptr: line 3: block 1 (x-block1.md) is unreadable — back-pointer NOT checked\n")
	noBlock1 := map[string]string{"d/x-block3.md": l29Correction["d/x-block3.md"], "e/keep": ""}
	run(l29Tree(t, noBlock1, "e"),
		"   DEGRADED backptr: line 3: block 1 — the candidate scan under {T}/d {T}/e failed; back-pointer NOT checked\n")
}
