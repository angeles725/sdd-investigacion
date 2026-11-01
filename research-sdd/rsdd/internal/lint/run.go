package lint

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Run is `rsdd lint block`, the port of lint-block.sh + lint_block.py. Exit: 0 clean (or --audit) · 1 findings or
// an empty block in FAIL mode · 2 usage / absent / unreadable / degraded (the legacy contract, not cli's 3).
//
// A run with --pack still needs the Python packs (U3.2, #2393): the packs are exec'd against the lint_block.py
// module as their API. Those runs do the listing here and hand the file list to `python3 lint_block.py`
// unchanged (delegate.go); a run without --pack never touches Python.
func Run(args []string, s cli.Stdio) int {
	audit := false
	var paths, packArgs []string
parse:
	for len(args) > 0 {
		a := args[0]
		switch {
		case a == "--audit":
			audit = true
		case a == "--pack":
			if len(args) < 2 || args[1] == "" || strings.HasPrefix(args[1], "-") {
				fmt.Fprintln(s.Err, "lint-block: --pack needs a name")
				return 2
			}
			packArgs = append(packArgs, "--pack", args[1])
			args = args[1:]
		case strings.HasPrefix(a, "--pack="):
			if v := strings.TrimPrefix(a, "--pack="); v == "" || strings.HasPrefix(v, "-") {
				fmt.Fprintln(s.Err, "lint-block: --pack needs a name")
				return 2
			}
			packArgs = append(packArgs, a)
		case a == "-h" || a == "--help":
			usage(s.Err)
			return 0
		case a == "--":
			paths = append(paths, args[1:]...)
			break parse
		case strings.HasPrefix(a, "-"):
			fmt.Fprintf(s.Err, "lint-block: unknown option: %s\n", a)
			usage(s.Err)
			return 2
		default:
			paths = append(paths, a)
		}
		args = args[1:]
	}
	if len(paths) == 0 {
		usage(s.Err)
		return 2
	}

	var py *pyEngine
	if len(packArgs) > 0 {
		var rc int
		if py, rc = newPyEngine(s); py == nil {
			return rc
		}
		if rc := py.run(s, append(append([]string(nil), packArgs...), "--check-packs"), ""); rc != 0 {
			return 2
		}
	}

	var list strings.Builder
	rcOps := 0
	for _, p := range paths {
		st, err := os.Stat(abs(s, p))
		switch {
		case err == nil && st.IsDir():
			if !audit {
				fmt.Fprintf(s.Err, "lint-block: %s is a directory; FAIL mode takes block files (use --audit for a corpus)\n", p)
				rcOps = 2
				continue
			}
			if !listCorpus(s, p, &list) {
				rcOps = 2
			}
		case err == nil && st.Mode().IsRegular():
			list.WriteString(p + "\n")
		default: // absent, or exists but is neither a directory nor a regular file (`[ -f ]` is false)
			fmt.Fprintf(s.Err, "ABSENT-INPUT: %s does not exist\n", p)
			rcOps = 2
		}
	}

	if list.Len() == 0 {
		if rcOps != 0 {
			fmt.Fprintln(s.Err, "lint-block: nothing was linted (see ABSENT-INPUT / DEGRADED above)")
			return 2
		}
		fmt.Fprintln(s.Out, "SUMMARY files=0 findings=0 — EMPTY-INPUT: no block files in the given paths; nothing was linted")
		return 0
	}

	var files []string
	for _, f := range strings.Split(list.String(), "\n") {
		if f != "" {
			files = append(files, f)
		}
	}
	var rc int
	if py != nil {
		var pa []string
		if audit {
			pa = append(pa, "--audit")
		}
		if rcOps != 0 {
			pa = append(pa, "--partial")
		}
		rc = py.run(s, append(append(pa, packArgs...), "--files-from", "-"), list.String())
	} else {
		rc = lintFiles(s, files, audit, rcOps != 0)
	}
	if rcOps != 0 && rc < 2 {
		rc = 2
	}
	return rc
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage: lint-block.sh [--pack NAME]... <block.md>...        (FAIL mode)")
	fmt.Fprintln(w, "       lint-block.sh --audit <file|dir>...  (report-only; dirs are searched for block files)")
}

func abs(s cli.Stdio, p string) string {
	if filepath.IsAbs(p) || s.Cwd == "" {
		return p
	}
	return filepath.Join(s.Cwd, p)
}

var prunedNames = map[string]bool{"node_modules": true, ".git": true, ".claude": true, ".venv": true, "venv": true, "site-packages": true, ".atl": true}

