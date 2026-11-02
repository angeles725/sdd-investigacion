package capa

// Rules-directory validation, sandbox bind and identity digest.
//
// The default capa-rules directory lives under /home, which core/adapter's Sandbox blocks for read-only
// inputs. The tool adds ONE explicit, narrowly validated read-only bind of exactly the resolved rules
// directory at /tmp/rsdd/capa-rules (inside the sandbox tmpfs); no parent directory is ever bound.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/user"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
)

// sandboxRulesPath is where the rules directory is bound inside the sandbox.
const sandboxRulesPath = "/tmp/rsdd/capa-rules"

// minYMLCount is the plausibility threshold of a real capa-rules checkout (~1000 files; 50 is conservative).
const minYMLCount = 50

// structuralSubdirs are the capa-rules top-level directories that mark a directory as plausible.
var structuralSubdirs = map[string]bool{
	"nursery": true, "lib": true, "host-interaction": true, "persistence": true, "collection": true, "discovery": true,
}

// walkDirLimit is the number of subdirectories the plausibility walk descends into per directory.
const walkDirLimit = 100

// fail is an error the legacy main() catches (CapaError, AdapterError, ManifestError, OSError, ...): the
// message goes to stderr and the exit code is 2.
type fail struct{ msg string }

func (f *fail) Error() string { return f.msg }

func failf(format string, a ...any) error { return &fail{msg: fmt.Sprintf(format, a...)} }

// crash is an exception the legacy main() does not catch (a Python traceback, exit 1).
type crash struct{ msg string }

func (c *crash) Error() string { return c.msg }

// expandUser is Path.expanduser for a normalized path: "~" and "~user" resolve through $HOME or the passwd
// database; an unresolvable home is the RuntimeError Python lets escape (a crash).
func expandUser(p string, home func() (string, bool)) (string, error) {
	parts := pyParts(p)
	if len(parts) == 0 || !strings.HasPrefix(parts[0], "~") {
		return p, nil
	}
	first := parts[0]
	var dir string
	switch {
	case first == "~":
		h, ok := home()
		if ok {
			dir = h
		} else if u, err := user.Current(); err == nil {
			dir, ok = u.HomeDir, true
		}
		if !ok {
			return "", &crash{"Could not determine home directory."}
		}
	default:
		u, err := user.Lookup(first[1:])
		if err != nil {
			return "", &crash{"Could not determine home directory."}
		}
		dir = u.HomeDir
	}
	dir = strings.TrimRight(dir, "/")
	rest := ""
	if len(parts) > 1 {
		rest = "/" + strings.Join(parts[1:], "/")
	}
	out := dir + rest
	if out == "" {
		out = "/"
	}
	return pyNorm(out), nil
}

// rulesEnv is what the rules checks read from the process.
type rulesEnv struct {
	cwd  string
	home func() (string, bool) // $HOME when set
}

func (e rulesEnv) abs(p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	return strings.TrimRight(e.cwd, "/") + "/" + p
}

// homeDir is os.path.expanduser("~") for the bind-scope guard.
func (e rulesEnv) homeDir() string {
	if h, ok := e.home(); ok {
		return h
	}
	if u, err := user.Current(); err == nil {
		return u.HomeDir
	}
	return "~"
}

// rulesScopeGuard rejects a blocked root or a path too broad to bind (the shape check of core/adapter/helpers).
func rulesScopeGuard(e rulesEnv, resolved string) error {
	err := helpers.AssertSafeBindRoot(helpers.Env{Cwd: e.cwd, Home: e.homeDir()}, resolved)
	var he *helpers.Error
	if errors.As(err, &he) && he.Kind == helpers.KindBindScope {
		return failf("--rules path rejected by bind-scope guard: %s", he.Msg)
	}
	if err != nil {
		return &crash{err.Error()}
	}
	return nil
}

