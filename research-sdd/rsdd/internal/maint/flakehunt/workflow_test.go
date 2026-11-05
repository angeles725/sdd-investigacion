package flakehunt

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The CI contract (Risk item 5): .github/workflows/flake-hunt.yml runs the hunt for every shard. These tests pin each
// invocation shape the workflow (and the documented cron line) uses: the flags, the exit codes, the out-dir layout it
// uploads and the issue title format `flake: <suite> `. The workflow file itself is read-only.

const evidenceURL = "https://github.com/angeles725/sdd-investigacion/actions/runs/42"

// shardRun is the `Flake hunt (shard N)` step: a suites file chosen by the previous step, --prove-teeth, the inputs,
// --out <runner temp>/flake-hunt/<shard>, the run URL and --file-issues=apply, with GH_TOKEN set for gh only.
func shardRun(w *world, runs, load string, suites ...string) ran {
	w.t.Helper()
	w.file("in/suites.txt", strings.Join(suites, "\n")+"\n")
	w.env = append(w.env, "GH_TOKEN=ci-token")
	return w.goRun("--runs", runs, "--prove-teeth", "--load", load, "--suites", w.root+"/in/suites.txt",
		"--out", w.root+"/flake-hunt/1", "--evidence-url", evidenceURL, "--file-issues=apply")
}

func inRepo(w *world) { w.cwd = w.repo } // the workflow runs from the checkout; no --repo is passed

func TestWorkflowShardShapeCleanHuntExitsZeroAndLeavesTheUploadedLayout(t *testing.T) {
	w := newWorld(t)
	w.standard()
	w.stubGH()
	inRepo(w)
	r := shardRun(w, "3", "2", "s/stable.test.sh", "s/skip.test.sh")
	if r.rc != 0 {
		t.Fatalf("rc %d err=%q out=%q", r.rc, r.err, r.out)
	}
	for _, p := range []string{"results.tsv", "logs/1-1.log", "logs/3-2.log"} {
		if _, err := os.Stat(w.root + "/flake-hunt/1/" + p); err != nil {
			t.Errorf("the uploaded out dir lacks %s", p)
		}
	}
	if b, _ := os.ReadFile(w.rec + "/gh.log"); len(b) != 0 {
		t.Errorf("a clean hunt called gh: %s", b)
	}
	if !strings.Contains(r.out, "Flake hunt: runs=3 suites=2 load=2 flaky=0 broken=0 stable=1 skipped=1\n") {
		t.Errorf("totals line: %q", r.out)
	}
}

func TestWorkflowShardShapeFlakyFilesOneIssueWithTheDedupeTitleAndEvidence(t *testing.T) {
	w := newWorld(t)
	w.standard()
	w.stubGH()
	inRepo(w)
	r := shardRun(w, "3", "0", "s/stable.test.sh", "s/flaky.test.sh", "s/broken.test.sh")
	if r.rc != 1 {
		t.Fatalf("rc %d err=%q out=%q", r.rc, r.err, r.out)
	}
	log, _ := os.ReadFile(w.rec + "/gh.log")
	for _, want := range []string{
		"issue|create|--title|flake: flaky.test.sh failed 2/3 under CPU load|--label|type:bug|--body-file|" + w.root + "/flake-hunt/1/issue-flaky.test.sh.md|",
		"issue|create|--title|flake: broken.test.sh failed 3/3 under CPU load|--label|type:bug|--body-file|" + w.root + "/flake-hunt/1/issue-broken.test.sh.md|",
	} {
		if !strings.Contains(string(log), want+"\n") {
			t.Errorf("gh log lacks %q\n%s", want, log)
		}
	}
	body, _ := os.ReadFile(w.root + "/flake-hunt/1/issue-flaky.test.sh.md")
	if !strings.HasSuffix(string(body), "evidence: "+evidenceURL+"\n") {
		t.Errorf("issue body lacks the evidence line:\n%s", body)
	}
	toks, _ := os.ReadFile(w.rec + "/gh.tok")
	if strings.Count(string(toks), "ci-token") != 4 { // 2 searches + 2 creates
		t.Errorf("gh must receive GH_TOKEN on every call: %q", toks)
	}
}

