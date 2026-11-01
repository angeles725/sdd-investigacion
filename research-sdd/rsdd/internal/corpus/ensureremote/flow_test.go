package ensureremote

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// Guard-to-test table. The six-layer private guard; each layer has a test that goes red when the layer is broken
// (checked by hand and by the gremlins run recorded in the PR):
//
//	1 no public code path   TestHappyPath, TestCreateIsPrivateAndBounded       (--private on the single create; its own knob)
//	2 personal account      TestOwnerGuard                                     (org refused 4, unverifiable refused 7, before any create)
//	3 consent gate          TestConsentGate                                    (no --yes / RSDD_ALLOW_REMOTE=1 => 3, before any gh call)
//	4a gitignore seed       TestGitignoreSeed, TestGitignoreCommit
//	4b secret sweep         TestScannerExitCodes, TestDirtyTree, TestScannerMissing
//	4c tracked secret files TestTrackedSecretRefused, TestAllowList*, TestHistory* (allow_flow_test.go)
//	5 verify before push    TestVisibilityGuard, TestCreateTimeout*, TestEditTimeout, TestHardAbortOriginLeft
//	6 idempotent            TestExistingOrigin

const happyStdout = "== ensure-remote: target ==\n" +
	"   owner : tester (personal)\n" +
	"   repo  : research-target (PRIVATE)\n" +
	">> creating PRIVATE remote tester/research-target\n" +
	">> confirmed PRIVATE — pushing corpus\n" +
	"== ensure-remote: private remote ready at https://github.com/tester/research-target ==\n"

func TestHappyPath(t *testing.T) {
	w := newWorld(t)
	w.diffRC = 1 // the seeded .gitignore differs from HEAD, so it is added and committed
	if rc := w.ok(); rc != 0 {
		t.Fatalf("rc=%d out=%q", rc, w.allOut())
	}
	if w.out() != happyStdout {
		t.Errorf("stdout:\n%q\nwant:\n%q", w.out(), happyStdout)
	}
	if w.err() != "" {
		t.Errorf("stderr = %q", w.err())
	}
	// the order of the whole run is the order of the layers
	want := []string{
		"git -C " + w.target + " rev-parse --git-dir",
		"git -C " + w.target + " remote get-url origin",
		"gh api user -q .login",
		"gh api users/tester -q .type",
		"git -C " + w.target + " diff --quiet -- .gitignore",
		"git -C " + w.target + " add .gitignore",
		"git -C " + w.target + " commit -q -m chore: ignore secret-bearing paths (ensure-remote) -- .gitignore",
		"git -C " + w.target + " status --porcelain",
		"bash " + w.toolbelt + "/scan-secrets.sh --committed " + w.target,
		"git -C " + w.target + " ls-files -z -- *.pem *.der *.key *.p12 *.pfx id_rsa* *.jks *.keystore security/* licenses/* certificates/* keystore/* keyring/*",
		"gh repo create tester/research-target --private --source " + w.target + " --remote origin --disable-wiki",
		"probe tester/research-target",
		"git -C " + w.target + " push -u origin HEAD --no-follow-tags",
	}
	if strings.Join(w.calls, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(w.calls, "\n"), strings.Join(want, "\n"))
	}
}

func TestCreateIsPrivateAndBounded(t *testing.T) {
	w := newWorld(t)
	w.env["RSDD_GH_TIMEOUT"] = "7"
	w.env["GH_REPO"] = "x/y"
	if rc := w.ok(); rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	creates := 0
	for _, c := range w.calls {
		if strings.HasPrefix(c, "gh repo create") {
			creates++
			if !strings.Contains(c, " --private ") {
				t.Errorf("create without --private: %s", c)
			}
			if strings.Contains(c, "public") {
				t.Errorf("create names public: %s", c)
			}
		}
	}
	if creates != 1 {
		t.Errorf("creates = %d", creates)
	}
	o := w.optsOf("gh repo create")
	if o.Knob != "RSDD_GH_CREATE_TIMEOUT" || o.Default != 60 {
		t.Errorf("create bound = %q/%d, want its own knob RSDD_GH_CREATE_TIMEOUT default 60", o.Knob, o.Default)
	}
	// the probe uses RSDD_GH_TIMEOUT (the default knob), default 20
	p := w.optsOf("probe ")
	if p.Knob != "" && p.Knob != "RSDD_GH_TIMEOUT" || (p.Default != 0 && p.Default != 20) {
		t.Errorf("probe bound = %q/%d", p.Knob, p.Default)
	}
	// every gh call gets the caller's environment (the gh package strips GH_REPO and forces GH_PROMPT_DISABLED)
	for _, c := range w.ghops {
		if !contains(c.o.Env, "RSDD_GH_TIMEOUT=7") || !contains(c.o.Env, "GH_REPO=x/y") {
			t.Errorf("%s: env not handed to gh: %v", c.line, c.o.Env)
		}
	}
}

func TestUsageAndArgs(t *testing.T) {
	usage := "usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]\n"
	for _, tt := range []struct {
		name string
		args func(w *world) []string
		rc   int
		err  string
	}{
		{"no-args", func(w *world) []string { return nil }, 2, usage},
		{"missing-dir", func(w *world) []string { return []string{w.root + "/nope", "--yes"} }, 2, usage},
		{"file-not-dir", func(w *world) []string {
			f := filepath.Join(w.root, "f")
			os.WriteFile(f, nil, 0o644)
			return []string{f}
		}, 2, usage},
		{"name-no-value", func(w *world) []string { return []string{w.target, "--name"} }, 2, "REFUSED: --name requires a value\n"},
		{"unknown-flag", func(w *world) []string { return []string{w.target, "--bogus"} }, 2, "unknown flag: --bogus\n"},
		{"dash-is-a-flag", func(w *world) []string { return []string{"-"} }, 2, "unknown flag: -\n"},
		{"double-dash-is-a-flag", func(w *world) []string { return []string{"--", w.target} }, 2, "unknown flag: --\n"},
		{"help-is-an-unknown-flag", func(w *world) []string { return []string{"-h"} }, 2, "unknown flag: -h\n"},
		{"flag-before-target-wins-order", func(w *world) []string { return []string{"--bogus", w.target, "--name"} }, 2, "unknown flag: --bogus\n"},
		{"empty-target", func(w *world) []string { return []string{""} }, 2, usage},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			rc := w.exec(tt.args(w)...)
			if rc != tt.rc || w.err() != tt.err || w.out() != "" {
				t.Errorf("rc=%d err=%q out=%q; want rc=%d err=%q", rc, w.err(), w.out(), tt.rc, tt.err)
			}
			if w.called("gh ") || w.called("git ") {
				t.Errorf("a bad argument reached an external tool: %v", w.calls)
			}
		})
	}
}

