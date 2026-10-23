package kit

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Reading is what a derivation saw (kit CLAUDE.md section 7): the outcomes a count of zero could hide.
type Reading int

const (
	ReadEmptyInput Reading = iota // the source has zero bytes
	ReadNoRows                    // content, but no table row at all
	ReadNoTokens                  // table rows exist, none holds a path token (no-match)
	ReadTokens                    // at least one path token
)

// Pair is one `<raw>\t<expanded>` record of target_paths_pairs.
type Pair struct{ Raw, Expanded string }

// Line renders the pair as the bash lib prints it (without the newline).
func (p Pair) Line() string { return p.Raw + "\t" + p.Expanded }

// WarnKind names why a path is not usable by a sweep.
type WarnKind string

const (
	WarnTruncated    WarnKind = "truncated"    // the path contains "..." (a shortened TARGETS.md cell)
	WarnUnresolvable WarnKind = "unresolvable" // not a directory (a non-path token or a moved corpus)
)

// Warning is a typed finding about one path. It never removes the path from the derivation: the caller decides.
type Warning struct {
	Kind WarnKind
	Path string
}

// msgError carries the exact stderr text of the bash helper and the typed sentinel it maps to.
type msgError struct {
	msg string
	is  error
}

func (e *msgError) Error() string { return e.msg }
func (e *msgError) Unwrap() error { return e.is }

var (
	// Form 1 is `/abs/path`; Form 2 is `$RESEARCH_HOME/rest` or `${RESEARCH_HOME}/rest` (the greps of target-paths.sh).
	reAbs = regexp.MustCompile("`/[^`]+`")
	reRH  = regexp.MustCompile("`\\$(\\{RESEARCH_HOME\\}|RESEARCH_HOME)/[^`]+`")
)

// isRowLine is grep -E '^\s*\|': optional whitespace (space, tab, \v, \f, \r) and then a pipe. Prose lines that
// merely mention a path never pass it (CLAUDE.md section 11 (a)).
func isRowLine(l string) bool {
	return strings.HasPrefix(strings.TrimLeft(l, " \t\v\f\r"), "|")
}

// ReadTargets reads a TARGETS.md-like file. An empty name is ErrUsage, a missing or non-regular file is
// ErrAbsentInput, a failed read is ErrUnreadable. The error text is the bash stderr line.
func ReadTargets(path string) (string, error) {
	if path == "" {
		return "", &msgError{"target-paths: called with no argument", ErrUsage}
	}
	s, err := readRegular(path)
	if err != nil {
		return "", &msgError{"target-paths: cannot read " + path, err}
	}
	return s, nil
}

// researchHome is `${RESEARCH_HOME:-$HOME}` with one trailing slash stripped (`${rh%/}`).
func researchHome(getenv Getenv) string {
	rh := getenv("RESEARCH_HOME")
	if rh == "" {
		rh = getenv("HOME")
	}
	return strings.TrimSuffix(rh, "/")
}

// Derive scans src for target tokens in table rows only and reports what it saw. Pairs are sorted (bytewise)
// and unique. Truncated "..." entries and non-path tokens pass through; Classify types them.
func Derive(src string, getenv Getenv) ([]Pair, Reading) {
	if src == "" {
		return nil, ReadEmptyInput
	}
	rh := researchHome(getenv)
	seen := map[string]Pair{}
	rows := 0
	for _, line := range strings.Split(src, "\n") {
		if !isRowLine(line) {
			continue
		}
		rows++
		for _, m := range reAbs.FindAllString(line, -1) {
			p := strings.ReplaceAll(m, "`", "")
			seen[p+"\t"+p] = Pair{p, p}
		}
		for _, m := range reRH.FindAllString(line, -1) {
			raw := strings.ReplaceAll(m, "`", "")
			exp := raw
			if rest, ok := strings.CutPrefix(raw, "${RESEARCH_HOME}/"); ok {
				exp = rh + "/" + rest
			} else if rest, ok := strings.CutPrefix(raw, "$RESEARCH_HOME/"); ok {
				exp = rh + "/" + rest
			}
			seen[raw+"\t"+exp] = Pair{raw, exp}
		}
	}
	pairs := make([]Pair, 0, len(seen))
	for _, p := range seen {
		pairs = append(pairs, p)
	}
	sort.Slice(pairs, func(i, j int) bool { return cLess(pairs[i].Line(), pairs[j].Line()) })
	switch {
	case rows == 0:
		return pairs, ReadNoRows
	case len(pairs) == 0:
		return pairs, ReadNoTokens
	}
	return pairs, ReadTokens
}

// PairsAll is target_paths_pairs: sorted unique pairs.
func PairsAll(src string, getenv Getenv) []Pair {
	p, _ := Derive(src, getenv)
	return p
}

// PathsAll is target_paths_all: sorted unique expanded paths.
func PathsAll(src string, getenv Getenv) []string {
	var out []string
	seen := map[string]bool{}
	for _, p := range PairsAll(src, getenv) {
		if !seen[p.Expanded] {
			seen[p.Expanded] = true
			out = append(out, p.Expanded)
		}
	}
	sort.Slice(out, func(i, j int) bool { return cLess(out[i], out[j]) })
	return out
}

// Classify splits expanded paths the way sweep callers do: "..." paths are truncated (sweep-retros.sh greps
// '\.\.\.'), then non-directories are unresolvable (their `[ -d ] || continue`). isDir is injected. Every input
// path lands in exactly one of usable or warns, in input order.
func Classify(paths []string, isDir func(string) bool) (usable []string, warns []Warning) {
	for _, p := range paths {
		switch {
		case strings.Contains(p, "..."):
			warns = append(warns, Warning{WarnTruncated, p})
		case !isDir(p):
			warns = append(warns, Warning{WarnUnresolvable, p})
		default:
			usable = append(usable, p)
		}
	}
	return usable, warns
}

// IsDirOS is the stat-only isDir for the process edge.
func IsDirOS(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// RC maps an error of NameForRetro or ResolveStateFile back to the bash return code.
func RC(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, ErrNoAncestor), errors.Is(err, ErrStateAmbiguous):
		return 2
	case errors.Is(err, ErrStateUsage):
		return 3
	}
	return 1
}

// physDir is `cd -P p && pwd -P` run from cwd: the symlink-free absolute directory, or false. A relative p is
// joined to cwd, which the caller takes from the cli boundary (Stdio.Cwd); an empty cwd cannot place it.
func physDir(cwd, p string) (string, bool) {
	if !filepath.IsAbs(p) {
		if cwd == "" {
			return "", false
		}
		p = cwd + "/" + p
	}
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", false
	}
	st, err := os.Stat(r)
	if err != nil || !st.IsDir() {
		return "", false
	}
	return r, true
}