func TestWorkflowShardShapeCommentsOnTheOpenIssueInsteadOfDuplicating(t *testing.T) {
	w := newWorld(t)
	w.standard()
	w.stubGH()
	inRepo(w)
	w.file("rec/gh-existing", "101\tflake: flaky.test.sh failed 1/3 under CPU load\n")
	r := shardRun(w, "3", "0", "s/flaky.test.sh")
	log, _ := os.ReadFile(w.rec + "/gh.log")
	if r.rc != 1 || !strings.Contains(string(log), "issue|comment|101|--body-file|") || strings.Contains(string(log), "issue|create|") {
		t.Errorf("rc %d, gh log:\n%s", r.rc, log)
	}
}

func TestWorkflowShardShapeNeverShowsTheTokenToASuite(t *testing.T) {
	w := newWorld(t)
	w.stubGH()
	inRepo(w)
	w.suite("tok.test.sh", `echo "gh=${GH_TOKEN-unset} gt=${GITHUB_TOKEN-unset}" >>`+w.rec+`/suite.tok; echo '== 1 passed · 0 failed =='`)
	shardRun(w, "2", "0", "s/tok.test.sh")
	b, _ := os.ReadFile(w.rec + "/suite.tok")
	if strings.TrimSpace(string(b)) != "gh=unset gt=unset\ngh=unset gt=unset" {
		t.Errorf("a suite saw a CI token: %q", b)
	}
}

func TestWorkflowShardShapeDegradedExitsTwoAndFilesNothing(t *testing.T) {
	w := newWorld(t)
	w.stubGH()
	inRepo(w)
	r := shardRun(w, "3", "0", "s/missing.test.sh")
	if r.rc != 2 || !strings.Contains(r.err, "degraded: kit-flake-hunt: suite not found: s/missing.test.sh") {
		t.Errorf("rc %d err=%q", r.rc, r.err)
	}
}

func TestWorkflowShardShapeWithEveryDispatchInput(t *testing.T) {
	for _, runs := range []string{"1", "2", "4"} {
		for _, load := range []string{"0", "1"} {
			w := newWorld(t)
			w.standard()
			w.stubGH()
			inRepo(w)
			r := shardRun(w, runs, load, "s/stable.test.sh")
			if r.rc != 0 || !strings.Contains(r.out, "runs="+runs+" suites=1 load="+load+" ") {
				t.Errorf("runs=%s load=%s: rc %d out=%q err=%q", runs, load, r.rc, r.out, r.err)
			}
		}
	}
}

// TestLocalCronShape is the documented nightly line: `--runs 5 --prove-teeth --file-issues` (dry, default load, run
// from the checkout). It prints the command it would run and files nothing. The test adds --load 1 to stay cheap.
func TestLocalCronShape(t *testing.T) {
	w := newWorld(t)
	w.standard()
	w.stubGH()
	inRepo(w)
	r := w.goRun("--runs", "5", "--prove-teeth", "--load", "1", "--file-issues", "--suite", "s/flaky.test.sh")
	if r.rc != 1 || !strings.Contains(r.out, "would run: gh issue create --title flake:\\ flaky.test.sh\\ failed\\ 3/5\\ under\\ CPU\\ load --label type:bug --body-file ") {
		t.Errorf("rc %d out=%q err=%q", r.rc, r.out, r.err)
	}
	if b, _ := os.ReadFile(w.rec + "/gh.log"); strings.Contains(string(b), "issue|create") {
		t.Errorf("dry mode created an issue: %s", b)
	}
}

// TestWorkflowFlagsAreAllAccepted reads the workflow itself: every flag it passes to kit-flake-hunt.sh must parse.
func TestWorkflowFlagsAreAllAccepted(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(kitroot.Dir(t), "..", ".github", "workflows", "flake-hunt.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(b)
	i := strings.Index(text, "bash research-sdd/toolbelt/maint/kit-flake-hunt.sh")
	if i < 0 {
		t.Fatal("the workflow no longer calls kit-flake-hunt.sh: update this pin on purpose")
	}
	step := text[i:]
	if j := strings.Index(step, "\n\n"); j >= 0 {
		step = step[:j]
	}
	flags := regexp.MustCompile(`--[a-z-]+(=[a-z]+)?`).FindAllString(step, -1)
	if len(flags) < 6 {
		t.Fatalf("found only %v in the workflow step %q", flags, step)
	}
	for _, f := range flags {
		args := []string{f}
		if !strings.Contains(f, "=") && f != "--prove-teeth" {
			args = append(args, "https://example.invalid/x") // a value every valued flag can take at the parser
		}
		if _, fail := parse(args); fail != nil && strings.Contains(fail.msg, "unknown argument") {
			t.Errorf("the workflow passes %s, which the command no longer knows", f)
		}
	}
}
