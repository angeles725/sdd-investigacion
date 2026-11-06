//go:build !nodiff && unix

package verify

import (
	"bytes"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Differential tests for `verify registry`: the frozen legacy script and libs (testdata/legacy/registry, the
// bytes of verify-registry.sh and lib/{retro-status,target-paths,block-files,state-files,corpus-markers,
// hook-wiring}.sh before the port) and the Go command must print the same stdout and stderr and exit with the
// same code from the same sandbox, in the default mode and under --json. The Go side gets a bash-backed
// registryHooks that runs the SAME frozen lib/hook-wiring.sh and a stub verify-session-budget.sh, so the sections
// that need hook wiring are compared too (production code never shells out). A missing bash FAILS: a skipped
// differential proves nothing.

func legacyRegistry(t *testing.T, rel string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", "legacy", "registry", rel))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

var legacyRegistryFiles = []string{
	"verify-registry.sh", "lib/retro-status.sh", "lib/target-paths.sh", "lib/block-files.sh",
	"lib/state-files.sh", "lib/corpus-markers.sh", "lib/hook-wiring.sh",
}

const budgetStub = `#!/usr/bin/env bash
case "$(basename "$1")" in
  over) printf 'hook a status=TRUNCATED\nhook b status=timed-out\naggregate: 9123 chars worst-source=startup\nOVER BUDGET\nstate: degraded\n' ;;
  nostate) echo crashed ;;
  clean) echo 'state: ok' ;;
  *) echo 'state: ok' ;;
esac
`

// installLegacy copies the frozen script and libs into the sandbox kit's toolbelt.
func (k *vrKit) installLegacy() {
	k.t.Helper()
	for _, f := range legacyRegistryFiles {
		b, err := os.ReadFile(legacyRegistry(k.t, f))
		if err != nil {
			k.t.Fatalf("frozen legacy file missing: %v", err)
		}
		k.write("home/kit/toolbelt/"+f, string(b))
	}
	k.write("home/kit/toolbelt/verify-session-budget.sh", budgetStub)
}

// legacyEnv is the environment of the legacy run and of the bash-backed hooks.
func (k *vrKit) legacyEnv(extra map[string]string) []string {
	e := k.env(extra)
	var out []string
	for kk, v := range e {
		out = append(out, kk+"="+v)
	}
	return out
}

func (k *vrKit) runLegacy(env map[string]string, args ...string) vrResult {
	k.t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		k.t.Fatalf("differential: bash not found; the Go port is NOT proven against verify-registry.sh: %v", err)
	}
	cmd := exec.Command(bash, append([]string{filepath.Join(k.kit, "toolbelt", "verify-registry.sh")}, args...)...)
	cmd.Dir = k.root
	cmd.Env = k.legacyEnv(env)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			k.t.Fatalf("legacy run: %v", err)
		}
		rc = ee.ExitCode()
	}
	return vrResult{out.String(), errb.String(), rc}
}

// shellHooks answers registryHooks by running the frozen lib/hook-wiring.sh functions in bash.
type shellHooks struct {
	t   *testing.T
	k   *vrKit
	env []string
	lib string
}

func (h shellHooks) bash(script string, args ...string) (string, bool) {
	cmd := exec.Command("bash", append([]string{"-c", script, "_"}, args...)...)
	cmd.Env = h.env
	cmd.Dir = h.k.root
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		if _, ok := err.(*exec.ExitError); !ok {
			h.t.Fatalf("hooks: %v", err)
		}
	}
	return out.String(), true
}

func (h shellHooks) fn(name, target string) (string, bool) {
	out, ok := h.bash(`. "$1"; "$2" "$3"`, h.lib, name, target)
	return strings.TrimRight(out, "\n"), ok
}

func (h shellHooks) StopWiringState(t string) (string, bool) {
	return h.fn("hook_stop_wiring_state", t)
}
func (h shellHooks) StopScriptState(t string) (string, bool) {
	return h.fn("hook_stop_script_state", t)
}
func (h shellHooks) StopLaunchState(t string) (string, bool) {
	return h.fn("hook_stop_launch_state", t)
}

