package parity

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const (
	kitTargetPaths = "../../../../toolbelt/lib/target-paths.sh"
	kitTargetsMD   = "../../../../TARGETS.md"
)

// bashTargets runs the legacy target_paths_all and returns its token list.
func bashTargets(t *testing.T, targetsMD, rh string) []string {
	t.Helper()
	lib, err := filepath.Abs(kitTargetPaths)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", "-c", `. "$1" && target_paths_all "$2"`, "_", lib, targetsMD)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C", "HOME=" + rh, "RESEARCH_HOME=" + rh}
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("bash target_paths_all failed: %v", err)
	}
	var toks []string
	for l := range strings.SplitSeq(strings.TrimRight(string(out), "\n"), "\n") {
		if l != "" {
			toks = append(toks, l)
		}
	}
	return toks
}

func needBashAndLib(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available: cannot cross-check the Go TARGETS.md parser against target-paths.sh")
	}
	if _, err := os.Stat(kitTargetPaths); err != nil {
		t.Skipf("legacy %s not found from the package dir (%v): cross-check not run", kitTargetPaths, err)
	}
}

// The Go parser must yield exactly the token list target_paths_all prints.
func TestParseTargetsMatchesBashOnFixtures(t *testing.T) {
	needBashAndLib(t)
	for _, tt := range targetFixtures {
		t.Run(tt.name, func(t *testing.T) {
			f := filepath.Join(t.TempDir(), "TARGETS.md")
			if err := os.WriteFile(f, []byte(tt.body), 0o644); err != nil {
				t.Fatal(err)
			}
			want := bashTargets(t, f, tt.rh)
			got, err := ParseTargets(f, tt.rh)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) && !(len(got) == 0 && len(want) == 0) {
				t.Fatalf("go %q != bash %q", got, want)
			}
		})
	}
}

func TestParseTargetsMatchesBashOnRealTargetsMD(t *testing.T) {
	needBashAndLib(t)
	if _, err := os.Stat(kitTargetsMD); err != nil {
		t.Skipf("real TARGETS.md not found (%v)", err)
	}
	for _, rh := range []string{"/home/someone", "/srv/rh/"} {
		want := bashTargets(t, kitTargetsMD, rh)
		if len(want) == 0 {
			t.Fatal("bash parsed 0 tokens from the real TARGETS.md: the cross-check would prove nothing")
		}
		got, err := ParseTargets(kitTargetsMD, rh)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("RESEARCH_HOME=%s\ngo   %q\nbash %q", rh, got, want)
		}
	}
}
