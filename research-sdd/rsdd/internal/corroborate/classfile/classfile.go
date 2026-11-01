// Package classfile implements `rsdd corroborate classfile <in.jar|in.class>`: one CLASSFILE line read
// straight from the class-file bytes (no javap, nothing executed), the Go port of corroborate_java.py's
// classfile-facts mode that decompile-java.sh calls (kit issue #2419). The Python helper stays as the
// fallback for a host without Go, so the observable contract is the helper's:
//
//	CLASSFILE major=<n|a-b|unknown> lvt=<yes|no|mixed|unknown> classes=N resugar_risk=<yes|no|unknown> unreadable=N partial=N truncated=<none|entry-cap|byte-cap> [reason=facts-truncated:<cap>]
//
// plus, for an input that cannot be read at all, the same field set with every value unknown and
// reason=unreadable-input(<exception class>). Exit 0 whenever a line is printed; 2 for a usage error.
//
// Intended differences from the helper, each pinned by a test:
//   - the usage line names rsdd, not the script;
//   - an entry name that is not valid UTF-8 makes the helper die with a traceback (exit 1); here the exit is
//     1 too, with a one-line typed message;
//   - bzip2- and LZMA-compressed entries (never written by jar/javac) read as corrupt-entry;
//   - the helper's UserWarning for an empty Info-ZIP unicode path field is not printed.
package classfile

import (
	"errors"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	usageLine = "usage: rsdd corroborate classfile <in.jar|in.class>"

	defaultMaxEntries  = 20000
	defaultMaxExpanded = 1 << 30
	defaultMaxClass    = 64 << 20

	envMaxEntries  = "RSDD_CLASSFACTS_MAX_ENTRIES"
	envMaxExpanded = "RSDD_CLASSFACTS_MAX_BYTES"
	envMaxClass    = "RSDD_CLASSFACTS_MAX_CLASS_BYTES"

	truncNone     = "none"
	truncEntryCap = "entry-cap"
	truncByteCap  = "byte-cap"
	unknownFields = "classes=unknown resugar_risk=unknown unreadable=unknown partial=unknown truncated=unknown"
)