func (h shellHooks) WiredExecReport(t string) ([]wiredExec, bool) {
	out, _ := h.bash(`. "$1"; hook_wired_exec_report "$2"`, h.lib, t)
	var rows []wiredExec
	for _, l := range splitLinesKeepEmpty(out) {
		a, b, c := readTab3(l)
		rows = append(rows, wiredExec{a, b, c})
	}
	return rows, true
}

func (h shellHooks) SessionBudget(t string) (string, bool) {
	cmd := exec.Command("bash", filepath.Join(h.k.kit, "toolbelt", "verify-session-budget.sh"), t)
	cmd.Env = h.env
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	_ = cmd.Run()
	return strings.TrimRight(out.String(), "\n"), true
}

func splitLinesKeepEmpty(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}

// readTab3 is `IFS=$'\t' read -r a b c`: tab is IFS whitespace, so leading tabs are dropped, runs collapse, and
// the last variable keeps the rest minus trailing tabs.
func readTab3(line string) (a, b, c string) {
	cut := func(s string) (field, rest string) {
		s = strings.TrimLeft(s, "\t")
		i := strings.IndexByte(s, '\t')
		if i < 0 {
			return s, ""
		}
		return s[:i], strings.TrimLeft(s[i:], "\t")
	}
	a, rest := cut(line)
	b, rest = cut(rest)
	c = strings.TrimRight(rest, "\t")
	return a, b, c
}

// runBoth runs the legacy script and the Go command on the same sandbox and compares them.
func (k *vrKit) runBoth(name string, env map[string]string, args ...string) {
	k.t.Helper()
	legacyRes := k.runLegacy(env, args...)
	hooks := shellHooks{t: k.t, k: k, env: k.legacyEnv(env), lib: filepath.Join(k.kit, "toolbelt", "lib", "hook-wiring.sh")}
	old := newRegistryHooks
	newRegistryHooks = func(cli.Stdio) registryHooks { return hooks }
	defer func() { newRegistryHooks = old }()
	goRes := k.run(env, args...)
	if legacyRes != goRes {
		k.t.Errorf("%s %v differs from the legacy script:\nlegacy rc=%d\n--stdout--\n%s--stderr--\n%s\n    go rc=%d\n--stdout--\n%s--stderr--\n%s",
			name, args, legacyRes.rc, legacyRes.stdout, legacyRes.stderr, goRes.rc, goRes.stdout, goRes.stderr)
	}
}

// both compares the default mode and --json.
func (k *vrKit) both(name string, env map[string]string) {
	k.t.Helper()
	k.runBoth(name, env)
	k.runBoth(name, env, "--json")
}

func settings(cmd string) string {
	return `{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"` + cmd + `"}]}]}}`
}

type scenario struct {
	name  string
	build func(k *vrKit) map[string]string // returns extra env
}

