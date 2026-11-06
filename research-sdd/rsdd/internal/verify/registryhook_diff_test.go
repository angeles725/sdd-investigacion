//go:build !nodiff && unix

package verify

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// Differential test of `verify registry-hook`: the frozen verify-registry-hook.sh (with the frozen verify-registry.sh
// and libs it runs and lib/hook-emit.sh) and the Go command print the same envelope from the same sandbox, in
// the compact default and under --full. Both sides run the real hook-wiring predicates (bash lib / core
// hookwiring) and the same session-budget stub. A missing bash or jq FAILS: a skipped differential proves nothing.

func (k *vrKit) installLegacyHook() {
	k.t.Helper()
	for rel, dst := range map[string]string{
		filepath.Join("registry", "verify-registry-hook.sh"): "home/kit/toolbelt/verify-registry-hook.sh",
		filepath.Join("lib", "hook-emit.sh"):                 "home/kit/toolbelt/lib/hook-emit.sh",
	} {
		b, err := os.ReadFile(filepath.Join("testdata", "legacy", rel))
		if err != nil {
			k.t.Fatalf("frozen legacy file missing: %v", err)
		}
		k.write(dst, string(b))
	}
	// the hook execs $here/verify-registry.sh, so the copy installed by installLegacy is rewritten as an executable,
	// under the fork lock (ETXTBSY, testkit/execfile)
	script := filepath.Join(k.kit, "toolbelt", "verify-registry.sh")
	b, err := os.ReadFile(script)
	if err != nil {
		k.t.Fatal(err)
	}
	execfile.Write(k.t, script, string(b))
}

// runLegacyHook runs the frozen hook; its output is the envelope on stdout (the hook exits 0 always).
func (k *vrKit) runLegacyHook(env map[string]string, args ...string) vrResult {
	k.t.Helper()
	if _, err := exec.LookPath("jq"); err != nil {
		k.t.Fatalf("differential: jq not found; the Go hook is NOT proven against verify-registry-hook.sh: %v", err)
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		k.t.Fatalf("differential: bash not found: %v", err)
	}
	cmd := exec.Command(bash, append([]string{filepath.Join(k.kit, "toolbelt", "verify-registry-hook.sh")}, args...)...)
	cmd.Dir = k.root
	cmd.Env = k.legacyEnv(env)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			k.t.Fatalf("legacy hook: %v", err)
		}
		rc = ee.ExitCode()
	}
	return vrResult{out.String(), errb.String(), rc}
}

func (k *vrKit) hookBoth(name string, env map[string]string, args ...string) {
	k.t.Helper()
	legacyRes := k.runLegacyHook(env, args...)
	old := SessionBudgetRunner
	SessionBudgetRunner = stubBudgetRunner
	defer func() { SessionBudgetRunner = old }()
	_, raw, rc := k.runHook(env, args...)
	goRes := vrResult{raw, "", rc}
	if legacyRes != goRes {
		k.t.Errorf("%s %v differs from the legacy hook:\nlegacy rc=%d\n--stdout--\n%s--stderr--\n%s\n    go rc=%d\n--stdout--\n%s",
			name, args, legacyRes.rc, legacyRes.stdout, legacyRes.stderr, goRes.rc, goRes.stdout)
	}
}

func TestRegistryHookDifferential(t *testing.T) {
	for _, sc := range registryScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			k := newVRKit(t)
			k.installLegacy()
			k.installLegacyHook()
			env := sc.build(k)
			k.hookBoth(sc.name, env)
			k.hookBoth(sc.name, env, "--full")
		})
	}
	t.Run("operational-failure", func(t *testing.T) {
		k := newVRKit(t)
		k.installLegacy()
		k.installLegacyHook()
		k.hookBoth("no-targets", nil)
		k.hookBoth("no-targets", nil, "--full")
	})
	t.Run("many-warnings-and-wide-characters", func(t *testing.T) {
		k := newVRKit(t)
		k.installLegacy()
		k.installLegacyHook()
		var rows []string
		for i := 1; i <= 9; i++ {
			n := "ünï" + strings.Repeat("é", 30) + string(rune('a'+i))
			k.blocks(n, 5)
			rows = append(rows, vrRow(string(rune('0'+i)), n, n, "(40 md)"))
		}
		k.targets(vrTable(rows...))
		k.hookBoth("wide", nil)
	})
}
