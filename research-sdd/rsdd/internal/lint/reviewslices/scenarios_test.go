package reviewslices

import (
	"fmt"
	"strings"
	"testing"
)

// A scenario is one state of the script's contract: the repository it builds, the arguments, the directory the
// process runs in and an optional git wrapper (a failure or a corrupted answer injected into one git call). The
// differential test (diff_test.go) runs the frozen script and the Go command on the SAME repository and demands the
// same stdout, stderr and exit code byte for byte; the golden replay (golden_test.go) keeps the recorded answers for
// the runs that have no bash oracle. Placeholders in args, cwd and env: {R} the repository, {ROOT} the temp root
// (<ROOT>/plain is a directory outside any repository), {CNT} a counter file private to each side of the run.
type scenario struct {
	name    string
	build   func(r *repo)
	args    []string
	cwd     string   // "" = the repository
	env     []string // appended to the run environment
	shim    string   // case body of a git wrapper, "" = the real git
	target  int      // 1-based commit of base..HEAD whose full sha the wrapper sees as $TARGET, the next one's as $NEXT (the walk measures concurrently, so a wrapper never counts calls)
	gitOnly bool     // PATH holds the real git and nothing else (no awk, no sed)
	light   bool     // the run ends before git is asked anything: <root>/r is a plain directory, not a repository
	diverge *divergence
}

// divergence is a deliberate difference from the legacy script: what the Go command must print instead.
type divergence struct {
	out, err string
	rc       int
	reason   string
}

func nothing(*repo) {}

// world is the scenario's temp root.
func (sc scenario) world(t *testing.T) *repo {
	if sc.light {
		return newRoot(t)
	}
	return newRepo(t)
}

// ---- repositories ------------------------------------------------------------------------------------------

func commitsOf(files ...string) func(*repo) {
	return func(r *repo) {
		for i := 0; i < len(files); i += 2 {
			var n int
			fmt.Sscanf(files[i+1], "%d", &n)
			r.add(files[i], n)
		}
	}
}

func bOne(r *repo)       { commitsOf("a", "5")(r) }
func bTwo(r *repo)       { commitsOf("a", "5", "b", "5")(r) }
func bGreedy(r *repo)    { commitsOf("f1", "150", "f2", "150", "f3", "150", "f4", "150")(r) }
func bEdge(r *repo)      { commitsOf("a", "200", "b", "200")(r) }
func bUnspMid(r *repo)   { commitsOf("a", "50", "big", "500", "c", "50")(r) }
func bUnspFirst(r *repo) { commitsOf("big", "500", "a", "50")(r) }
func bUnspLast(r *repo)  { commitsOf("a", "50", "big", "500")(r) }
func bUnspOne(r *repo)   { commitsOf("big", "500")(r) }
func bParents(r *repo)   { commitsOf("p1", "250", "p2", "250", "p3", "250")(r) }

func bDel(r *repo) {
	r.add("a", 100)
	r.write("a", lines("a", 30))
	r.commit("shrink")
}

func bMod(r *repo) {
	r.add("a", 10)
	r.write("a", lines("zz", 10))
	r.commit("rewrite")
}

func blob() string { return strings.Repeat("\x01", 4096) + "x\x00y\n" }

func bBin(r *repo) {
	r.add("a", 40)
	r.write("blob.bin", blob())
	r.commit("binary")
}

func bBinOnly(r *repo) {
	r.write("blob.bin", blob())
	r.write("other.bin", blob()+"z")
	r.commit("two binaries only")
}

func bBinTwice(r *repo) {
	bBin(r)
	r.write("blob2.bin", blob()+"q")
	r.add("c", 5)
	r.commit("second binary")
}

func bMerge(r *repo) {
	r.add("m1", 60)
	r.git("checkout", "-q", "-b", "side", "base")
	r.add("s1", 30)
	r.git("checkout", "-q", "main")
	r.git("merge", "-q", "--no-ff", "-m", "merge", "side")
}

func bDiverged(r *repo) {
	r.add("a", 20)
	r.git("checkout", "-q", "-b", "other", "base")
	r.add("o", 33)
}

func bOrphan(r *repo) {
	r.git("checkout", "-q", "--orphan", "unrelated")
	r.git("rm", "-rfq", ".")
	r.write("r.txt", "r\n")
	r.commit("root")
}

func bRoot(r *repo) {
	r.add("a", 10)
	bOrphan(r)
	r.git("merge", "-q", "--allow-unrelated-histories", "-m", "merge", "main")
}

