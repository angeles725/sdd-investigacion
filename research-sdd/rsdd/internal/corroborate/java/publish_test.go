package java

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExistingRootRequiresExplicitOverwrite(t *testing.T) {
	h := newHarness(t)
	if r := h.run(h.args("--output", h.out("out one"))...); r.rc != 0 {
		t.Fatalf("first run rc=%d %s", r.rc, r.err)
	}
	r := h.run(h.args("--output", h.out("out one"))...)
	if r.rc != 2 || !strings.Contains(r.err, "output root exists; pass --overwrite") {
		t.Fatalf("second run rc=%d stderr=%q", r.rc, r.err)
	}
	if h.exists(h.root, ".out one.stage") {
		t.Error("the refused run left its stage behind")
	}
	if r := h.run(h.args("--output", h.out("out one"), "--overwrite")...); r.rc != 0 {
		t.Fatalf("overwrite rc=%d %s", r.rc, r.err)
	}
	if h.exists(h.root, ".out one.stage") {
		t.Error("an overwrite left the old tree behind as the stage")
	}
}

func TestOverwriteReplacesAnExistingRootWholesale(t *testing.T) {
	h := newHarness(t)
	old := h.out("old")
	if err := os.MkdirAll(old, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(old, "stale.txt"), []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	if r := h.run(h.args("--output", old, "--overwrite")...); r.rc != 0 {
		t.Fatalf("rc=%d %s", r.rc, r.err)
	}
	if h.exists(old, "stale.txt") || !h.exists(old, schema+".json") {
		t.Error("the new tree must replace the old one entirely")
	}
}

// interrupted simulates a process that dies between the exchange and the removal of the old tree.
func TestInterruptedOverwriteStaysVisibleAndTheNextRunRecovers(t *testing.T) {
	dir := t.TempDir()
	destination := filepath.Join(dir, "publication")
	if err := os.Mkdir(destination, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{".corroborate-java-stage": stageMarker, "old": "old"} {
		if err := os.WriteFile(filepath.Join(destination, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	lock, err := lockParent(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	stage, err := prepareStage(destination)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "new"), []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}
	boom := errors.New("simulated interruption")
	saved := removeTree
	removeTree = func(string) error { return boom }
	err = publish(stage, destination, true)
	removeTree = saved
	if err == nil {
		t.Fatal("the simulated interruption did not occur")
	}
	if got, _ := os.ReadFile(filepath.Join(destination, "new")); string(got) != "new" || pathExists(filepath.Join(destination, "old")) {
		t.Fatal("the new tree must already be the visible destination")
	}
	if got, _ := os.ReadFile(filepath.Join(stage, "old")); string(got) != "old" {
		t.Fatal("the old tree must wait in the stage")
	}
	recovered, err := prepareStage(destination)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(destination, "new")); string(got) != "new" || pathExists(filepath.Join(recovered, "old")) {
		t.Error("the next run must clear the leftover stage and keep the published tree")
	}
}

func TestUnmanagedStagePathIsRefusedAndKept(t *testing.T) {
	cases := map[string]func(stage string) error{
		"no marker": func(s string) error { return os.Mkdir(s, 0o755) },
		"wrong marker": func(s string) error {
			_ = os.Mkdir(s, 0o755)
			return os.WriteFile(s+"/.corroborate-java-stage", []byte("x"), 0o644)
		},
		"a file":    func(s string) error { return os.WriteFile(s, nil, 0o644) },
		"a symlink": func(s string) error { return os.Symlink(os.TempDir(), s) },
	}
	for name, make := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			stage := filepath.Join(dir, ".out.stage")
			if err := make(stage); err != nil {
				t.Fatal(err)
			}
			_, err := prepareStage(filepath.Join(dir, "out"))
			if err == nil || err.Error() != "staging path exists and is not managed by corroborate-java" {
				t.Fatalf("err = %v", err)
			}
			if _, serr := os.Lstat(stage); serr != nil {
				t.Error("an unmanaged path must never be removed")
			}
		})
	}
}

func TestManagedLeftoverStageIsClearedIncludingReadOnlyTrustedTools(t *testing.T) {
	dir := t.TempDir()
	stage := filepath.Join(dir, ".out.stage")
	if err := os.MkdirAll(filepath.Join(stage, "trusted-tools"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, ".corroborate-java-stage"), []byte(stageMarker), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "trusted-tools", "x.jar"), nil, 0o400); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(stage, "trusted-tools"), 0o500); err != nil {
		t.Fatal(err)
	}
	got, err := prepareStage(filepath.Join(dir, "out"))
	if err != nil || got != stage {
		t.Fatalf("prepareStage = %q, %v", got, err)
	}
	if pathExists(filepath.Join(stage, "trusted-tools")) {
		t.Error("the leftover tree survived")
	}
	if fi, _ := os.Stat(stage); fi.Mode().Perm() != 0o700 {
		t.Errorf("stage mode = %v, want 0700", fi.Mode().Perm())
	}
}