func registryScenarios() []scenario {
	return []scenario{
		{"consistent", func(k *vrKit) map[string]string {
			k.blocks("alpha", 3)
			k.put("alpha/retros/r.md", "x\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(3 blocks)")))
			return nil
		}},
		{"drift-and-tol", func(k *vrKit) map[string]string {
			k.blocks("alpha", 5)
			k.put("alpha/retros/r.md", "x\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(08 md)")))
			return map[string]string{"RSDD_REGISTRY_TOL": "1"}
		}},
		{"tol-override", func(k *vrKit) map[string]string {
			k.blocks("alpha", 5)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(40 md)")))
			return map[string]string{"RSDD_REGISTRY_TOL": "50"}
		}},
		{"no-claim", func(k *vrKit) map[string]string {
			k.blocks("alpha", 4)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 focus)")))
			return nil
		}},
		{"absent-rows", func(k *vrKit) map[string]string {
			k.blocks("here", 1)
			k.targets(vrTable(vrRow("1", "here", "here", "(1 md)"), vrRow("2", "g1", "g1", "(1 md)"), vrRow("3", "g2", "g2", "(1 md)"),
				vrRow("4", "g3", "g3", "(1 md)"), vrRow("5", "g4", "g4", "(1 md)"), "| 6 | two | `@H@/g5` `@H@/g5b` | (1 md) | x | en |",
				"| 7 | slug | `/mrdoob/three.js` `@H@/here` | (1 md) | x | en |", "| 8 | rowless |  `/loose/x` | y |"))
			return nil
		}},
		{"truncated", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)"), "| 2 | cut | `@H@/long/path/...` | (1 md) | x | en |", "| 3 | cut2 | `/a/b/...` | (1 md) | x | en |"))
			return nil
		}},
		{"maturity", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.blocks("beta", 1)
			k.blocks("gamma", 1)
			k.blocks("delta", 1)
			k.targets(vrTable(
				vrRow("1", "alpha", "alpha", "(1 md @2026-01-02, ACTIVE / 2 focuses / 3 runs / 4 retros + 1 corpus §18 / 2-of-5 gaps / git yes / remote no / hook anything here / unregistered / registered-no-sessions)"),
				vrRow("2", "beta", "beta", "(1 md-x / bogus here / 3 retrograde motion / 1 md @2026-1-2)"),
				vrRow("3", "gamma", "gamma", "(whatever)"),
				vrRow("4", "delta", "delta", "(1 md /  / 2 RUNS / Git yes / nc2)")))
			return nil
		}},
		{"nc", func(k *vrKit) map[string]string {
			for _, f := range []string{"t1/a.md", "t1/b.md", "t1/sub/c.md", "t2/a.md", "t3/a.md", "t3/RESEARCH-STATE.md", "t4/x.txt"} {
				k.put(f, "x\n")
			}
			k.targets(vrTable(vrRow("1", "t1", "t1", "(9 md / nc)"), vrRow("2", "t2", "t2", "(1 run / nc)"),
				vrRow("3", "t3", "t3", "(1 md / nc)"), vrRow("4", "t4", "t4", "(0 md / nc / x)"), vrRow("5", "t5", "t4", "(0 md / nc;)")))
			return nil
		}},
		{"markers", func(k *vrKit) map[string]string {
			k.put("deep/research/RESEARCH-STATE.md", "s\n")
			k.put("deep/research/p-block1.md", "b\n")
			k.put("nest/corpus/RESEARCH-STATE.md", "s\n")
			k.put("nest/corpus/p-block1.md", "b\n")
			k.put("bare/INDEX.md", "i\n")
			k.put("tmpl/RESEARCH-STATE.template.md", "s\n")
			k.put("amb/a/RESEARCH-STATE.md", "s\n")
			k.put("amb/b/RESEARCH-STATE.md", "s\n")
			k.put("foc/RESEARCH-STATE-x.md", "s\n")
			k.put("foc/p-block1.md", "b\n")
			k.targets(vrTable(vrRow("1", "deep", "deep", "(1 md)"), vrRow("2", "nest", "nest", "(1 md)"), vrRow("3", "bare", "bare", "(1 md)"),
				vrRow("4", "tmpl", "tmpl", "(1 md)"), vrRow("5", "amb", "amb", "(0 md)"), vrRow("6", "foc", "foc", "(1 md)")))
			return nil
		}},
		{"retros", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.put("alpha/retros/r1.md", "# r\n")
			k.put("alpha/retros/r2.md", "<!-- kit-retro: exclude -->\n# r\n")
			k.put("alpha/retros/INDEX-retros.md", "# idx\n")
			k.put("alpha/research/retros/r3.md", "# deep\n")
			k.put("alpha/retros/r4.md", "\xef\xbb\xbf<!-- kit-retro: exclude -->\n")
			k.put("alpha/retros/r5.md", "<!-- a -->\ntext\n<!-- kit-retro: exclude -->\n")
			k.put("alpha/retros/r6.md", "\n\n  <!--  KIT-RETRO:EXCLUDE  -->  \n# x")
			k.put("alpha/retros/r7.md", "<!-- kit-retro: exclude --> trailing\n")
			k.put("alpha/.git/retros/g.md", "x\n")
			k.blocks("beta", 4)
			k.put("beta/retros/only-excluded.md", "<!-- kit-retro: exclude -->\n")
			k.blocks("gamma", 1)
			k.put("gamma/deep/er/retros/too-deep.md", "x\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / 3 retros)"), vrRow("2", "beta", "beta", "(4 md / 1 retro)"), vrRow("3", "gamma", "gamma", "(1 md / 1 retro)")))
			return nil
		}},
		{"catalog", func(k *vrKit) map[string]string {
			type c struct {
				name, header string
				rows, blocks int
				claim        string
			}
			var rows []string
			for i, cc := range []c{
				{"cfresh", "Total: 6", 6, 5, "6"}, {"cfdrift", "Total: 6", 6, 5, "12"}, {"cstalehdr", "Total: 9", 6, 5, "5"},
				{"cstale", "Total: 12", 12, 5, "12"}, {"cdisc0", "Total: 12", 12, 0, "12"}, {"cnoparse", "no digits", 6, 5, "5"},
				{"ctok", "12 bloques", 12, 5, "12"}, {"czero", "Total: 0", 0, 0, "0"}, {"cleading", "Total: 06", 6, 5, "6"},
			} {
				k.blocks(cc.name, cc.blocks)
				k.put(cc.name+"/retros/r.md", "x\n")
				k.catalog(cc.name, cc.header, cc.rows)
				rows = append(rows, vrRow(strconv.Itoa(i+1), cc.name, cc.name, "("+cc.claim+" md)"))
			}
			k.targets(vrTable(rows...))
			return nil
		}},
		{"unclassifiable", func(k *vrKit) map[string]string {
			k.put("alpha/RESEARCH-STATE.md", "s\n")
			for _, n := range []string{"block1.md", "bloque3.md", "block_07.md", "blocking-issues.md", "block-diagram.md", "bloques-pendientes.md", "roadblock.md", "p-block9.md.bak", "BLOCK5.md"} {
				k.put("alpha/"+n, "x\n")
			}
			k.blocks("beta", 3)
			k.put("beta/retros/r.md", "x\n")
			k.put("gamma/RESEARCH-STATE.md", "s\n")
			k.put("gamma/p-block1.md", "b\n")
			k.put("gamma/p-bloque2-x.md", "b\n")
			k.put("gamma/p-block3.MD", "b\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(0 md)"), vrRow("2", "beta", "beta", "(3 md)"), vrRow("3", "gamma", "gamma", "(2 md)")))
			return nil
		}},
		{"hygiene", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			long := strings.Repeat("é", 30)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")) + "| 7 | wordy | `@H@/alpha` | (1 md) | " + long + " | en |\n|8|tight|`@H@/alpha`|(1 md)|" + strings.Repeat("y", 31) + "|en|\n| 9 | | `@H@/alpha` | (1 md) | " + strings.Repeat("z", 40) + " |")
			return map[string]string{"RSDD_ROW_MAXLEN": "25"}
		}},
		{"hygiene-utf8", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")) + "| 7 | wordy | `@H@/alpha` | (1 md) | " + strings.Repeat("é", 30) + " | en |\n")
			return map[string]string{"RSDD_ROW_MAXLEN": "40", "LC_ALL": "C.UTF-8"}
		}},
		{"hygiene-text-max", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
			return map[string]string{"RSDD_ROW_MAXLEN": "abc"}
		}},
		{"kit-unregistered", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.write("home/kit/TARGETS.md", "| 1 | alpha | `$RESEARCH_HOME/alpha` | (1 md) | x | en |\n")
			return nil
		}},
		{"kit-parent", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.write("home/kit/TARGETS.md", "| 1 | alpha | `$RESEARCH_HOME/alpha` | (1 md) | x | en |\n| 2 | root | `"+k.home+"` | (0 md / nc) | x | en |\n")
			return nil
		}},
		{"rh-braces-and-slash", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.targets(vrTable("| 1 | a | `${RESEARCH_HOME}/alpha` | (1 md) | x | en |", "| 2 | b | `$RESEARCH_HOME/alpha` | (1 md) | x | en |"))
			return map[string]string{"RESEARCH_HOME": ""}
		}},
		{"all-absent", func(k *vrKit) map[string]string {
			k.targets("| 1 | gone | `@H@/nowhere` | (1 md) | x | en |\n")
			return nil
		}},
		{"all-absent-unset-home", func(k *vrKit) map[string]string {
			k.targets("| 1 | gone | `@H@/nowhere` | (1 md) | x | en |\n")
			return map[string]string{"RESEARCH_HOME": ""}
		}},
		{"no-paths", func(k *vrKit) map[string]string { k.targets("| # | Name |\n|---|---|\n| 1 | prose |\n"); return nil }},
		{"empty-targets", func(k *vrKit) map[string]string { k.targets(""); return nil }},
		{"targets-missing", func(k *vrKit) map[string]string {
			if err := os.Remove(k.targetsMD); err != nil && !os.IsNotExist(err) {
				k.t.Fatal(err)
			}
			return nil
		}},
		{"symlinked-target", func(k *vrKit) map[string]string {
			k.blocks("real", 2)
			if err := os.Symlink(filepath.Join(k.home, "real"), filepath.Join(k.home, "link")); err != nil {
				k.t.Fatal(err)
			}
			k.targets(vrTable(vrRow("1", "link", "link", "(2 md)"), vrRow("2", "tool", "link", "(2 md / nc)")))
			return nil
		}},
		// hook sections, against the frozen lib/hook-wiring.sh
		{"hook-yes-wired", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.put("alpha/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
			k.put("alpha/.claude/settings.json", settings(k.home+"/alpha/.claude/hooks/retro-gate-stop.sh"))
			k.put("alpha/.git/HEAD", "x\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / hook yes)")))
			return map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root}
		}},
		{"hook-yes-states", func(k *vrKit) map[string]string {
			for _, n := range []string{"absent", "unwired", "missing", "offroot", "nosess", "degraded"} {
				k.blocks(n, 1)
			}
			k.put("unwired/.claude/settings.json", settings("some-other-hook.sh"))
			k.put("missing/.claude/settings.json", settings(k.home+"/missing/.claude/hooks/retro-gate-stop.sh"))
			k.put("offroot/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
			k.put("offroot/.claude/settings.json", settings(k.home+"/offroot/.claude/hooks/retro-gate-stop.sh"))
			k.put("nosess/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
			k.put("nosess/.claude/settings.json", settings(k.home+"/nosess/.claude/hooks/retro-gate-stop.sh"))
			k.put("nosess/.git/HEAD", "x\n")
			k.put("degraded/.claude/settings.json", "{not json")
			k.write("hist/-other/x.jsonl", "{}\n")
			k.put(".git/HEAD", "x\n")
			var rows []string
			for i, n := range []string{"absent", "unwired", "missing", "offroot", "nosess", "degraded"} {
				rows = append(rows, vrRow(strconv.Itoa(i+1), n, n, "(1 md / hook yes)"))
			}
			k.targets(vrTable(rows...))
			return map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root, "RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(k.root, "hist")}
		}},
		{"hook-launched", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.put("alpha/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
			k.put("alpha/.claude/settings.json", settings(k.home+"/alpha/.claude/hooks/retro-gate-stop.sh"))
			k.put("alpha/.git/HEAD", "x\n")
			enc := strings.NewReplacer("/", "-", ".", "-").Replace(k.home + "/alpha")
			k.write("hist/"+enc+"/s.jsonl", "{}\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / hook file yes / unregistered)")))
			return map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root, "RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(k.root, "hist")}
		}},
		{"hook-file-claims", func(k *vrKit) map[string]string {
			names := []string{"u1", "u2", "n1", "n2", "n3", "plain"}
			for _, n := range names {
				k.blocks(n, 1)
			}
			for _, n := range []string{"u1", "u2", "n1", "n2"} {
				k.put(n+"/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
				k.put(n+"/.claude/settings.json", settings(k.home+"/"+n+"/.claude/hooks/retro-gate-stop.sh"))
				k.put(n+"/.git/HEAD", "x\n")
			}
			k.put("n3/.claude/settings.json", settings("elsewhere.sh"))
			k.write("hist/-other/x.jsonl", "{}\n")
			k.write("hist/"+strings.NewReplacer("/", "-", ".", "-").Replace(k.home+"/n2")+"/s.jsonl", "{}\n")
			k.targets(vrTable(
				vrRow("1", "u1", "u1", "(1 md / hook file yes / unregistered)"),
				vrRow("2", "u2", "u2", "(1 md / hook file yes / unregistered / registered-no-sessions)"),
				vrRow("3", "n1", "n1", "(1 md / hook file yes / registered-no-sessions)"),
				vrRow("4", "n2", "n2", "(1 md / hook file yes / registered-no-sessions)"),
				vrRow("5", "n3", "n3", "(1 md / hook file yes / registered-no-sessions)"),
				vrRow("6", "plain", "plain", "(1 md / hook file yes)")))
			return map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root, "RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(k.root, "hist")}
		}},
		{"hook-no", func(k *vrKit) map[string]string {
			for _, n := range []string{"w", "m", "o", "plain"} {
				k.blocks(n, 1)
			}
			k.put("w/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
			k.put("w/.claude/settings.json", settings(k.home+"/w/.claude/hooks/retro-gate-stop.sh"))
			k.put("w/.git/HEAD", "x\n")
			k.put("m/.claude/settings.json", settings(k.home+"/m/.claude/hooks/retro-gate-stop.sh"))
			k.put("m/.git/HEAD", "x\n")
			k.put("o/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
			k.put("o/.claude/settings.json", settings(k.home+"/o/.claude/hooks/retro-gate-stop.sh"))
			k.targets(vrTable(vrRow("1", "w", "w", "(1 md / hook no)"), vrRow("2", "m", "m", "(1 md / hook no)"),
				vrRow("3", "o", "o", "(1 md / Hook No)"), vrRow("4", "plain", "plain", "(1 md / hook no)")))
			return map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root}
		}},
		{"wired-exec", func(k *vrKit) map[string]string {
			k.blocks("alpha", 1)
			k.put("alpha/.claude/hooks/ok.sh", "#!/bin/sh\n")
			if err := os.Chmod(filepath.Join(k.home, "alpha/.claude/hooks/ok.sh"), 0o755); err != nil {
				k.t.Fatal(err)
			}
			k.put("alpha/.claude/hooks/noexec.sh", "#!/bin/sh\n")
			k.put("alpha/.claude/settings.json", `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"`+k.home+`/alpha/.claude/hooks/ok.sh"},{"type":"command","command":"`+k.home+`/alpha/.claude/hooks/noexec.sh"},{"type":"command","command":"`+k.home+`/alpha/.claude/hooks/gone.sh"},{"type":"command","command":"bash -c 'echo hi'"}]}],"Stop":[{"hooks":[{"type":"command","command":"`+k.home+`/alpha/.claude/hooks/retro-gate-stop.sh"}]}]}}`)
			k.put("alpha/.git/HEAD", "x\n")
			k.blocks("beta", 1)
			k.put("beta/.claude/settings.json", "{bad")
			k.blocks("gamma", 1)
			k.put("gamma/.claude/", "")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / hook yes)"), vrRow("2", "beta", "beta", "(1 md)"), vrRow("3", "gamma", "gamma", "(1 md)")))
			return map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root}
		}},
		{"session-budget", func(k *vrKit) map[string]string {
			for _, n := range []string{"over", "nostate", "clean", "nosettings"} {
				k.blocks(n, 1)
			}
			for _, n := range []string{"over", "nostate", "clean"} {
				k.put(n+"/.claude/settings.json", "{}\n")
			}
			k.targets(vrTable(vrRow("1", "over", "over", "(1 md)"), vrRow("2", "nostate", "nostate", "(1 md)"),
				vrRow("3", "clean", "clean", "(1 md)"), vrRow("4", "nosettings", "nosettings", "(1 md)")))
			return map[string]string{"RSDD_REGISTRY_SESSION_BUDGET": "1"}
		}},
		{"session-budget-script-missing", func(k *vrKit) map[string]string {
			k.blocks("over", 1)
			k.put("over/.claude/settings.json", "{}\n")
			k.targets(vrTable(vrRow("1", "over", "over", "(1 md)")))
			if err := os.Remove(filepath.Join(k.kit, "toolbelt", "verify-session-budget.sh")); err != nil {
				k.t.Fatal(err)
			}
			return map[string]string{"RSDD_REGISTRY_SESSION_BUDGET": "1"}
		}},
	}
}

