//go:build unix && !nodiff

package deploy

import "testing"

// Failure mode "HOME unset": legacy dies under `set -u` while reading $HOME for the default of --home, even though an
// explicit --home follows (the script never reaches its argument loop). Exit 1 and a bash error, nothing written.
// legacy defect (install-trio-go.md "HOME unset"): the Go port answers a typed exit 2.
func TestHomeUnset(t *testing.T) {
	w := newWorld(t)
	delete(w.env, "HOME")
	w.check("install", w.install("--harness", "claude"), 1, "",
		"<ROOT>/kit/install/research-sdd-install.sh: line 1623: HOME: unbound variable\n")
}

// Failure mode "`--home ""`: exit 2": an empty value is a usage error before anything is touched.
func TestEmptyHomeFlag(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.installEmptyHome("--harness", "claude"), 2, "", fromGolden)
}

// Failure mode "pi override relative or `/`: exit 2" (adapters.sh:157). The override applies only when --home equals
// $HOME, which the harness always sets, so the relative case is reachable; the `/` case is not run (it would target
// the filesystem root if the guard ever regressed).
func TestPiOverrideRelativeIsRejected(t *testing.T) {
	for _, name := range []string{"GENTLE_PI_AGENT_HOME", "PI_CODING_AGENT_DIR"} {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t)
			w.env[name] = "relative/agent"
			r := w.install("--harness", "pi", "--dry-run")
			// quirk: the error surfaces inside the profile lookup, so a second, misleading line names an empty profile
			w.check("dry-run", r, 2, "", "rsdd_field: "+name+" must be an absolute path other than / (got 'relative/agent')\n"+
				"research-sdd-install: unknown profile '' for harness 'pi' (valid: claude general)\n")
		})
	}
}

// The override wins over ~/.pi/agent when --home equals $HOME: the whole pi config root moves (inside the scratch home).
func TestPiOverrideRedirectsConfigRoot(t *testing.T) {
	w := newWorld(t)
	w.env["GENTLE_PI_AGENT_HOME"] = w.hp("custom-pi")
	w.check("install", w.install("--harness", "pi"), 0, fromGolden, "")
	if w.blocks("custom-pi/AGENTS.md") != 1 {
		t.Error("the launcher did not land in the overridden agent dir")
	}
}

// Usage errors: an unknown harness and mode conflicts exit 2 before the filesystem is touched.
func TestUsageErrors(t *testing.T) {
	cases := []struct {
		name string
		args []string
		err  string
	}{
		{"unknown harness", []string{"--harness", "bogus"}, "research-sdd-install: unknown harness 'bogus' (known: claude pi gentle-shell all)\n"},
		{"verify with dry-run", []string{"--verify", "--dry-run"}, fromGolden},
		{"yes without uninstall", []string{"--yes"}, fromGolden},
		{"unknown profile", []string{"--profile", "nope", "--harness", "claude"}, "research-sdd-install: unknown profile 'nope' for harness 'claude' (valid: claude general)\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			w.check("run", w.install(c.args...), 2, "", c.err)
		})
	}
}
