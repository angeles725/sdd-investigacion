package kitmaint

import (
	"bytes"
	"strings"
	"testing"
)

// An empty dir leaves git in the process directory; a dir is passed as `git -C <abs dir>`.
func TestGitEmptyDirStaysInTheProcessDirectory(t *testing.T) {
	bin, runnerCwd, procCwd := scratch(t), scratch(t), scratch(t)
	script(t, bin, "git", `echo "args=$*"; pwd`)
	t.Chdir(procCwd)
	var eb bytes.Buffer
	r := testRunner([]string{"PATH=" + bin + ":/usr/bin:/bin"}, runnerCwd, &eb, &clock{}, nil)
	res := r.Git("", "status")
	if res.Out != "args=-C  status\n"+procCwd+"\n" {
		t.Errorf("empty dir: %q (want an empty -C, run in %s)", res.Out, procCwd)
	}
	res = r.Git("sub", "status")
	if !strings.HasPrefix(res.Out, "args=-C "+runnerCwd+"/sub status\n") {
		t.Errorf("relative dir: %q (want -C <runner cwd>/sub)", res.Out)
	}
}