// listCorpus is the `find | sort | block_file_filter` of lint-block.sh for one directory: it appends the canonical
// block files to list and prints the EMPTY-INPUT / UNCLASSIFIED lines. It reports false when the listing was degraded.
func listCorpus(s cli.Stdio, p string, list *strings.Builder) bool {
	var found []string
	findOK := true
	// `find` does not follow a symlinked root (no -H/-L): a link to a directory lists nothing.
	// A trailing slash resolves the link (filepath.Join would drop it), so `link/` is followed like `find link/`.
	follow := strings.HasSuffix(p, "/")
	if st, err := os.Lstat(abs(s, p)); err == nil && (follow || st.Mode()&fs.ModeSymlink == 0) {
		prefix := p
		if !strings.HasSuffix(prefix, "/") {
			prefix += "/"
		}
		if !walk(abs(s, p), prefix, &found) {
			findOK = false
		}
	}
	lines := kit.SplitLines(strings.Join(found, "\n"))
	sort.Strings(lines)
	good, gerr := kit.FilterBlockFiles(lines, false, "")
	bad, berr := kit.FilterBlockFiles(lines, true, "")
	if !findOK {
		fmt.Fprintf(s.Err, "lint-block: DEGRADED: listing of %s failed (find=1 sort=0 filter=%d/%d); result below is partial\n", p, rcOf(gerr), rcOf(berr))
	}
	if len(good) > 0 {
		for _, f := range good {
			list.WriteString(f + "\n")
		}
	} else {
		fmt.Fprintf(s.Out, "EMPTY-INPUT: %s has no canonical block files\n", p)
	}
	if len(bad) > 0 {
		first := bad
		if len(first) > 3 {
			first = first[:3]
		}
		fmt.Fprintf(s.Out, "UNCLASSIFIED: %d non-canonical .md file(s) under %s were NOT linted (first: %s)\n", len(bad), p, strings.Join(first, " "))
	}
	return findOK
}

func rcOf(err error) int {
	if err != nil {
		return 1
	}
	return 0
}

// walk lists regular `*.md` files below dir (never following symlinks), pruning the names find prunes.
func walk(dir, shown string, out *[]string) bool {
	ents, err := os.ReadDir(dir)
	ok := err == nil
	for _, e := range ents {
		name := e.Name()
		if prunedNames[name] {
			continue
		}
		switch {
		case e.IsDir():
			if !walk(filepath.Join(dir, name), shown+name+"/", out) {
				ok = false
			}
		case e.Type().IsRegular() && strings.HasSuffix(name, ".md"):
			*out = append(*out, shown+name)
		}
	}
	return ok
}

// lintFiles is lint_block.main for a file list, without packs.
func lintFiles(s cli.Stdio, files []string, audit, partial bool) int {
	counts := map[string]int{}
	var cov coverage
	read, empty, unreadable, total, warn, inactive := 0, 0, 0, 0, 0, 0
	for _, path := range files {
		data, err := os.ReadFile(abs(s, path))
		if err != nil {
			fmt.Fprintf(s.Err, "UNREADABLE %s: %s\n", path, pyOSError(err, path))
			unreadable++
			continue
		}
		if msg := utf8Error(data); msg != "" {
			fmt.Fprintf(s.Err, "UNREADABLE %s: %s\n", path, msg)
			unreadable++
			continue
		}
		read++
		text := universalNewlines(string(data))
		if pyStrip(text) == "" {
			empty++
			fmt.Fprintf(s.Out, "EMPTY-INPUT %s\n", path)
			continue
		}
		findings, warns, infos, c := lintText(text)
		cov.selfverifySections += c.selfverifySections
		cov.certHwLive += c.certHwLive
		cov.r6Triggers += c.r6Triggers
		cov.certInline += c.certInline
		for _, i := range infos {
			fmt.Fprintf(s.Out, "INFO %s:%d: %s\n", path, i.line, i.msg)
			inactive++
		}
		for _, w := range warns {
			fmt.Fprintf(s.Out, "WARN %s:%d: %s\n", path, w.line, w.msg)
			warn++
		}
		for _, f := range findings {
			fmt.Fprintf(s.Out, "%s %s:%d: %s\n", f.rule, path, f.line, f.msg)
			counts[f.rule]++
			total++
		}
	}
	mode := "LINT"
	if audit {
		mode = "AUDIT"
	}
	perRule := fmt.Sprintf("R0=%d R3=%d R6=%d", counts["R0"], counts["R3"], counts["R6"])
	fmt.Fprintf(s.Out, "SUMMARY %s files=%d empty=%d unreadable=%d findings=%d warn=%d inactive-waivers=%d %s | inspected: selfverify-sections=%d cert-hw-live-items=%d r6-trigger-clauses=%d cert-inline-items=%d\n",
		mode, read, empty, unreadable, total, warn, inactive, perRule, cov.selfverifySections, cov.certHwLive, cov.r6Triggers, cov.certInline)
	if unreadable > 0 {
		return 2
	}
	switch {
	case read-empty == 0:
		fmt.Fprintln(s.Out, "EMPTY-INPUT: every given file was empty; nothing was linted")
	case total == 0 && partial:
		fmt.Fprintln(s.Out, "PARTIAL: the files read were inspected and no rule fired, but the input was incomplete (see ABSENT-INPUT / DEGRADED above); this is NOT a clean result")
	case total == 0 && empty > 0 && !audit:
		fmt.Fprintf(s.Out, "EMPTY-INPUT: %d empty file(s) in FAIL mode; a new block must have content\n", empty)
	case total == 0:
		fmt.Fprintln(s.Out, "NO-MATCH: files were read and inspected; no rule fired")
	}
	if partial {
		return 2
	}
	if audit {
		return 0
	}
	if total > 0 || empty > 0 {
		return 1
	}
	return 0
}
