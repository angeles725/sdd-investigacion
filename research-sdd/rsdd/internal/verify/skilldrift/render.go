package skilldrift

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Profile renders. A non-"claude" profile is compared against a fresh render of that profile into a throwaway directory, never
// the kit and never $home (propose-never-apply extended to renders). The render is the kit's own render-profile.sh, run through
// the exec seam; nothing here re-implements it.

// renderer runs render-profile.sh of one kit.
type renderer struct {
	script string
	env    []string
	dir    string
	tmpDir string // mktemp's directory
}

// mktemp is `mktemp -d`: a fresh 0700 directory under the temp dir, named tmp.XXXXXXXXXX.
func (r *renderer) mktemp() (string, error) {
	return os.MkdirTemp(r.tmpDir, "tmp.")
}

// run is `"$script" "$profile" "$dst" 2>&1`: the combined output, with the trailing newlines of a command substitution removed.
// ok is false for a non-zero exit, and for a script that cannot be started (reported as the shell reports it: rc 126 or 127 and
// the reason in the output).
func (r *renderer) run(profile, dst string) (out string, ok bool) {
	c := exec.Command(r.script, profile, dst)
	c.Env, c.Dir = r.env, r.dir
	var buf bytes.Buffer // one writer for both streams keeps their interleaving
	c.Stdout, c.Stderr = &buf, &buf
	err := c.Run()
	if err == nil {
		return strings.TrimRight(buf.String(), "\n"), true
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return strings.TrimRight(buf.String(), "\n"), false
	}
	reason := "No such file or directory"
	if errors.Is(err, os.ErrPermission) {
		reason = "Permission denied"
	}
	return fmt.Sprintf("%s: %s", r.script, reason), false
}

// renderStatus is the word _vsd_check_render_completeness prints.
type renderStatus string

const (
	renderOK         renderStatus = "ok"
	renderMissing    renderStatus = "missing"
	renderDiverged   renderStatus = "diverged"
	renderIncomplete renderStatus = "incomplete"
	renderError      renderStatus = "error"
)

// persistedFiles are re-rendered and compared byte for byte; persistedLinks must still resolve (kit issue #1024 review F1).
var (
	persistedFiles = []string{"skills/research-sdd/SKILL.md", "PROMPT-LOOP.md", "METHODOLOGY.md"}
	persistedLinks = []string{"toolbelt", "TARGETS.md", "skills/README.md"}
)

// completeness verifies that the PERSISTED render dir of a non-claude profile, <configRoot>/research-sdd/profile/<profile>, still
// exists and is intact: its rendered files still match a fresh re-render, and the F1-completion links still resolve. Every
// outcome other than renderOK is a drift or could-not-run state the caller must never fold into "in sync" (kit issue #1024).
func (r *renderer) completeness(configRoot, profile string) renderStatus {
	renderDir := filepath.Join(configRoot, "research-sdd", "profile", profile)
	if !isDir(renderDir) {
		return renderMissing
	}
	tmp, err := r.mktemp()
	if err != nil {
		return renderError
	}
	defer os.RemoveAll(tmp)
	if _, ok := r.run(profile, tmp); !ok {
		return renderError
	}
	for _, rel := range persistedFiles {
		if !sameBytes(filepath.Join(tmp, rel), filepath.Join(renderDir, rel)) {
			return renderDiverged
		}
	}
	for _, f := range persistedLinks {
		if !exists(filepath.Join(renderDir, f)) {
			return renderIncomplete
		}
	}
	return renderOK
}