func TestRegistryDifferential(t *testing.T) {
	for _, sc := range registryScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			k := newVRKit(t)
			k.installLegacy()
			env := sc.build(k)
			k.both(sc.name, env)
		})
	}
	t.Run("usage", func(t *testing.T) {
		k := newVRKit(t)
		k.installLegacy()
		k.targets(vrTable())
		k.runBoth("usage", nil, "--bogus")
		k.runBoth("usage", nil, "--json", "extra")
		k.runBoth("usage", nil, "extra", "--json")
	})
}

// TestRegistryRealFleet is the real-data acceptance: the live kit's TARGETS.md and the live corpora on this
// machine, the live toolbelt script (RSDD_REAL_FLEET_KIT, the kit root) against the Go command. Read-only on every
// corpus. Opt-in (RSDD_REAL_FLEET=1) because the result depends on the machine, not on the code.
func TestRegistryRealFleet(t *testing.T) {
	if os.Getenv("RSDD_REAL_FLEET") != "1" {
		t.Skip("real-fleet acceptance is opt-in: set RSDD_REAL_FLEET=1 and RSDD_REAL_FLEET_KIT=<kit root>")
	}
	kitRoot := os.Getenv("RSDD_REAL_FLEET_KIT")
	if kitRoot == "" {
		t.Fatal("RSDD_REAL_FLEET_KIT is not set")
	}
	k := &vrKit{t: t, root: kitRoot, kit: kitRoot, home: os.Getenv("HOME"), targetsMD: kitRoot + "/TARGETS.md"}
	env := map[string]string{"RESEARCH_HOME": os.Getenv("RESEARCH_HOME"), "RSDD_HOOK_WIRING_CEILING": os.Getenv("RSDD_HOOK_WIRING_CEILING")}
	for _, mode := range [][]string{nil, {"--json"}} {
		k.runBoth("real-fleet", env, mode...)
	}
}