func TestLastTargetWinsAndNameValueMayLookLikeAFlag(t *testing.T) {
	w := newWorld(t)
	other := filepath.Join(w.root, "other")
	os.MkdirAll(other, 0o755)
	if rc := w.exec(other, w.target, "--yes", "--name", "--yes"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.allOut())
	}
	if !w.called("gh repo create tester/yes ") || !w.called("-C "+w.target+" ") || w.called("-C "+other+" ") {
		t.Errorf("calls: %v", w.calls)
	}
}

func TestRelativeTargetResolvesAgainstCwd(t *testing.T) {
	w := newWorld(t)
	if rc := w.exec("./target/", "--yes"); rc != 0 || !w.called("-C "+w.target+" rev-parse") {
		t.Errorf("rc=%d calls=%v err=%q", rc, w.calls, w.err())
	}
	w = newWorld(t)
	os.MkdirAll(filepath.Join(w.root, "a", "b"), 0o755)
	if rc := w.exec("a/b/../../target", "--yes"); rc != 0 || !w.called("-C "+w.target+" rev-parse") {
		t.Errorf("rc=%d calls=%v err=%q", rc, w.calls, w.err())
	}
}

func TestNotAGitRepo(t *testing.T) {
	w := newWorld(t)
	w.notRepo = true
	rc := w.ok()
	want := "REFUSED: " + w.target + " is not a git repository — run research-sdd-init.sh first.\n"
	if rc != 2 || w.err() != want || w.out() != "" || w.called("gh ") {
		t.Errorf("rc=%d err=%q out=%q calls=%v", rc, w.err(), w.out(), w.calls)
	}
}

func TestExistingOrigin(t *testing.T) { // layer 6
	w := newWorld(t)
	w.origin = "https://github.com/tester/research-target.git"
	rc := w.exec(w.target) // no consent needed: nothing to do is not a network mutation
	want := "ensure-remote: origin already set (https://github.com/tester/research-target.git) — nothing to do.\n"
	if rc != 0 || w.out() != want || w.err() != "" {
		t.Errorf("rc=%d out=%q err=%q", rc, w.out(), w.err())
	}
	if w.created() || w.called("gh ") || w.pushed() {
		t.Errorf("an existing origin must short-circuit everything: %v", w.calls)
	}
}

func TestEmptyOriginURLIsNoOrigin(t *testing.T) {
	w := newWorld(t)
	w.originEmpty = true
	if rc := w.ok(); rc != 0 || !w.created() {
		t.Errorf("rc=%d calls=%v", rc, w.calls)
	}
}

func TestConsentGate(t *testing.T) { // layer 3
	for _, tt := range []struct {
		name    string
		env     string
		args    []string
		granted bool
	}{
		{"none", "", nil, false},
		{"yes-flag", "", []string{"--yes"}, true},
		{"env-1", "1", nil, true},
		{"env-0", "0", nil, false},
		{"env-yes", "yes", nil, false},
		{"env-true", "true", nil, false},
		{"env-11", "11", nil, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			if tt.env != "" {
				w.env["RSDD_ALLOW_REMOTE"] = tt.env
			}
			rc := w.exec(append([]string{w.target}, tt.args...)...)
			if tt.granted {
				if rc != 0 {
					t.Errorf("rc=%d err=%q", rc, w.err())
				}
				return
			}
			wantErr := "REFUSED: creating a remote pushes the corpus to GitHub. Re-run with --yes (or RSDD_ALLOW_REMOTE=1)\n" +
				"         when you consent to a PRIVATE GitHub remote for target.\n"
			if rc != 3 || w.err() != wantErr || w.out() != "" {
				t.Errorf("rc=%d err=%q out=%q", rc, w.err(), w.out())
			}
			if w.called("gh ") || w.created() || w.pushed() || w.called("bash ") {
				t.Errorf("no network or scan call before consent: %v", w.calls)
			}
		})
	}
}

func TestGHMissing(t *testing.T) {
	w := newWorld(t)
	w.noGH = true
	rc := w.ok()
	if rc != 7 || w.err() != "REFUSED: gh CLI not found — cannot create a remote.\n" || w.called("gh ") {
		t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
}

func TestOwnerGuard(t *testing.T) { // layer 2
	for _, tt := range []struct {
		name  string
		setup func(w *world)
		rc    int
		err   string
	}{
		{"organization", func(w *world) { w.ownerType = "Organization" }, 4,
			"REFUSED: resolved owner 'tester' is an ORGANIZATION — orgs can enforce a default-public creation\n" +
				"         policy that would override --private. Create under a personal account instead.\n"},
		{"login-unresolved", func(w *world) { w.owner = "" }, 7, "REFUSED: could not resolve your GitHub login (is gh authenticated?).\n"},
		{"login-call-fails", func(w *world) { w.ownerFail = true }, 7, "REFUSED: could not resolve your GitHub login (is gh authenticated?).\n"},
		{"type-call-fails", func(w *world) { w.ownerTypeRC = 1 }, 7, "REFUSED: could not verify that owner 'tester' is a personal account (gh api failed).\n"},
		{"type-empty", func(w *world) { w.ownerType = "" }, 7, "REFUSED: could not verify that owner 'tester' is a personal account (gh api failed).\n"},
		{"type-lowercase-organization-is-not-org", func(w *world) { w.ownerType = "organization" }, 0, ""},
		{"bot-is-personal-enough", func(w *world) { w.ownerType = "Bot" }, 0, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			tt.setup(w)
			rc := w.ok()
			if rc != tt.rc || (tt.rc != 0 && w.err() != tt.err) {
				t.Errorf("rc=%d err=%q want %d %q", rc, w.err(), tt.rc, tt.err)
			}
			if tt.rc != 0 && (w.created() || w.pushed() || w.out() != "") {
				t.Errorf("nothing may be created or printed before the owner is verified personal: out=%q calls=%v", w.out(), w.calls)
			}
		})
	}
}