// Run is the command: args is the single input path.
func Run(args []string, s cli.Stdio) int {
	if len(args) != 1 {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	maxEntries := envLimit(s, envMaxEntries, defaultMaxEntries)
	maxExpanded := envLimit(s, envMaxExpanded, defaultMaxExpanded)
	maxClass := envLimit(s, envMaxClass, defaultMaxClass)
	records, truncated, err := collect(pyPath(args[0]), maxEntries, maxExpanded, maxClass)
	if errors.Is(err, errCrash) {
		fmt.Fprintf(s.Err, "rsdd: classfile-facts: %v\n", err)
		return cli.ExitOperational
	}
	if err != nil {
		fmt.Fprintf(s.Out, "CLASSFILE major=unknown lvt=unknown %s reason=unreadable-input(%s)\n", unknownFields, errClass(err))
		return cli.ExitOK
	}
	fmt.Fprintln(s.Out, summarize(records, truncated))
	return cli.ExitOK
}

// envLimit reads a positive-integer limit. An unset or empty value is the default; a malformed one (anything
// but ASCII digits, or zero) warns on stderr and falls back to the default, so a bad override never crashes a
// run. A value too large for 64 bits saturates: it can never be exceeded either way.
func envLimit(s cli.Stdio, name string, def uint64) uint64 {
	raw := s.Env(name)
	if raw == "" {
		return def
	}
	v, err := strconv.ParseUint(raw, 10, 64)
	switch {
	case errors.Is(err, strconv.ErrRange):
		v = math.MaxUint64
	case err != nil:
		v = 0
	}
	if v == 0 {
		fmt.Fprintf(s.Err, "WARN: classfile-facts: invalid %s=%s; using default %d\n", name, pyRepr(raw), def)
		return def
	}
	return v
}

// pyPath normalizes a path the way pathlib.Path does before it is used: an empty path is ".", and empty and
// "." components (so a trailing slash) disappear. ".." is kept; it is not resolved lexically.
func pyPath(p string) string {
	parts := strings.Split(p, "/")
	kept := parts[:0]
	for _, c := range parts {
		if c != "" && c != "." {
			kept = append(kept, c)
		}
	}
	out := strings.Join(kept, "/")
	if strings.HasPrefix(p, "/") {
		return "/" + out
	}
	if out == "" {
		return "."
	}
	return out
}

// errClass is the Python exception class name the helper prints for err.
func errClass(err error) string {
	if pe, ok := err.(*pyError); ok {
		return pe.class
	}
	switch {
	case os.IsNotExist(err):
		return "FileNotFoundError"
	case os.IsPermission(err):
		return "PermissionError"
	case errors.Is(err, syscall.EISDIR):
		return "IsADirectoryError"
	case errors.Is(err, syscall.ENOTDIR):
		return "NotADirectoryError"
	}
	return "OSError"
}

// collect reads the facts of every class the input holds, within the limits.
func collect(path string, maxEntries, maxExpanded, maxClass uint64) (records []facts, truncated string, err error) {
	truncated = truncNone
	if f, openErr := os.Open(path); openErr == nil {
		defer f.Close()
		if fi, statErr := f.Stat(); statErr == nil {
			if rec, ok := findEOCD(f, fi.Size()); ok {
				return collectArchive(f, fi.Size(), rec, maxEntries, maxExpanded, maxClass)
			}
		}
	}
	fi, err := os.Stat(path)
	if err != nil {
		return nil, "", err
	}
	if uint64(fi.Size()) > maxClass {
		return []facts{nullFacts()}, truncated, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	return []facts{classFacts(data)}, truncated, nil
}

func collectArchive(f *os.File, size int64, rec eocd, maxEntries, maxExpanded, maxClass uint64) (records []facts, truncated string, err error) {
	truncated = truncNone
	a, err := openArchive(f, size, rec)
	if err != nil {
		return nil, "", err
	}
	names := a.classNames()
	if uint64(len(names)) > maxEntries {
		names, truncated = names[:maxEntries], truncEntryCap
	}
	var spent uint64
	for _, name := range names {
		e := a.byName[name]
		if e.usize > maxExpanded-spent {
			truncated = truncByteCap
			break
		}
		spent += e.usize
		rec, err := entryFacts(a, e, maxClass)
		if err != nil {
			return nil, "", err
		}
		records = append(records, rec)
	}
	return records, truncated, nil
}

func entryFacts(a *archive, e *zipEntry, maxClass uint64) (facts, error) {
	if e.usize > maxClass {
		return nullFacts(), nil
	}
	data, err := a.read(e)
	switch err {
	case nil:
		return classFacts(data), nil
	case errBadEntry:
		return nullFacts(), nil // oversize, corrupt, encrypted, truncated...: counted as unreadable, never a fake fact
	}
	return facts{}, err
}

// summarize aggregates the per-class facts into the CLASSFILE line.
func summarize(records []facts, truncated string) string {
	var (
		classes, risky, unreadable, partial int
		lo, hi                              int
		haveMajor, lvtYes, lvtNo            bool
	)
	for _, r := range records {
		classes++
		if r.majorKnown {
			if haveMajor {
				lo, hi = min(lo, r.major), max(hi, r.major)
			} else {
				lo, hi, haveMajor = r.major, r.major, true
			}
			if r.resugarRisk() {
				risky++
			}
			if r.partial {
				partial++
			}
		} else {
			unreadable++
		}
		if r.lvtKnown {
			lvtYes = lvtYes || r.lvt
			lvtNo = lvtNo || !r.lvt
		}
	}
	major, risk := "unknown", "unknown"
	if haveMajor {
		major, risk = fmt.Sprint(lo), "no"
		if lo != hi {
			major = fmt.Sprintf("%d-%d", lo, hi)
		}
		if risky > 0 {
			risk = "yes"
		}
	}
	lvt := "unknown"
	switch {
	case lvtYes && lvtNo:
		lvt = "mixed"
	case lvtYes:
		lvt = "yes"
	case lvtNo:
		lvt = "no"
	}
	line := fmt.Sprintf("CLASSFILE major=%s lvt=%s classes=%d resugar_risk=%s unreadable=%d partial=%d truncated=%s",
		major, lvt, classes, risk, unreadable, partial, truncated)
	if truncated != truncNone {
		line += " reason=facts-truncated:" + truncated
	}
	return line
}