// TestRegistryGeneratedDifferential builds pseudo-random registries (a fixed seed, so a failure reproduces) from
// a pool of maturity tokens, block counts, retro layouts and claims, and compares both modes on each.
func TestRegistryGeneratedDifferential(t *testing.T) {
	rng := rand.New(rand.NewSource(20261101))
	pool := []string{"3 md", "5 blocks", "0 md", "12 blocks @2026-02-03", "1 focus", "2 runs", "2 retros", "1 retro", "4 retros + 1 corpus §18",
		"1-of-3 gaps", "git yes", "remote no", "hook no", "hook file yes", "hook yes", "unregistered", "registered-no-sessions", "nc", "junk", "09 md"}
	for i := 0; i < 40; i++ {
		t.Run(fmt.Sprintf("gen%02d", i), func(t *testing.T) {
			k := newVRKit(t)
			k.installLegacy()
			var rows []string
			for n := 0; n < 1+rng.Intn(5); n++ {
				name := fmt.Sprintf("t%d", n)
				var toks []string
				for j := 0; j < 1+rng.Intn(5); j++ {
					toks = append(toks, pool[rng.Intn(len(pool))])
				}
				switch rng.Intn(5) {
				case 0: // absent
				case 1:
					k.put(name+"/a.md", "x\n")
				default:
					k.blocks(name, rng.Intn(8))
					for r := 0; r < rng.Intn(3); r++ {
						ex := ""
						if rng.Intn(2) == 0 {
							ex = "<!-- kit-retro: exclude -->\n"
						}
						k.put(fmt.Sprintf("%s/retros/r%d.md", name, r), ex+"# r\n")
					}
					if rng.Intn(3) == 0 {
						k.catalog(name, "Total: "+strconv.Itoa(rng.Intn(10)), rng.Intn(10))
					}
					if rng.Intn(3) == 0 {
						k.put(name+"/.claude/settings.json", settings("retro-gate-stop.sh"))
					}
				}
				rows = append(rows, vrRow(strconv.Itoa(n+1), name, name, "("+strings.Join(toks, " / ")+")"))
			}
			k.targets(vrTable(rows...))
			k.both(fmt.Sprintf("gen%02d", i), map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root, "RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(k.root, "hist")})
		})
	}
}