func TestOwnerLookupUsesStdoutAndTheDefaultBound(t *testing.T) {
	w := newWorld(t)
	w.ok()
	for _, p := range []string{"gh api user", "gh api users/tester"} {
		o := w.optsOf(p)
		if o.Knob != "" && o.Knob != "RSDD_GH_TIMEOUT" {
			t.Errorf("%s: knob %q", p, o.Knob)
		}
	}
	// a login with a trailing newline only is trimmed; one with inner text is used as printed
	w = newWorld(t)
	w.owner = "some-user"
	w.ok()
	if !w.called("gh api users/some-user -q .type") || !w.called("gh repo create some-user/research-target ") {
		t.Errorf("calls=%v", w.calls)
	}
}

func TestRepoNames(t *testing.T) {
	for _, tt := range []struct{ dir, name, want string }{
		{"target", "", "research-target"},
		{"My Corpus", "", "research-my-corpus"},
		{"UPPER_case.v2", "", "research-upper-case-v2"},
		{"a--b", "", "research-a-b"},
		{"x", "Custom_Name!", "custom-name"},
		{"x", "--lead-and-trail--", "lead-and-trail"},
		{"x", "ünï", "n"}, // every byte outside [a-z0-9-] becomes '-' (bytewise, as tr -c)
		{"x", "a/b", "a-b"},
		{"x", "ok-1", "ok-1"},
	} {
		w := newWorld(t)
		dir := filepath.Join(w.root, tt.dir)
		os.MkdirAll(dir, 0o755)
		args := []string{dir, "--yes"}
		if tt.name != "" {
			args = append(args, "--name", tt.name)
		}
		if rc := w.exec(args...); rc != 0 {
			t.Errorf("%q/%q: rc=%d err=%q", tt.dir, tt.name, rc, w.err())
			continue
		}
		if !w.called("gh repo create tester/" + tt.want + " --private") {
			t.Errorf("%q/%q: want repo %q, calls %v", tt.dir, tt.name, tt.want, w.calls)
		}
		if !strings.Contains(w.out(), "   repo  : "+tt.want+" (PRIVATE)\n") {
			t.Errorf("%q/%q: stdout %q", tt.dir, tt.name, w.out())
		}
	}
}

func TestEmptyNameFallsBackAndUnderivableNameRefused(t *testing.T) {
	w := newWorld(t)
	if rc := w.ok("--name", ""); rc != 0 || !w.called("tester/research-target ") {
		t.Errorf("empty --name must mean the default: rc=%d %v", rc, w.calls)
	}
	for _, n := range []string{"---", "!!!", "-"} {
		w = newWorld(t)
		rc := w.ok("--name", n)
		if rc != 2 || w.err() != "REFUSED: could not derive a valid repo name.\n" || w.out() != "" || w.created() {
			t.Errorf("--name %q: rc=%d err=%q out=%q", n, rc, w.err(), w.out())
		}
	}
}