func TestSecondPublicationInTheSameParentIsRefused(t *testing.T) {
	dir := t.TempDir()
	first, err := lockParent(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if _, err := lockParent(dir); err == nil || err.Error() != "another publication is active in the output parent" {
		t.Fatalf("err = %v", err)
	}
	first.Close()
	again, err := lockParent(dir)
	if err != nil {
		t.Fatalf("the lock must be free once the holder closed it: %v", err)
	}
	again.Close()
}

func TestPublishRefusesSymlinkAndNonDirectoryDestinations(t *testing.T) {
	dir := t.TempDir()
	stage := filepath.Join(dir, "stage")
	if err := os.Mkdir(stage, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(dir, link); err != nil {
		t.Fatal(err)
	}
	if err := publish(stage, link, true); err == nil || err.Error() != "output root must not be a symlink" {
		t.Errorf("symlink: %v", err)
	}
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := publish(stage, file, true); err == nil || err.Error() != "output root must be a directory" {
		t.Errorf("file: %v", err)
	}
	if err := publish(stage, file, false); err == nil || err.Error() != "output root exists; pass --overwrite" {
		t.Errorf("no overwrite: %v", err)
	}
}

func TestCollisionsAndSymlinksFailClosed(t *testing.T) {
	h := newHarness(t)
	alias := h.out("input-alias")
	if err := os.Symlink(filepath.Dir(h.input), alias); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(h.input)
	for name, out := range map[string]string{
		"output root is a symlink":        alias,
		"output root contains the input":  filepath.Dir(h.input),
		"output root is the input itself": h.input,
		"output root is the java home":    h.javaHome,
		"output root is the launcher":     h.bwrap,
	} {
		r := h.run(h.args("--output", out, "--overwrite")...)
		if r.rc != 2 {
			t.Errorf("%s: rc=%d stderr=%q", name, r.rc, r.err)
		}
	}
	if after, _ := os.ReadFile(h.input); string(after) != string(before) {
		t.Fatal("the input was modified by a refused run")
	}
	// A symlinked decompiler JAR is refused as a source; its target may not be opened through the link.
	link := h.out("tools/vineflower-link.jar")
	if err := os.Symlink(h.tools["vineflower"], link); err != nil {
		t.Fatal(err)
	}
	h.env["RSDD_CORROBORATE_VINEFLOWER"] = link
	if r := h.run(h.args("--output", h.out("artifact-link"))...); r.rc != 2 || !strings.Contains(r.err, "vineflower source cannot be opened safely") {
		t.Errorf("symlinked source: rc=%d stderr=%q", r.rc, r.err)
	}
}

func TestOutputRootCollidingWithAProtectedArtifactIsNamed(t *testing.T) {
	h := newHarness(t)
	r := h.run(h.args("--output", h.root)...) // the temp root holds every input
	if r.rc != 2 || !strings.Contains(r.err, "output root collides with protected artifact: ") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
}

func TestOutputRootMustNameANewDirectoryUnderAnExistingParent(t *testing.T) {
	h := newHarness(t)
	if r := h.run(h.args("--output", "/")...); r.rc != 2 || !strings.Contains(r.err, "output root must name a new directory") {
		t.Errorf("root: rc=%d stderr=%q", r.rc, r.err)
	}
	r := h.run(h.args("--output", h.out("missing/parent/out"))...)
	if r.rc != 2 || !strings.Contains(r.err, "[Errno 2] No such file or directory: ") {
		t.Errorf("missing parent: rc=%d stderr=%q", r.rc, r.err)
	}
	file := h.out("a-file")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if r := h.run(h.args("--output", file)...); r.rc != 2 || !strings.Contains(r.err, "output root must be a directory") {
		t.Errorf("file: rc=%d stderr=%q", r.rc, r.err)
	}
}

func TestRelativeOutputAndHomeExpansionResolveAgainstTheInjectedEnvironment(t *testing.T) {
	h := newHarness(t)
	if r := h.run(h.args("--output", "rel-out")...); r.rc != 0 {
		t.Fatalf("relative rc=%d %s", r.rc, r.err)
	}
	if !h.exists(h.root, "rel-out", schema+".json") {
		t.Error("a relative output belongs under the injected working directory")
	}
	if r := h.run(h.args("--output", "~/home-out")...); r.rc != 0 {
		t.Fatalf("~ rc=%d %s", r.rc, r.err)
	}
	if !h.exists(h.root, "home-out", schema+".json") {
		t.Error("~ expands to the injected HOME")
	}
}