// validateRulesDir validates the --rules directory (fail-closed, in order: symlink, type, scope,
// plausibility) and returns its resolved path. rulesArg is str(Path(--rules)).
func validateRulesDir(e rulesEnv, rulesArg string) (string, error) {
	expanded, err := expandUser(rulesArg, e.homeLookup)
	if err != nil {
		return "", err
	}
	fi, err := os.Lstat(e.abs(expanded))
	if err != nil {
		return "", failf("--rules path does not exist: %s", rulesArg)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return "", failf("--rules must not be a symlink (symlink-to-rules-dir is rejected to prevent redirection to a sensitive path): %s", rulesArg)
	}
	if !fi.IsDir() {
		return "", failf("--rules is not a directory: %s", rulesArg)
	}
	resolved, err := resolve(expanded, false, e.cwd)
	if err != nil {
		return "", &fail{err.Error()}
	}
	if err := rulesScopeGuard(e, resolved); err != nil {
		return "", err
	}
	ymls, structural := countRules(resolved)
	if !(ymls >= minYMLCount || structural) {
		return "", failf("--rules directory does not appear to be a capa-rules directory (found %d .yml files; expected ≥ %d or a known structural subdir like nursery/, lib/, host-interaction/): %s",
			ymls, minYMLCount, resolved)
	}
	return resolved, nil
}

func (e rulesEnv) homeLookup() (string, bool) { return e.home() }

// countRules is the plausibility walk: .yml file count (stopping at the threshold) and whether the top
// level holds a structural subdirectory. Symlinked directories are listed but never entered.
func countRules(root string) (ymls int, structural bool) {
	var walk func(dir string, top bool) bool
	walk = func(dir string, top bool) bool {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return false
		}
		var dirs []string
		for _, ent := range entries {
			isDir := ent.IsDir()
			if ent.Type()&os.ModeSymlink != 0 {
				if st, serr := os.Stat(dir + "/" + ent.Name()); serr == nil && st.IsDir() {
					isDir = true
				}
			}
			if isDir {
				dirs = append(dirs, ent.Name())
				continue
			}
			if strings.HasSuffix(ent.Name(), ".yml") {
				ymls++
			}
		}
		if top {
			for _, d := range dirs {
				if structuralSubdirs[d] {
					structural = true
				}
			}
		}
		if ymls >= minYMLCount || structural {
			return true
		}
		for _, d := range dirs[:min(len(dirs), walkDirLimit)] {
			st, serr := os.Lstat(dir + "/" + d)
			if serr != nil || st.Mode()&os.ModeSymlink != 0 {
				continue
			}
			if walk(dir+"/"+d, false) {
				return true
			}
		}
		return false
	}
	walk(root, true)
	return ymls, structural
}

// bindRules extends a bwrap prefix with the read-only bind of the resolved rules directory, before the
// trailing "--".
func bindRules(prefix []string, resolved string) ([]string, error) {
	if len(prefix) == 0 || prefix[len(prefix)-1] != "--" {
		return nil, failf("bwrap prefix must end with '--' (produced by adapter_core.sandbox())")
	}
	out := append([]string{}, prefix[:len(prefix)-1]...)
	return append(out, "--dir", sandboxRulesPath, "--ro-bind", resolved, sandboxRulesPath, "--"), nil
}

// rulesPathDigest is "sha256:" over the sorted relative paths of every entry named *.yml (files,
// directories and symlinks alike; symlinked directories are not entered), joined by newlines.
func rulesPathDigest(root string) (string, error) {
	var paths []string
	var walk func(dir, rel string) error
	walk = func(dir, rel string) error {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return nil // pathlib's glob ignores unreadable directories
		}
		for _, ent := range entries {
			name := ent.Name()
			if strings.HasSuffix(name, ".yml") {
				if !utf8.ValidString(name) {
					return &crash{"UnicodeEncodeError: surrogates not allowed"}
				}
				paths = append(paths, rel+name)
			}
			if ent.IsDir() {
				if err := walk(dir+"/"+name, rel+name+"/"); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := walk(root, ""); err != nil {
		return "", err
	}
	sort.Strings(paths)
	sum := sha256.Sum256([]byte(strings.Join(paths, "\n")))
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}