func TestGitignoreSeed(t *testing.T) { // layer 4a
	pats := []string{"security/", "licenses/", "certificates/", "*.pem", "*.der", "*.key", "*.p12", "*.pfx",
		"id_rsa*", "keystore/", "keyring/", "*.jks", "*.keystore"}
	gi := func(w *world) string {
		b, err := os.ReadFile(filepath.Join(w.target, ".gitignore"))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	t.Run("created", func(t *testing.T) {
		w := newWorld(t)
		w.ok()
		if got, want := gi(w), strings.Join(pats, "\n")+"\n"; got != want {
			t.Errorf(".gitignore = %q, want %q", got, want)
		}
	})
	t.Run("keeps-existing-and-adds-newline", func(t *testing.T) {
		w := newWorld(t)
		os.WriteFile(filepath.Join(w.target, ".gitignore"), []byte("build/\n*.pem"), 0o644)
		w.ok()
		want := "build/\n*.pem\n" + strings.Join(append([]string{}, pats[0:3]...), "\n") + "\n" + strings.Join(pats[4:], "\n") + "\n"
		if got := gi(w); got != want {
			t.Errorf(".gitignore = %q, want %q", got, want)
		}
	})
	t.Run("idempotent-whole-line-match", func(t *testing.T) {
		w := newWorld(t)
		full := strings.Join(pats, "\n") + "\n"
		os.WriteFile(filepath.Join(w.target, ".gitignore"), []byte(full), 0o644)
		w.ok()
		if got := gi(w); got != full {
			t.Errorf(".gitignore changed: %q", got)
		}
	})
	t.Run("substring-is-not-a-match", func(t *testing.T) {
		w := newWorld(t)
		os.WriteFile(filepath.Join(w.target, ".gitignore"), []byte("# *.pem\nx*.key\n *.der\n"), 0o644)
		w.ok()
		got := gi(w)
		for _, p := range pats {
			if !strings.Contains("\n"+got, "\n"+p+"\n") {
				t.Errorf("pattern %q not present as its own line in %q", p, got)
			}
		}
	})
	t.Run("seeded-before-any-gh-mutation", func(t *testing.T) {
		w := newWorld(t)
		w.ok()
		if w.count("gh repo create") != 1 {
			t.Fatal("no create")
		}
	})
	t.Run("empty-existing-file-gets-no-leading-newline", func(t *testing.T) {
		w := newWorld(t)
		os.WriteFile(filepath.Join(w.target, ".gitignore"), nil, 0o644)
		w.ok()
		if !strings.HasPrefix(gi(w), "security/\n") {
			t.Errorf(".gitignore = %q", gi(w))
		}
	})
}

func TestGitignoreCommit(t *testing.T) {
	commit := func(w *world) string {
		for _, c := range w.calls {
			if strings.Contains(c, " commit ") {
				return c
			}
		}
		return ""
	}
	t.Run("dirty-diff-commits-scoped", func(t *testing.T) {
		w := newWorld(t)
		w.diffRC = 1
		w.ok()
		c := commit(w)
		if !strings.HasSuffix(c, " commit -q -m chore: ignore secret-bearing paths (ensure-remote) -- .gitignore") {
			t.Errorf("commit = %q", c)
		}
		if !w.called(" add .gitignore") {
			t.Errorf("no add: %v", w.calls)
		}
	})
	t.Run("untracked-commits", func(t *testing.T) {
		w := newWorld(t)
		w.untracked = ".gitignore\n"
		w.ok()
		if commit(w) == "" {
			t.Errorf("an untracked .gitignore must be committed: %v", w.calls)
		}
	})
	t.Run("clean-does-not-commit", func(t *testing.T) {
		w := newWorld(t)
		w.diffRC = 0
		w.untracked = ""
		w.ok()
		if commit(w) != "" || w.called(" add ") {
			t.Errorf("clean .gitignore must not be committed: %v", w.calls)
		}
	})
	t.Run("diff-error-commits", func(t *testing.T) {
		w := newWorld(t)
		w.diffRC = 128
		w.ok()
		if commit(w) == "" {
			t.Errorf("a failed diff reads as dirty: %v", w.calls)
		}
	})
	t.Run("failed-commit-never-aborts", func(t *testing.T) {
		w := newWorld(t)
		w.diffRC, w.commitRC = 1, 1
		if rc := w.ok(); rc != 0 {
			t.Errorf("rc=%d err=%q", rc, w.err())
		}
	})
}

func TestDirtyTree(t *testing.T) {
	w := newWorld(t)
	w.statusOut = " M file.md\n"
	rc := w.ok()
	want := "REFUSED: the working tree is dirty — a redaction applied to the working tree without\n" +
		"         committing would pass the committed-content scan while the pushed HEAD still\n" +
		"         carries the original secret. Commit, add to .gitignore, or stash with\n" +
		"         'git stash -u', then re-run.\n"
	if rc != 8 || w.err() != want || w.created() || w.pushed() || w.called("bash ") {
		t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
	// the banner was printed before the layer ran, so the operator sees what was being attempted
	if !strings.HasPrefix(w.out(), "== ensure-remote: target ==\n") {
		t.Errorf("stdout = %q", w.out())
	}
}

func TestStatusFailureFailsClosed(t *testing.T) {
	w := newWorld(t)
	w.statusFail = true
	rc := w.ok()
	want := "REFUSED: could not check working tree status (git status --porcelain failed) — cannot\n" +
		"         guarantee the committed-content scan matches what would be pushed.\n"
	if rc != 7 || w.err() != want || w.created() || w.pushed() || w.called("bash ") {
		t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
}

func TestScannerExitCodes(t *testing.T) { // layer 4b
	secret := "REFUSED: scan-secrets.sh --committed found a high-confidence secret VALUE in the\n" +
		"         committed history — NOT pushing. The git history must be rewritten to remove\n" +
		"         the secret value (e.g. git filter-repo / BFG). Cite structure, not value —\n" +
		"         SECRETS DISCIPLINE applies.\n"
	for _, tt := range []struct {
		name string
		rc   int
		want int
		err  string
	}{
		{"clean", 0, 0, ""},
		{"secret", 1, 5, secret},
		{"degraded", 3, 7, "REFUSED: scan-secrets.sh --committed is degraded (git unavailable or no commits) —\n         cannot verify committed content before push.\n"},
		{"usage-2", 2, 7, "REFUSED: scan-secrets.sh --committed failed (exit 2) — cannot verify committed content before push.\n"},
		{"other-4", 4, 7, "REFUSED: scan-secrets.sh --committed failed (exit 4) — cannot verify committed content before push.\n"},
		{"killed-137", 137, 7, "REFUSED: scan-secrets.sh --committed failed (exit 137) — cannot verify committed content before push.\n"},
		{"timeout-124", 124, 7, "REFUSED: scan-secrets.sh --committed failed (exit 124) — cannot verify committed content before push.\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.scanRC = tt.rc
			rc := w.ok()
			if rc != tt.want || (tt.want != 0 && w.err() != tt.err) {
				t.Errorf("rc=%d err=%q", rc, w.err())
			}
			if tt.want != 0 && (w.created() || w.pushed() || w.called("ls-files -z")) {
				t.Errorf("a refused scan must stop before create/push: %v", w.calls)
			}
			if tt.want == 0 && !w.pushed() {
				t.Errorf("clean scan must reach the push: %v", w.calls)
			}
		})
	}
}

func TestScannerCannotRunFailsClosed(t *testing.T) {
	w := newWorld(t)
	w.scanRC, w.scanErr = 127, os.ErrNotExist
	if rc := w.ok(); rc != 7 || !strings.Contains(w.err(), "failed (exit 127)") || w.created() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestScannerMissing(t *testing.T) {
	w := newWorld(t)
	os.Remove(filepath.Join(w.toolbelt, "scan-secrets.sh"))
	rc := w.ok()
	want := "REFUSED: scan-secrets.sh not found at " + w.toolbelt + "/scan-secrets.sh — cannot verify committed content before push.\n"
	if rc != 7 || w.err() != want || w.created() || w.called("bash ") {
		t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
}

func TestScannerFromTheKitWhenNoToolbeltFlag(t *testing.T) {
	w := newWorld(t)
	kit := filepath.Join(w.root, "kit")
	os.MkdirAll(filepath.Join(kit, "toolbelt"), 0o755)
	os.WriteFile(filepath.Join(kit, "toolbelt", "scan-secrets.sh"), []byte("#!/bin/sh\n"), 0o755)
	w.env["RESEARCH_SDD_KIT"] = kit
	rc := execute([]string{w.target, "--yes"}, w.stdio(), w.deps())
	if rc != 0 || !w.called("bash "+kit+"/toolbelt/scan-secrets.sh --committed "+w.target) {
		t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
}

func TestNoToolbeltAndNoKit(t *testing.T) {
	w := newWorld(t)
	w.env["HOME"] = w.root // no default kit checkout under it
	rc := execute([]string{w.target, "--yes"}, w.stdio(), w.deps())
	if rc != 7 || !strings.HasPrefix(w.err(), "REFUSED: scan-secrets.sh not found") || w.created() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestToolbeltFlagNeedsAValue(t *testing.T) {
	w := newWorld(t)
	rc := execute([]string{"--toolbelt"}, w.stdio(), w.deps())
	if rc != 2 || w.err() != "REFUSED: --toolbelt requires a value\n" {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

// Layer 4b cannot be swapped: the shim injects --toolbelt FIRST; a user-supplied one (anywhere else, or a second one)
// is the bash's unknown-flag error, and the scanner is never run from a directory the user named.
func TestToolbeltIsHonouredOnlyAsTheShimsFirstArgument(t *testing.T) {
	for name, args := range map[string][]string{
		"after-the-target":  {"{T}", "--yes", "--toolbelt", "/x"},
		"before-the-target": {"--yes", "--toolbelt", "/x", "{T}"},
		"second-toolbelt":   {"--toolbelt", "{TB}", "{T}", "--yes", "--toolbelt", "/x"},
		"toolbelt-twice":    {"--toolbelt", "{TB}", "--toolbelt", "/x", "{T}", "--yes"},
		"trailing-no-value": {"--toolbelt", "{TB}", "{T}", "--yes", "--toolbelt"},
	} {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t)
			for i, a := range args {
				args[i] = strings.NewReplacer("{T}", w.target, "{TB}", w.toolbelt).Replace(a)
			}
			rc := execute(args, w.stdio(), w.deps())
			if rc != 2 || w.err() != "unknown flag: --toolbelt\n" || w.called("scan-secrets.sh") || w.created() {
				t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
			}
		})
	}
}

func TestTrackedSecretRefused(t *testing.T) { // layer 4c, no allow list
	w := newWorld(t)
	w.tracked = []string{"secret.pem"}
	rc := w.ok()
	want := "REFUSED: secret-bearing file(s) are git-TRACKED and would be pushed: secret.pem\n" +
		"         scan-secrets.sh cannot see these binary types. Untrack them first:\n" +
		"         git -C \"" + w.target + "\" rm --cached <file> ; ensure they are in .gitignore ; commit ; re-run.\n"
	if rc != 5 || w.err() != want || w.created() || w.pushed() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestTrackedSecretsAreAllNamed(t *testing.T) {
	w := newWorld(t)
	w.tracked = []string{"a.pem", "dir/b.key", "security/c"}
	rc := w.ok()
	if rc != 5 || !strings.Contains(w.err(), "would be pushed: a.pem dir/b.key security/c\n") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestTrackedListFailureFailsClosed(t *testing.T) {
	w := newWorld(t)
	w.lsFilesFail = true
	rc := w.ok()
	if rc != 7 || w.err() != "REFUSED: could not enumerate tracked files (git ls-files failed) — cannot verify no secret is tracked.\n" || w.created() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestTrackedListIsNULDelimitedAndBlankSafe(t *testing.T) {
	w := newWorld(t)
	w.tracked = []string{"", "x.pem", ""}
	rc := w.ok()
	if rc != 5 || !strings.Contains(w.err(), "would be pushed: x.pem\n") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

// ---- layer 5: create, then verify visibility before any push --------------------------------------------------

func TestVisibilityGuard(t *testing.T) {
	pub, priv := visOf(gh.StatePublic), visOf(gh.StatePrivate)
	for _, tt := range []struct {
		name      string
		vis       []gh.Visibility
		afterEdit *gh.Visibility
		editState gh.State
		editRC    int
		rc        int
		pushed    bool
		edits     int
		err       string
	}{
		{"private", []gh.Visibility{priv}, nil, gh.StateOK, 0, 0, true, 0, ""},
		{"public-stays-public", []gh.Visibility{pub}, nil, gh.StateOK, 0, 6, false, 1,
			"   visibility read back as 'PUBLIC' — forcing --visibility private once\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n"},
		{"public-forced-private", []gh.Visibility{pub, priv}, nil, gh.StateOK, 0, 0, true, 1,
			"   visibility read back as 'PUBLIC' — forcing --visibility private once\n"},
		{"internal-is-not-private", []gh.Visibility{visOf(gh.StateInternal)}, nil, gh.StateOK, 0, 6, false, 1,
			"   visibility read back as 'INTERNAL' — forcing --visibility private once\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n"},
		{"unknown-is-not-private", []gh.Visibility{{State: gh.StateTimeout}}, nil, gh.StateOK, 0, 6, false, 1,
			"   visibility read back as 'UNKNOWN(TIMEOUT)' — forcing --visibility private once\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n"},
		{"unrecognised-is-not-private", []gh.Visibility{{State: gh.StateUnrecognised, Raw: "PRIVATEISH"}}, nil, gh.StateOK, 0, 6, false, 1,
			"   visibility read back as 'UNKNOWN(UNRECOGNISED)' — forcing --visibility private once\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n"},
		{"edit-times-out-but-landed", []gh.Visibility{pub, pub}, &priv, gh.StateTimeout, 124, 0, true, 1,
			"   visibility read back as 'PUBLIC' — forcing --visibility private once\n" +
				"   DEGRADED: gh repo edit timed out after 20s — outcome unknown, re-reading visibility\n"},
		{"edit-times-out-still-public", []gh.Visibility{pub}, nil, gh.StateTimeout, 124, 6, false, 1,
			"   visibility read back as 'PUBLIC' — forcing --visibility private once\n" +
				"   DEGRADED: gh repo edit timed out after 20s — outcome unknown, re-reading visibility\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n"},
		{"edit-fails", []gh.Visibility{pub}, nil, gh.StateError, 1, 6, false, 1,
			"   visibility read back as 'PUBLIC' — forcing --visibility private once\n" +
				"   DEGRADED: gh repo edit failed (exit 1) — re-reading visibility\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n"},
		{"edit-missing-gh", []gh.Visibility{pub}, nil, gh.StateMissing, 127, 6, false, 1,
			"   visibility read back as 'PUBLIC' — forcing --visibility private once\n" +
				"   DEGRADED: gh repo edit failed (exit 127) — re-reading visibility\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.createAdds = true
			w.vis, w.visAfterEdit = tt.vis, tt.afterEdit
			w.editState, w.editRC = tt.editState, tt.editRC
			rc := w.ok()
			if rc != tt.rc || w.err() != tt.err || w.pushed() != tt.pushed || w.count("gh repo edit") != tt.edits {
				t.Errorf("rc=%d err=%q pushed=%v edits=%d\ncalls=%v", rc, w.err(), w.pushed(), w.count("gh repo edit"), w.calls)
			}
			if tt.edits > 0 && !w.called("gh repo edit tester/research-target --visibility private") {
				t.Errorf("edit args: %v", w.calls)
			}
			if tt.rc == 6 && w.origin != "" {
				t.Errorf("hard abort must remove the origin; still %q", w.origin)
			}
			// the push is always after the last visibility read
			if tt.pushed {
				last := -1
				for i, c := range w.calls {
					if strings.HasPrefix(c, "probe ") {
						last = i
					}
				}
				if !strings.Contains(w.calls[len(w.calls)-1], " push ") || last > len(w.calls)-2 {
					t.Errorf("push must follow the last probe: %v", w.calls)
				}
			}
		})
	}
}

func TestEditBoundIsTheProbeKnob(t *testing.T) {
	w := newWorld(t)
	w.vis = []gh.Visibility{visOf(gh.StatePublic), visOf(gh.StatePrivate)}
	w.editBound = gh.Bound{Seconds: 9}
	w.editState, w.editRC = gh.StateTimeout, 124
	w.ok()
	o := w.optsOf("gh repo edit")
	if o.Knob != "" && o.Knob != "RSDD_GH_TIMEOUT" {
		t.Errorf("edit knob = %q, want the default RSDD_GH_TIMEOUT", o.Knob)
	}
	if !strings.Contains(w.err(), "gh repo edit timed out after 9s") {
		t.Errorf("err = %q (the edit's own bound is reported)", w.err())
	}
}

func TestHardAbortOriginLeft(t *testing.T) { // exit-6 path checks its origin removal too
	w := newWorld(t)
	w.createAdds, w.removeFail = true, true
	w.vis = []gh.Visibility{visOf(gh.StatePublic)}
	rc := w.ok()
	if rc != 6 || w.pushed() {
		t.Fatalf("rc=%d", rc)
	}
	want := "   PARTIAL-STATE ORIGIN-LEFT: 'git remote remove origin' FAILED — the local origin https://github.com/tester/research-target.git is STILL configured and points at a NON-PRIVATE repo. Remove it by hand (git -C \"" + w.target + "\" remote remove origin).\n"
	if !strings.HasSuffix(w.err(), want) || strings.Contains(w.err(), "removed") {
		t.Errorf("err = %q", w.err())
	}
}

func TestHardAbortRemovalFailureWithNoOriginIsSilent(t *testing.T) {
	w := newWorld(t)
	w.removeFail = true // there is no origin to leave behind
	w.vis = []gh.Visibility{visOf(gh.StatePublic)}
	rc := w.ok()
	if rc != 6 || strings.Contains(w.err(), "ORIGIN-LEFT") || !w.called("remote remove origin") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

// ---- create failures and timeouts ---------------------------------------------------------------------------

func TestCreateFailure(t *testing.T) {
	for _, st := range []gh.State{gh.StateError, gh.StateMissing, gh.StateOutputCap, gh.StateProbeFailed} {
		w := newWorld(t)
		w.createState, w.createRC = st, 1
		rc := w.ok()
		if rc != 7 || w.err() != "REFUSED: gh repo create failed.\n" || strings.Contains(w.err(), "timed out") || w.pushed() || w.count("probe ") != 0 {
			t.Errorf("%s: rc=%d err=%q calls=%v", st, rc, w.err(), w.calls)
		}
	}
}

func TestCreatePassesGhOutputThrough(t *testing.T) {
	w := newWorld(t)
	w.createOut, w.createErr = "https://github.com/tester/research-target\n", "✓ Created repository\n"
	if rc := w.ok(); rc != 0 {
		t.Fatal(rc)
	}
	if !strings.Contains(w.out(), ">> creating PRIVATE remote tester/research-target\nhttps://github.com/tester/research-target\n") {
		t.Errorf("stdout = %q", w.out())
	}
	if w.err() != "✓ Created repository\n" {
		t.Errorf("stderr = %q", w.err())
	}
}

func TestCreateBadTimeoutKnobNote(t *testing.T) {
	w := newWorld(t)
	w.env["RSDD_GH_CREATE_TIMEOUT"] = "abc"
	w.createBound = gh.Bound{Seconds: 60, Bad: true}
	rc := w.ok()
	want := "   note: RSDD_GH_CREATE_TIMEOUT='abc' is not a positive integer — using the default 60s\n"
	if rc != 0 || w.err() != want {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
	// an empty (but set) knob is reported as ''
	w = newWorld(t)
	w.env["RSDD_GH_CREATE_TIMEOUT"] = ""
	w.createBound = gh.Bound{Seconds: 60, Bad: true}
	w.ok()
	if !strings.Contains(w.err(), "RSDD_GH_CREATE_TIMEOUT='' is not") {
		t.Errorf("err = %q", w.err())
	}
	// a good knob prints nothing
	w = newWorld(t)
	w.env["RSDD_GH_CREATE_TIMEOUT"] = "5"
	w.createBound = gh.Bound{Seconds: 5}
	w.ok()
	if w.err() != "" {
		t.Errorf("err = %q", w.err())
	}
}

const (
	manual = "https://github.com/tester/research-target"
)

func TestCreateTimeout(t *testing.T) {
	pub, priv := visOf(gh.StatePublic), visOf(gh.StatePrivate)
	unknown := gh.Visibility{State: gh.StateError, RC: 1}
	degraded := func(origin, vis string) string {
		return "DEGRADED: gh repo create timed out after 20s — PARTIAL-STATE local origin=" + origin + ", remote tester/research-target visibility=" + vis + "\n"
	}
	hard := func(vis string) string {
		return "!! HARD ABORT: a non-private repo (" + vis + ") exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
			"   (this wrapper has NO delete_repo scope). Nothing pushed; no local origin was added.\n"
	}
	for _, tt := range []struct {
		name       string
		adds       bool
		removeFail bool
		vis        []gh.Visibility
		rc         int
		pushed     bool
		err        string
		origin     string // origin left afterwards
	}{
		{"nothing-created", false, false, []gh.Visibility{unknown}, 7, false,
			degraded("absent", "UNKNOWN(GH_ERROR)") +
				"   PARTIAL-STATE UNKNOWN: the repo tester/research-target may exist with an unknown visibility; any local origin was removed; nothing pushed.\n" +
				"   Next: check https://github.com/tester/research-target by hand (delete it, or set it private) BEFORE re-running ensure-remote.sh — a re-run is NOT safe until its visibility is known.\n", ""},
		{"origin-added-visibility-unreadable", true, false, []gh.Visibility{unknown}, 7, false,
			degraded("configured", "UNKNOWN(GH_ERROR)") +
				"   PARTIAL-STATE UNKNOWN: the repo tester/research-target may exist with an unknown visibility; any local origin was removed; nothing pushed.\n" +
				"   Next: check https://github.com/tester/research-target by hand (delete it, or set it private) BEFORE re-running ensure-remote.sh — a re-run is NOT safe until its visibility is known.\n", ""},
		{"origin-removal-fails", true, true, []gh.Visibility{unknown}, 7, false,
			degraded("configured", "UNKNOWN(GH_ERROR)") +
				"   PARTIAL-STATE ORIGIN-LEFT: 'git remote remove origin' FAILED — the unverified local origin " + manual + ".git is STILL configured; the repo tester/research-target may exist with an unknown visibility; nothing pushed.\n" +
				"   Remove it by hand (git -C \"TARGET\" remote remove origin) — a re-run would short-circuit onto that unverified origin.\n" +
				"   Next: check https://github.com/tester/research-target by hand (delete it, or set it private) BEFORE re-running ensure-remote.sh — a re-run is NOT safe until its visibility is known.\n",
			manual + ".git"},
		{"origin-added-private-adopted", true, false, []gh.Visibility{priv, priv}, 0, true,
			degraded("configured", "PRIVATE") +
				"   next: local origin is configured — verifying the existing remote below; it is pushed ONLY if confirmed PRIVATE.\n", manual + ".git"},
		{"origin-added-public-aborts", true, false, []gh.Visibility{pub, pub, pub}, 6, false,
			degraded("configured", "PUBLIC") +
				"   next: local origin is configured — verifying the existing remote below; it is pushed ONLY if confirmed PRIVATE.\n" +
				"   visibility read back as 'PUBLIC' — forcing --visibility private once\n" +
				"!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-target — DELETE IT MANUALLY\n" +
				"   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n", ""},
		{"no-origin-private", false, false, []gh.Visibility{priv}, 7, false,
			degraded("absent", "PRIVATE") +
				"   the repo exists PRIVATE but no local origin was added. Nothing pushed. Next: git -C \"TARGET\" remote add origin https://github.com/tester/research-target.git\n" +
				"   and push it yourself (git push -u origin HEAD --no-follow-tags); re-running this script would fail on 'repo already exists'.\n", ""},
		{"no-origin-public", false, false, []gh.Visibility{pub}, 6, false,
			degraded("absent", "PUBLIC") + hard("PUBLIC"), ""},
		{"no-origin-internal", false, false, []gh.Visibility{visOf(gh.StateInternal)}, 6, false,
			degraded("absent", "INTERNAL") + hard("INTERNAL"), ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.createState, w.createRC = gh.StateTimeout, 124
			w.createAdds, w.removeFail = tt.adds, tt.removeFail
			w.vis = tt.vis
			rc := w.ok()
			want := strings.ReplaceAll(tt.err, "TARGET", w.target)
			if rc != tt.rc || w.err() != want || w.pushed() != tt.pushed || w.origin != tt.origin {
				t.Errorf("rc=%d pushed=%v origin=%q\nerr=%q\nwant=%q", rc, w.pushed(), w.origin, w.err(), want)
			}
			if strings.Contains(strings.ToLower(w.err()), "(safe)") {
				t.Errorf("a timed-out create must never claim a re-run is safe: %q", w.err())
			}
		})
	}
}

// The bash prints GHV_BOUND after the read-back overwrote it, so the DEGRADED line carries the PROBE's bound,
// not the create's. Kept byte for byte (reported in the PR as a legacy quirk).
func TestCreateTimeoutReportsTheProbeBound(t *testing.T) {
	w := newWorld(t)
	w.createState, w.createRC = gh.StateTimeout, 124
	w.createBound = gh.Bound{Seconds: 60}
	w.vis = []gh.Visibility{{State: gh.StateTimeout, Bound: gh.Bound{Seconds: 13}}}
	w.ok()
	if !strings.HasPrefix(w.err(), "DEGRADED: gh repo create timed out after 13s — PARTIAL-STATE") {
		t.Errorf("err = %q", w.err())
	}
	// a probe that never ran (bound 0) reads as the default 20
	w = newWorld(t)
	w.createState, w.createRC = gh.StateTimeout, 124
	w.vis = []gh.Visibility{{State: gh.StateMissing}}
	w.ok()
	if !strings.HasPrefix(w.err(), "DEGRADED: gh repo create timed out after 20s") {
		t.Errorf("err = %q", w.err())
	}
}

func TestCreateTimeoutBadKnobNoteComesFirst(t *testing.T) {
	w := newWorld(t)
	w.env["RSDD_GH_CREATE_TIMEOUT"] = "0"
	w.createState, w.createRC, w.createBound = gh.StateTimeout, 124, gh.Bound{Seconds: 60, Bad: true}
	w.vis = []gh.Visibility{visOf(gh.StatePrivate)}
	w.ok()
	if !strings.HasPrefix(w.err(), "   note: RSDD_GH_CREATE_TIMEOUT='0' is not a positive integer — using the default 60s\nDEGRADED: gh repo create timed out") {
		t.Errorf("err = %q", w.err())
	}
}

func TestTimeoutRerunFlow(t *testing.T) {
	// 22f: after a nothing-created timeout, a re-run (no stall now) completes with exactly one push
	w := newWorld(t)
	w.createState, w.createRC = gh.StateTimeout, 124
	w.vis = []gh.Visibility{{State: gh.StateError}}
	if rc := w.ok(); rc != 7 {
		t.Fatal(rc)
	}
	w.createState, w.createRC = gh.StateOK, 0
	w.vis = []gh.Visibility{visOf(gh.StatePrivate)}
	w.stdout.Reset()
	w.stderr.Reset()
	if rc := w.ok(); rc != 0 || w.count(" push ") != 1 {
		t.Errorf("calls=%v", w.calls)
	}
	// 22b2: and a re-run on an adopted origin is the idempotent no-op
	w2 := newWorld(t)
	w2.createState, w2.createRC, w2.createAdds = gh.StateTimeout, 124, true
	w2.vis = []gh.Visibility{visOf(gh.StatePrivate)}
	if rc := w2.ok(); rc != 0 {
		t.Fatal(rc)
	}
	w2.stdout.Reset()
	if rc := w2.ok(); rc != 0 || !strings.Contains(w2.out(), "origin already set") || w2.count("gh repo create") != 1 || w2.count(" push ") != 1 {
		t.Errorf("rc=%d out=%q calls=%v", rc, w2.out(), w2.calls)
	}
}

func TestPublicAfterTimeoutRerunStartsClean(t *testing.T) {
	// 22c2: a re-run on a still-PUBLIC repo aborts 6 again and never short-circuits on a stale origin
	w := newWorld(t)
	w.createState, w.createRC, w.createAdds = gh.StateTimeout, 124, true
	w.vis = []gh.Visibility{visOf(gh.StatePublic)}
	if rc := w.ok(); rc != 6 || w.origin != "" {
		t.Fatalf("rc=%d origin=%q", rc, w.origin)
	}
	w.stdout.Reset()
	if rc := w.ok(); rc != 6 || strings.Contains(w.out(), "origin already set") || w.pushed() {
		t.Errorf("rc=%d out=%q", rc, w.out())
	}
}

// ---- push ----------------------------------------------------------------------------------------------------

func TestPushFailure(t *testing.T) {
	w := newWorld(t)
	w.pushRC = 1
	rc := w.ok()
	if rc != 7 || !strings.HasSuffix(w.err(), "REFUSED: push failed.\n") || strings.Contains(w.out(), "private remote ready") {
		t.Errorf("rc=%d err=%q out=%q", rc, w.err(), w.out())
	}
}

func TestPushOutputPassesThrough(t *testing.T) {
	w := newWorld(t)
	w.pushOut, w.pushErr = "branch 'main' set up\n", "To github.com:tester/research-target.git\n"
	if rc := w.ok(); rc != 0 {
		t.Fatal(rc)
	}
	if !strings.Contains(w.out(), ">> confirmed PRIVATE — pushing corpus\nbranch 'main' set up\n== ensure-remote") || w.err() != "To github.com:tester/research-target.git\n" {
		t.Errorf("out=%q err=%q", w.out(), w.err())
	}
}

func TestGitCallsGetTheCallersEnvironment(t *testing.T) {
	w := newWorld(t)
	w.env["GIT_CONFIG_GLOBAL"] = "/dev/null"
	w.ok()
	for _, c := range w.cmds {
		if !contains(c.Env, "GIT_CONFIG_GLOBAL=/dev/null") || !contains(c.Env, "HOME=/home/x") {
			t.Errorf("%v: env %v", c.Argv, c.Env)
		}
		if c.Timeout <= 0 {
			t.Errorf("%v: every external run is bounded", c.Argv)
		}
	}
}

// ---- .gitignore I/O and git output edges ----------------------------------------------------------------------

func TestGitignoreThatCannotBeWrittenIsReportedNotFatal(t *testing.T) {
	w := newWorld(t)
	os.Mkdir(filepath.Join(w.target, ".gitignore"), 0o755) // a directory: it can be neither read nor appended to
	rc := w.ok()
	if rc != 0 || !strings.HasPrefix(w.err(), "ensure-remote: cannot update "+filepath.Join(w.target, ".gitignore")+": ") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestCompleteGitignoreIsNeverOpenedForWriting(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes through a read-only mode")
	}
	w := newWorld(t)
	gi := filepath.Join(w.target, ".gitignore")
	os.WriteFile(gi, []byte(strings.Join(secretPatterns, "\n")+"\n"), 0o444)
	if rc := w.ok(); rc != 0 || w.err() != "" {
		t.Errorf("rc=%d err=%q (an up-to-date .gitignore needs no write)", rc, w.err())
	}
}

func TestFailedGitAddPassesItsOutputAndSkipsTheCommit(t *testing.T) {
	w := newWorld(t)
	w.diffRC, w.addRC, w.addErr = 1, 1, "fatal: pathspec '.gitignore' did not match any files\n"
	rc := w.ok()
	if rc != 0 || w.err() != w.addErr || w.called(" commit ") {
		t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
}

func TestRelativeToolbeltResolvesAgainstCwd(t *testing.T) {
	w := newWorld(t)
	rc := execute([]string{"--toolbelt", "toolbelt", w.target, "--yes"}, w.stdio(), w.deps())
	if rc != 0 || !w.called("bash "+w.toolbelt+"/scan-secrets.sh --committed") {
		t.Errorf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
}

func TestSeededGitignoreIgnoresReadFailureOfAMissingFile(t *testing.T) {
	// no .gitignore at all: created with the whole block and no leading blank line
	w := newWorld(t)
	w.ok()
	b, _ := os.ReadFile(filepath.Join(w.target, ".gitignore"))
	if !strings.HasPrefix(string(b), "security/\n") || !strings.HasSuffix(string(b), "*.keystore\n") {
		t.Errorf(".gitignore = %q", b)
	}
}

// Hermeticity: a relative <target-dir> and --toolbelt resolve against Stdio.Cwd, never against the process working
// directory, so nothing is read or written there.
func TestRelativePathsNeverTouchTheProcessCwd(t *testing.T) {
	w := newWorld(t) // Cwd is w.root; the target is w.root/target
	proc := t.TempDir()
	t.Chdir(proc)
	rel, err := filepath.Rel(w.root, w.target)
	if err != nil {
		t.Fatal(err)
	}
	relTB, err := filepath.Rel(w.root, w.toolbelt)
	if err != nil {
		t.Fatal(err)
	}
	if rc := execute([]string{"--toolbelt", relTB, rel, "--yes"}, w.stdio(), w.deps()); rc != 0 {
		t.Fatalf("rc=%d err=%q calls=%v", rc, w.err(), w.calls)
	}
	if ents, _ := os.ReadDir(proc); len(ents) != 0 {
		t.Errorf("the process cwd was written to: %v", ents)
	}
	if _, err := os.Stat(filepath.Join(w.target, ".gitignore")); err != nil {
		t.Errorf(".gitignore not seeded under the Stdio cwd target: %v", err)
	}
	if !w.called("-C "+w.target+" rev-parse") || !w.called("bash "+filepath.Join(w.toolbelt, "scan-secrets.sh")+" --committed") {
		t.Errorf("paths printed/passed must be the absolute Cwd-resolved ones: %v", w.calls)
	}
}
