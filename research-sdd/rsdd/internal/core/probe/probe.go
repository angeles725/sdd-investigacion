package probe

import (
	"errors"
	"io"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/reasons"
)

// Error kinds of a *Degraded, tested with errors.Is.
var (
	ErrNotFound         = errors.New("not found")
	ErrOverrideUnusable = errors.New("explicit override is unusable")
	ErrUnknownTool      = errors.New("unknown tool")
)

// Degraded is a typed absence: Tool could not be resolved. Override names the authoritative variable that
// was set but unusable, or is empty when no candidate was usable.
type Degraded struct {
	Tool     string
	Override string
}

func (d *Degraded) Error() string {
	if d.Override != "" {
		return "missing runtime dependency: " + d.Tool + " (" + d.Override + " is set but unusable)"
	}
	return "missing runtime dependency: " + d.Tool
}

// Unwrap returns ErrOverrideUnusable or ErrNotFound.
func (d *Degraded) Unwrap() error {
	if d.Override != "" {
		return ErrOverrideUnusable
	}
	return ErrNotFound
}

// Code is the registry row a caller emits for d.
func (d *Degraded) Code() reasons.Code { return reasons.DegradedMissingRuntimeDependency }

// Emit writes d's degraded line ("degraded: missing runtime dependency: <tool>") to w.
func (d *Degraded) Emit(w io.Writer) error { return reasons.EmitDetail(w, d.Code(), d.Tool) }

// Prober resolves tools against one environment and working directory.
type Prober struct {
	environ []string
	env     map[string]string
	cwd     string
	root    string // prefix of the fixed host paths; empty except in tests
}

// New returns a Prober over environ ("KEY=value" entries, the last one wins) and the working directory
// cwd that relative paths resolve against.
func New(environ []string, cwd string) *Prober {
	env := make(map[string]string, len(environ))
	for _, kv := range environ {
		if k, v, ok := strings.Cut(kv, "="); ok {
			env[k] = v
		}
	}
	return &Prober{environ: environ, env: env, cwd: cwd}
}

func (p *Prober) lookup(key string) (string, bool) {
	v, ok := p.env[key]
	return v, ok
}

// get is "${key:-}": unset reads as empty.
func (p *Prober) get(key string) string { return p.env[key] }

// abs anchors a relative path at the working directory without cleaning it, as the kernel resolves it.
func (p *Prober) abs(path string) string {
	if path == "" || strings.HasPrefix(path, "/") {
		return path
	}
	return p.cwd + "/" + path
}

// isExec is `[ -x path ]`.
func (p *Prober) isExec(path string) bool { return path != "" && accessExec(p.abs(path)) }

// isFile is `[ -f path ]`.
func (p *Prober) isFile(path string) bool {
	fi, err := os.Stat(p.abs(path))
	return path != "" && err == nil && fi.Mode().IsRegular()
}

// isDir is `[ -d path ]`.
func (p *Prober) isDir(path string) bool {
	fi, err := os.Stat(p.abs(path))
	return path != "" && err == nil && fi.IsDir()
}

// globNames is the shell glob dir+prefix*suffix: the matching non-hidden entries of dir in byte order
// (the LC_ALL=C glob order). An empty or unreadable dir matches nothing.
func (p *Prober) globNames(dir, prefix, suffix string) []string {
	ents, _ := os.ReadDir(dir)
	var out []string
	for _, e := range ents {
		n := e.Name()
		if !strings.HasPrefix(n, ".") && len(n) >= len(prefix)+len(suffix) &&
			strings.HasPrefix(n, prefix) && strings.HasSuffix(n, suffix) {
			out = append(out, dir+n)
		}
	}
	return out
}

// LookPath is `command -v name` for an external command (see the package contract).
func (p *Prober) LookPath(name string) (string, error) {
	if path, ok := p.commandV(name); ok {
		return path, nil
	}
	return "", &Degraded{Tool: name}
}

func (p *Prober) commandV(name string) (string, bool) {
	switch {
	case name == "":
		return "", false
	case strings.Contains(name, "/"):
		return name, p.isExec(name) && !p.isDir(name)
	}
	path := p.get("PATH")
	if path == "" {
		return p.searchPATH([]string{p.cwd}, name)
	}
	return p.searchPATH(strings.Split(path, ":"), name)
}

// searchPATH returns the first executable non-directory dir/name, else the first existing non-directory.
func (p *Prober) searchPATH(dirs []string, name string) (string, bool) {
	fallback := ""
	for _, dir := range dirs {
		if dir == "" {
			dir = "."
		}
		cand := strings.TrimSuffix(dir, "/") + "/" + name
		if fi, err := os.Stat(p.abs(cand)); err != nil || fi.IsDir() {
			continue
		}
		if p.isExec(cand) {
			return cand, true
		}
		if fallback == "" {
			fallback = cand
		}
	}
	return fallback, fallback != ""
}