func bUnrelated(r *repo) {
	r.add("a", 10)
	bOrphan(r)
	r.add("b", 4)
}

func bOrigin(r *repo) {
	r.git("update-ref", "refs/remotes/origin/main", r.git("rev-parse", "base"))
	r.add("a", 120)
}

func bEmptyCommit(r *repo) {
	r.add("a", 10)
	r.commit("empty")
	r.add("b", 3)
}

func bRename(r *repo) {
	r.add("a", 30)
	r.git("mv", "a", "b")
	r.commit("rename")
	r.write("b", lines("a", 30)+"extra\n")
	r.git("mv", "b", "c")
	r.commit("rename and edit")
}

func bMode(r *repo) {
	r.add("run.sh", 5)
	r.git("update-index", "--chmod=+x", "run.sh")
	r.commit("chmod")
}

func bOddPath(r *repo) {
	r.write("sp ace/ü.txt", lines("u", 7))
	r.write("tab\there.txt", lines("t", 3))
	r.commit("odd paths")
}

func bAnnotated(r *repo) {
	r.add("a", 12)
	r.git("tag", "-a", "-m", "annotated", "v1", "base")
}

func bBare(r *repo) {
	r.add("a", 12)
	r.git("clone", "-q", "--bare", ".", r.root+"/bare.git")
}

func bSub(r *repo) {
	r.add("sub/a", 8)
}

func bLink(r *repo) {
	r.add("a", 8)
	_ = osSymlink(r, r.dir, r.root+"/link")
}

func bMixed(r *repo) {
	commitsOf("c1", "10", "c2", "390", "c3", "5", "c4", "400", "c5", "401", "c6", "1", "c7", "399", "c8", "2", "c9", "2", "c10", "398", "c11", "1")(r)
}

// ---- argument vectors -------------------------------------------------------------------------------------

func args(extra ...string) []string {
	return append([]string{"--cwd", "{R}", "--base-ref", "base"}, extra...)
}

func max(n string) []string { return args("--max-lines", n) }

// ---- the numstat answers a git wrapper can give (every commit gets the same one) -----------------------

type numstat struct{ name, text string }

func numstats() []numstat {
	return []numstat{
		{"plain", "3\\t4\\tfile\\n"},
		{"binary-then-text", "-\\t-\\tbin\\n3\\t4\\tf\\n"},
		{"blank-line-between", "3\\t4\\tf\\n\\n5\\t6\\tg\\n"},
		{"two-fields", "3\\t4\\n"},
		{"dash-and-number", "-\\t3\\tx\\n"},
		{"number-and-dash", "3\\t-\\tx\\n"},
		{"leading-space", " 3\\t4\\tx\\n"},
		{"extra-field", "3\\t4\\tx\\textra\\n"},
		{"only-tabs", "\\t\\t\\n"},
		{"leading-zeros", "007\\t3\\tx\\n"},
		{"crlf-tail", "3\\t4\\tx\\r\\n"},
		{"cr-in-count", "3\\r\\t4\\tx\\n"},
		{"two-dashes-two-fields", "-\\t-\\n"},
		{"one-word", "x\\n"},
		{"nothing", ""},
		{"blank-lines-only", "\\n\\n"},
		{"two-binaries", "1\\t2\\tf\\n-\\t-\\tb1\\n-\\t-\\tb2\\n"},
		{"binary-empty-path", "-\\t-\\t\\n"},
		{"zero-counts", "0\\t0\\tf\\n"},
		{"garbage", "garbage-row\\n"},
		{"empty-count", "5\\t\\tf\\n"},
		{"plus-sign", "+5\\t4\\tf\\n"},
		{"huge-count", "99999999999999999999\\t1\\tx\\n"},
	}
}

func numstatShim(text string) string {
	if text == "" {
		return `*--numstat*) exit 0;;`
	}
	return `*--numstat*) printf '` + text + `'; exit 0;;`
}

// ---- the scenarios ----------------------------------------------------------------------------------------

