// Package kitroot resolves the research-sdd directory (the parent of the Go module root) for tests that read kit
// files outside the module: toolbelt/, templates/, install/ and TARGETS.md.
//
// gremlins copies only the module into each mutant's work dir, so a relative "../../toolbelt" read fails in every
// mutant and reads as KILLED (kit issue #2592). `make teeth` therefore exports RSDD_TEST_RESEARCH_SDD with the
// absolute path; with the variable unset the path is derived from the current directory (the package dir under test).
// A directory that cannot be found is a test FAILURE naming the variable, never a skip.
package kitroot

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// EnvVar names the variable that overrides the in-tree research-sdd path.
const EnvVar = "RSDD_TEST_RESEARCH_SDD"

// Dir returns the research-sdd directory, failing the test when it cannot be found.
func Dir(tb testing.TB) string {
	tb.Helper()
	d, err := lookup()
	if err != nil {
		tb.Fatalf("kitroot: %v", err)
	}
	return d
}

// Unresolved is the directory Must returns when the research-sdd directory cannot be found. It never exists, and its
// name carries the cause, so a test that reads below it fails with "no such file ... set RSDD_TEST_RESEARCH_SDD".
const Unresolved = "/kitroot-unresolved-set-" + EnvVar + "-to-the-research-sdd-directory"

// Must is Dir for package-level variables, which have no testing.TB to fail. It must not panic: a test binary
// re-executes itself as a helper process with a scrubbed environment (no EnvVar), and an init-time panic would kill
// that child before it ran a line of its own. An unresolvable directory therefore yields Unresolved, so every read
// below it fails naming EnvVar instead of reading a wrong path.
func Must() string {
	d, err := lookup()
	if err != nil {
		return Unresolved
	}
	return d
}

// Path joins elem onto Dir.
func Path(tb testing.TB, elem ...string) string {
	tb.Helper()
	return filepath.Join(append([]string{Dir(tb)}, elem...)...)
}

// lookup reads EnvVar and the working directory. It uses filepath.Abs and syscall.Getenv, not os.Getwd / os.Getenv:
// archtest bans those two outside cli/stdio.go, and this package is test support that has no Stdio to take them from.
func lookup() (string, error) {
	wd, err := filepath.Abs(".")
	if err != nil {
		return "", fmt.Errorf("cannot read the working directory: %v (set %s)", err, EnvVar)
	}
	env, _ := syscall.Getenv(EnvVar)
	return resolve(env, wd)
}

// resolve is lookup without the ambient reads: env is the value of EnvVar, wd the directory to climb from.
func resolve(env, wd string) (string, error) {
	if env != "" {
		st, err := os.Stat(env)
		if err != nil || !st.IsDir() {
			return "", fmt.Errorf("%s=%q is not a directory", EnvVar, env)
		}
		return env, nil
	}
	mod, err := moduleRoot(wd)
	if err != nil {
		return "", fmt.Errorf("%v; set %s to the research-sdd directory", err, EnvVar)
	}
	rs := filepath.Dir(mod)
	// The kit marker: a module-only copy (gremlins' work dir) has a parent, but no toolbelt/ in it.
	if st, err := os.Stat(filepath.Join(rs, "toolbelt")); err != nil || !st.IsDir() {
		return "", fmt.Errorf("the module at %s is not inside a research-sdd tree (no %s); set %s to the research-sdd directory",
			mod, filepath.Join(rs, "toolbelt"), EnvVar)
	}
	return rs, nil
}

// moduleRoot climbs from wd to the nearest directory holding a go.mod.
func moduleRoot(wd string) (string, error) {
	for d := wd; ; {
		_, err := os.Stat(filepath.Join(d, "go.mod"))
		if err == nil {
			return d, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("cannot stat %s: %v", filepath.Join(d, "go.mod"), err)
		}
		up := filepath.Dir(d)
		if up == d {
			return "", fmt.Errorf("no go.mod found above %s", wd)
		}
		d = up
	}
}
