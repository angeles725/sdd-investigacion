//go:build unix && !nodiff

package cishard

import (
	"fmt"
	"os/exec"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// Guard-to-test table: the manifests this package writes are read UNCHANGED by the real toolbelt/tests/shard-join.sh.
// complete green set -> "Shard join: OK"; one package missing -> MISSING SUITE; a failed shard -> SHARD FAILED and FAILED
// SUITE; an empty stream -> SHARD FAILED (the forced exit=1); a SKIP row under --strict-skip -> SKIPPED SUITE.

// join runs the real shard-join.sh over the given manifests and returns its combined output and exit code.
func join(t *testing.T, expected string, extra []string, manifests ...string) (string, int) {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash is required to run the real shard-join.sh: %v", err)
	}
	args := append([]string{kitroot.Path(t, "toolbelt", "tests", "shard-join.sh"), "--expected", expected, "--shards", "2"}, extra...)
	cmd := exec.Command(bash, append(args, manifests...)...)
	out, err := cmd.CombinedOutput()
	rc := 0
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("running shard-join.sh: %v", err)
	}
	return string(out), rc
}

// shardManifest writes the manifest of shard i/2 for the given planned packages with the stream and exit code, through
// the real command, and returns its path.
func shardManifest(t *testing.T, dir string, i int, planned []string, stream, rc string) string {
	t.Helper()
	p := writeFile(t, dir, fmt.Sprintf("planned-%d.txt", i), strings.Join(planned, "\n")+"\n")
	r := runIn(t, dir, str(stream), "manifest", "--shard", fmt.Sprintf("%d/2", i), "--exit", rc, "--planned", p)
	if r.out == "" {
		t.Fatalf("no manifest written: %+v", r)
	}
	return writeFile(t, dir, fmt.Sprintf("manifest-%d.txt", i), r.out)
}

func passStream(pkgs []string) string {
	var s string
	for _, p := range pkgs {
		s += ev("start", p, "") + ev("pass", p, "")
	}
	return s
}

func TestManifestsAreReadByShardJoin(t *testing.T) {
	all := []string{"m/a", "m/b", "m/c", "m/d", "m/e"}
	dir := t.TempDir()
	expected := writeFile(t, dir, "expected.txt", strings.Join(all, "\n")+"\n")
	// the real plan command splits the list, so the two halves are what a CI matrix would run
	var share [3][]string
	for i := 1; i <= 2; i++ {
		r := runIn(t, dir, str(strings.Join(all, "\n")), "plan", "--shard", fmt.Sprintf("%d/2", i))
		share[i] = lines(r.out)
	}
	m1 := shardManifest(t, dir, 1, share[1], passStream(share[1]), "0")
	m2 := shardManifest(t, dir, 2, share[2], passStream(share[2]), "0")

	if out, rc := join(t, expected, nil, m1, m2); rc != 0 || !strings.Contains(out, "Shard join: OK — 2 shard(s), 5 suite(s)") || strings.Contains(out, "JOIN:") {
		t.Errorf("complete green set: rc %d\n%s", rc, out)
	}

	// one package missing from the second shard's plan: the join names it
	short := share[2][:len(share[2])-1]
	gone := share[2][len(share[2])-1]
	m2short := shardManifest(t, dir, 2, short, passStream(short), "0")
	if out, rc := join(t, expected, nil, m1, m2short); rc != 1 || !strings.Contains(out, "JOIN: MISSING SUITE: "+gone+" ran in no shard") {
		t.Errorf("one package missing: rc %d\n%s", rc, out)
	}

	// a failing package: exit=1 and a FAIL row
	failStream := passStream(share[2][1:]) + ev("fail", share[2][0], "")
	m2fail := shardManifest(t, dir, 2, share[2], failStream, "1")
	if out, rc := join(t, expected, nil, m1, m2fail); rc != 1 || !strings.Contains(out, "JOIN: FAILED SUITE: "+share[2][0]) || !strings.Contains(out, "JOIN: SHARD FAILED: shard 2/2 exited 1") {
		t.Errorf("failed shard: rc %d\n%s", rc, out)
	}

	// an empty stream with --exit 0: the forced exit=1 is what the join sees
	m2empty := shardManifest(t, dir, 2, share[2], "", "0")
	if out, rc := join(t, expected, nil, m1, m2empty); rc != 1 || !strings.Contains(out, "JOIN: SHARD FAILED: shard 2/2 exited 1") {
		t.Errorf("empty stream: rc %d\n%s", rc, out)
	}

	// a finding with --exit 0 (a package in the stream that was not planned): the manifest alone makes the join fail,
	// even if the workflow step swallowed the command's own exit code
	extraStream := passStream(share[2]) + ev("pass", "m/unplanned", "")
	m2extra := shardManifest(t, dir, 2, share[2], extraStream, "0")
	if out, rc := join(t, expected, nil, m1, m2extra); rc != 1 || !strings.Contains(out, "JOIN: SHARD FAILED: shard 2/2 exited 1") {
		t.Errorf("unplanned package: rc %d\n%s", rc, out)
	}

	// a package whose tests ALL skipped is a package-level pass in the stream, but a SKIP row: accepted by the real join,
	// refused under --strict-skip
	allSkipped := passStream(share[2][1:]) + ev("start", share[2][0], "") + ev("skip", share[2][0], "TestA") + ev("pass", share[2][0], "")
	m2allskip := shardManifest(t, dir, 2, share[2], allSkipped, "0")
	if out, rc := join(t, expected, nil, m1, m2allskip); rc != 0 {
		t.Errorf("all-skipped package: rc %d\n%s", rc, out)
	}
	if out, rc := join(t, expected, []string{"--strict-skip"}, m1, m2allskip); rc != 1 || !strings.Contains(out, "JOIN: SKIPPED SUITE: "+share[2][0]+" (--strict-skip)") {
		t.Errorf("all-skipped package with --strict-skip: rc %d\n%s", rc, out)
	}

	// a package-level skip is a SKIP row: reported, and a finding only under --strict-skip
	skipStream := passStream(share[2][1:]) + ev("skip", share[2][0], "")
	m2skip := shardManifest(t, dir, 2, share[2], skipStream, "0")
	if out, rc := join(t, expected, nil, m1, m2skip); rc != 0 {
		t.Errorf("skip without --strict-skip: rc %d\n%s", rc, out)
	}
	if out, rc := join(t, expected, []string{"--strict-skip"}, m1, m2skip); rc != 1 || !strings.Contains(out, "JOIN: SKIPPED SUITE: "+share[2][0]) {
		t.Errorf("skip with --strict-skip: rc %d\n%s", rc, out)
	}
}