func scenarios() []scenario {
	var out []scenario
	add := func(name string, build func(*repo), a []string) *scenario {
		out = append(out, scenario{name: name, build: build, args: a})
		return &out[len(out)-1]
	}
	plain := func(name string, a ...string) { add(name, nothing, a) }

	// the plan itself
	add("empty-range", nothing, args())
	add("empty-range-head-as-base", bGreedy, []string{"--cwd", "{R}", "--base-ref", "HEAD"})
	add("greedy-4x150", bGreedy, max("400"))
	add("greedy-default-max", bGreedy, args())
	add("boundary-equal-fits", bEdge, max("400"))
	add("boundary-one-below-splits", bEdge, max("399"))
	add("boundary-commit-equals-max", bEdge, max("200"))
	add("boundary-commit-above-max", bEdge, max("199"))
	add("unsplittable-middle", bUnspMid, max("400"))
	add("unsplittable-first", bUnspFirst, max("400"))
	add("unsplittable-last", bUnspLast, max("400"))
	add("unsplittable-alone", bUnspOne, max("400"))
	add("unsplittable-max-1", bUnspMid, max("1"))
	add("deletions-counted", bDel, max("400"))
	add("rewrite-counts-both-sides", bMod, max("400"))
	add("binary-typed", bBin, max("400"))
	add("binary-absent-no-field", func(r *repo) { r.add("a", 40) }, max("400"))
	add("binary-only-commit", bBinOnly, max("400"))
	add("binary-summed-across-slices", bBinTwice, max("400"))
	add("binary-summed-small-budget", bBinTwice, max("10"))
	add("parents-are-the-real-bases", bParents, max("400"))
	add("merge-first-parent", bMerge, max("400"))
	add("diverged-uses-merge-base", bDiverged, []string{"--cwd", "{R}", "--base-ref", "main"})
	add("root-commit-base-root", bRoot, []string{"--cwd", "{R}", "--base-ref", "main"})
	add("root-commit-small-budget", bRoot, []string{"--cwd", "{R}", "--base-ref", "main", "--max-lines", "5"})
	add("default-base-origin-main", bOrigin, []string{"--cwd", "{R}"})
	add("empty-commit-zero-lines", bEmptyCommit, max("400"))
	add("empty-commit-zero-lines-tiny-budget", bEmptyCommit, max("3"))
	add("renames", bRename, max("400"))
	add("mode-change-only", bMode, max("400"))
	add("odd-path-names", bOddPath, max("400"))
	add("annotated-tag-base", bAnnotated, []string{"--cwd", "{R}", "--base-ref", "v1"})
	add("bare-repository", bBare, []string{"--cwd", "{ROOT}/bare.git", "--base-ref", "base"})
	add("mixed-400", bMixed, max("400"))
	add("mixed-399", bMixed, max("399"))
	add("mixed-401", bMixed, max("401"))
	add("mixed-10", bMixed, max("10"))
	add("mixed-1", bMixed, max("1"))
	add("mixed-9223372036854775807", bMixed, max("9223372036854775807"))
	add("max-1", bParents, max("1"))
	add("max-large", bParents, max("999999"))
	add("repeated-max-last-wins", bParents, args("--max-lines", "100", "--max-lines", "400"))
	add("repeated-base-last-wins", bParents, []string{"--cwd", "{R}", "--base-ref", "nope", "--base-ref", "base"})
	add("repeated-cwd-last-wins", bParents, []string{"--cwd", "{ROOT}/plain", "--cwd", "{R}", "--base-ref", "base"})
	add("options-in-other-order", bParents, []string{"--max-lines", "300", "--base-ref", "base", "--cwd", "{R}"})
	add("report-only-no-refs", bParents, max("400"))

	// the working directory
	sub := add("cwd-default-dot-in-subdirectory", bSub, []string{"--base-ref", "base"})
	sub.cwd = "{R}/sub"
	rel := add("cwd-relative-subdirectory", bSub, []string{"--cwd", "sub", "--base-ref", "base"})
	rel.cwd = "{R}"
	up := add("cwd-relative-dotdot", bSub, []string{"--cwd", "..", "--base-ref", "base"})
	up.cwd = "{R}/sub"
	add("cwd-through-a-symlink", bLink, []string{"--cwd", "{ROOT}/link", "--base-ref", "base"})
	add("cwd-is-a-file", nothing, []string{"--cwd", "{R}/seed.txt", "--base-ref", "base"})
	add("cwd-absent", nothing, []string{"--cwd", "{ROOT}/does-not-exist", "--base-ref", "base"})
	add("cwd-empty-string", nothing, []string{"--cwd", "", "--base-ref", "base"})
	add("cwd-not-a-repository", nothing, []string{"--cwd", "{ROOT}/plain", "--base-ref", "base"})
	add("cwd-not-a-repository-bad-ref-after", nothing, []string{"--cwd", "{ROOT}/plain", "--base-ref", "nope"})
	spaced := add("cwd-with-spaces", func(r *repo) {
		r.add("a", 3)
		r.git("clone", "-q", ".", r.root+"/with space/r")
	}, []string{"--cwd", "{ROOT}/with space/r", "--base-ref", "base"})
	spaced.cwd = "{ROOT}/plain"

	// the base ref
	plain("base-ref-unknown", "--cwd", "{R}", "--base-ref", "no-such-ref")
	plain("base-ref-empty-string", "--cwd", "{R}", "--base-ref", "")
	plain("base-ref-looks-like-option", "--cwd", "{R}", "--base-ref", "--foo")
	plain("base-ref-default-absent", "--cwd", "{R}")
	plain("base-ref-a-tree", "--cwd", "{R}", "--base-ref", "base^{tree}")
	plain("base-ref-with-quote", "--cwd", "{R}", "--base-ref", "it's")
	add("base-ref-unrelated-history", bUnrelated, []string{"--cwd", "{R}", "--base-ref", "main"})
	add("base-ref-detached-head", func(r *repo) { r.add("a", 5); r.add("b", 6); r.git("checkout", "-q", "--detach", "HEAD~1") }, args())

	// usage and --max-lines
	plain("usage-unknown-option", "--cwd", "{R}", "--base-ref", "base", "--bogus")
	plain("usage-no-arguments-needs-base", "--bogus")
	plain("usage-positional", "x")
	plain("usage-help", "--help")
	plain("usage-short-help", "-h")
	plain("usage-equals-form", "--cwd={R}")
	plain("usage-max-equals-form", "--max-lines=5")
	plain("usage-cwd-without-value", "--cwd")
	plain("usage-base-ref-without-value", "--base-ref")
	plain("usage-max-lines-without-value", "--max-lines")
	plain("usage-without-value-after-others", "--cwd", "{R}", "--base-ref", "base", "--max-lines")
	plain("usage-before-max-check", "--max-lines", "abc", "--bogus")
	plain("max-checked-before-cwd", "--max-lines", "abc", "--cwd", "{ROOT}/does-not-exist")
	plain("max-checked-before-cwd-reversed", "--cwd", "{ROOT}/does-not-exist", "--max-lines", "abc")
	for i, m := range []string{"0", "abc", "-5", "5x", "05", "00", "007", "1.5", " 5", "5 ", "+5", "0x10", "", "5\n", "٣", "1e3", "5;echo"} {
		add(fmt.Sprintf("max-invalid-%02d", i), nothing, max(m))
	}
	for _, m := range []string{"9223372036854775808", "99999999999999999999"} {
		sc := add("max-beyond-int64-"+m, bParents, max(m))
		sc.diverge = &divergence{
			out:    "plan-review-slices: --max-lines must be a positive integer no larger than 9223372036854775807 (got '" + m + "')\n",
			rc:     2,
			reason: "the script's [ -gt ] fails with 'integer expression expected' above int64, treats it as false, never joins two commits and prints max=9223372036854775807 with exit 0: a wrong plan, so the Go command refuses it",
		}
	}

	// the environment
	env := add("git-environment-is-ignored", bParents, max("400"))
	env.env = []string{"GIT_DIR={ROOT}/does-not-exist", "GIT_WORK_TREE={ROOT}/plain", "GIT_INDEX_FILE={ROOT}/nope", "GIT_COMMON_DIR={ROOT}/nope"}
	miss := add("git-missing", nothing, max("400"))
	miss.env = []string{"PATH={ROOT}/plain"}
	missUsage := add("git-missing-before-usage", nothing, []string{"--bogus"})
	missUsage.env = []string{"PATH={ROOT}/plain"}
	missMax := add("git-missing-before-max-check", nothing, max("abc"))
	missMax.env = []string{"PATH={ROOT}/plain"}

	// awk is no longer a dependency: the script, with no awk on PATH, printed a plan of lines=0 and exited 0
	noAwk := add("awk-is-not-needed", bOne, max("400"))
	noAwk.gitOnly = true
	noAwk.diverge = &divergence{
		out:    "SLICE 1 {C1}..{C1} commits=1 lines=5 base={B}\nPLAN: 1 slice(s) commits=1 lines=5 max=400\n",
		rc:     0,
		reason: "with no awk on PATH the script's measurement failed ('awk: command not found', 'integer expression expected') and it printed lines=0 for a 5-line commit with exit 0 - a silent zero; the Go command reads numstat itself",
	}

	// git answers the script cannot trust
	shimmed := func(name string, build func(*repo), a []string, body string) {
		add(name, build, a).shim = body
	}
	shimmed("git-numstat-garbage", func(r *repo) { r.add("a", 20) }, max("400"), numstatShim("garbage-row\\n"))
	for _, n := range numstats() {
		sc := add("numstat-"+n.name, bTwo, max("400"))
		sc.shim = numstatShim(n.text)
		if n.name == "huge-count" {
			sc.diverge = &divergence{
				out:    "plan-review-slices: malformed numstat row for {C1}\n",
				rc:     2,
				reason: "a count above int64 is a float in the awk and an 'integer expression expected' in the later [ -gt ]; git never prints one, the Go command calls the row malformed",
			}
		}
	}
	shimmed("git-parents-lookup-fails", bParents, max("400"), `*"rev-list --parents"*) exit 1;;`)
	shimmed("git-parents-lookup-empty-reads-as-root", bParents, max("400"), `*"rev-list --parents"*) exit 0;;`)
	shimmed("git-short-fails-first-call", bParents, max("400"), `*"rev-parse --short=12"*) exit 1;;`)
	shimmed("git-short-fails-on-the-parent", bOne, max("400"),
		`*"rev-parse --short=12"*) n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$CNT"; [ "$n" -ge 2 ] && exit 1;;`)
	shimmed("git-empty-tree-fails-on-root", bRoot, []string{"--cwd", "{R}", "--base-ref", "main"}, `*"hash-object"*) exit 1;;`)
	shimmed("git-empty-tree-empty-answer", bRoot, []string{"--cwd", "{R}", "--base-ref", "main"}, `*"hash-object"*) exit 0;;`)
	shimmed("git-diff-fails", bParents, max("400"), `*"diff --numstat"*) exit 1;;`)
	// a failure after a slice was already printed leaves that slice on stdout, as the script's stdout was; the commits
	// are measured concurrently, so the wrapper picks the commit by its sha ($TARGET), never by counting calls
	atCommit := func(name string, build func(*repo), n int, a []string, body string) {
		sc := add(name, build, a)
		sc.shim, sc.target = body, n
	}
	atCommit("git-diff-fails-on-the-third-commit", bParents, 3, max("400"), `*"diff --numstat"*" $TARGET") exit 1;;`)
	atCommit("git-numstat-garbage-on-the-third-commit", bParents, 3, max("400"), `*"diff --numstat"*" $TARGET") echo garbage-row; exit 0;;`)
	atCommit("git-parents-fail-on-the-third-commit", bParents, 3, max("400"), `*"rev-list --parents -n 1 $TARGET") sleep 0.3; exit 1;;`)
	atCommit("git-numstat-garbage-on-the-last-of-many", bMixed, 11, max("400"), `*"diff --numstat"*" $TARGET") echo garbage-row; exit 0;;`)
	// two commits fail: the FIRST in commit order is the one reported, however the concurrent runs finish
	atCommit("git-diff-fails-on-the-second-and-third-commit", bParents, 2, max("400"), `*"diff --numstat"*" $TARGET"|*"diff --numstat"*" $NEXT") exit 1;;`)
	atCommit("git-two-kinds-of-failure-the-earlier-commit-wins", bParents, 2, max("400"), `*"diff --numstat"*" $NEXT") exit 1;;
*"rev-list --parents -n 1 $TARGET") sleep 0.3; exit 1;;`)
	shimmed("git-rev-list-fails", bParents, max("400"), `*"--first-parent"*) exit 1;;`)
	shimmed("git-merge-base-fails", bParents, max("400"), `*"merge-base"*) exit 1;;`)
	shimmed("git-merge-base-empty-answer", bParents, max("400"), `*"merge-base"*) exit 0;;`)
	shimmed("git-verify-fails", bParents, max("400"), `*"rev-parse --verify"*) exit 1;;`)
	shimmed("git-git-dir-fails", bParents, max("400"), `*"--git-dir"*) exit 1;;`)
	shimmed("git-stderr-noise-is-never-printed", bParents, max("400"), `*) echo "noise from git" >&2;;`)
	shimmed("git-stderr-noise-on-failure", bParents, max("400"), `*"--git-dir"*) echo "fatal: noise" >&2; exit 128;;`)
	for i := range out {
		for _, p := range lightPrefixes {
			if strings.HasPrefix(out[i].name, p) {
				out[i].light = true
			}
		}
	}
	return out
}

// lightPrefixes are the scenarios that end before git is asked a thing (checked by TestLightScenariosNeverRunGit).
var lightPrefixes = []string{"usage-", "max-invalid-", "max-checked-before-cwd", "git-missing", "cwd-absent", "cwd-empty-string", "cwd-is-a-file"}

func osSymlink(r *repo, target, link string) error {
	r.t.Helper()
	return symlink(target, link)
}
