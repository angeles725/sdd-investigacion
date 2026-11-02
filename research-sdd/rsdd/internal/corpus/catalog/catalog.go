// Package catalog is `rsdd corpus catalog`: the port of templates/gen-catalog.py (kit issue #2535), the generator of
// a corpus's CATALOG.md. It scans <corpus-root>/*.md for block files (`<prefix>-(block|bloque)<N>[-suffix].md`,
// case-sensitive), takes each title from the first `# ` line, sorts the rows by block number and writes
// <corpus-root>/CATALOG.md, then prints `CATALOG.md regenerated: N blocks.`.
//
// Invocation: `rsdd corpus catalog <corpus-root>`. The root is mandatory. The Python generator also accepted no
// argument (or an empty string) and then used the parent of the directory holding the script; that mode only makes
// sense for a script copied under <corpus>/tools/, and the Go binary has no such location, so a missing or empty
// root is a usage error (exit 2) instead of a guess. research-sdd-archive.sh still runs a corpus-local
// tools/gen-catalog.py first and keeps that legacy mode for it.
//
// Exit: 0 written - 1 operational failure (root not writable, a matching name that cannot be read or is not valid
// UTF-8) - 2 usage.
//
// Byte-identical to the Python generator on CATALOG.md, stdout and the exit code. The pattern classes follow
// Python's Unicode-aware str regex semantics: `\d` is category Nd, `\w` is letters, numbers and `_`, `\s` (and the
// strip() of the fallback title) is Python's str.isspace set. The stderr text of a failure differs (Python prints
// a traceback). Declared deviations, none of them visible on a corpus with distinct block numbers and one prefix:
//   - ordering: Python takes the directory in scandir order, which is arbitrary. Go sorts the names bytewise first,
//     so two files with the same block number (p-block1.md, p-block01.md) keep name order, and the subject is the
//     prefix of the first matching name in that order;
//   - decoding: Python decodes a read chunk of the file, so invalid UTF-8 after the title line but inside the same
//     chunk fails there. Go decodes line by line: a file fails only when a line up to and including the title line
//     (all lines, when there is no title) is not valid UTF-8; bytes after the title line are never read;
//   - a matching file name that is not valid UTF-8 fails with exit 1 before CATALOG.md is touched; Python truncated
//     CATALOG.md and then failed to encode the name;
//   - block numbers are compared as decimal strings of any length (Python's int(), without its configurable
//     digit-count limit; a file name cannot hold more than 255 bytes anyway);
//   - Unicode tables come from the Go release instead of the Python one, so a character added to Nd, L or N in one
//     and not yet in the other can classify differently.
//
// Kept on purpose: an unreadable root is treated as empty (pathlib's glob swallows the error), so the write step
// decides the outcome, exactly as in Python.
package catalog

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Run is the command entry point.
func Run(args []string, s cli.Stdio) int {
	if len(args) != 1 || args[0] == "" {
		fmt.Fprintln(s.Err, "usage: rsdd corpus catalog <corpus-root>")
		return cli.ExitUsage
	}
	root := args[0]
	if !filepath.IsAbs(root) {
		root = filepath.Join(s.Cwd, root)
	}
	blocks, err := scan(root)
	if err != nil {
		fmt.Fprintf(s.Err, "rsdd corpus catalog: %v\n", err)
		return cli.ExitOperational
	}
	if err := os.WriteFile(filepath.Join(root, "CATALOG.md"), []byte(render(blocks)), 0o666); err != nil {
		fmt.Fprintf(s.Err, "rsdd corpus catalog: %v\n", err)
		return cli.ExitOperational
	}
	fmt.Fprintf(s.Out, "CATALOG.md regenerated: %d blocks.\n", len(blocks.rows))
	return cli.ExitOK
}

// row is one cataloged block file.
type row struct {
	num   string // decimal, no leading zeros
	name  string
	title string
}

// scanned is the result of reading the root.
type scanned struct {
	subject string
	rows    []row
}

// scan lists root's *.md files in name order, keeps the block files, reads their titles and sorts the rows by
// number (stable, so equal numbers keep name order).
func scan(root string) (scanned, error) {
	entries, _ := os.ReadDir(root) // ReadDir returns names sorted; an unreadable root counts as empty, like pathlib's glob
	var out scanned
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		prefix, num, ok := matchBlock(name)
		if !ok {
			continue
		}
		if !utf8.ValidString(name) {
			return scanned{}, fmt.Errorf("block file name is not valid UTF-8: %q", name)
		}
		title, err := blockTitle(filepath.Join(root, name))
		if err != nil {
			return scanned{}, err
		}
		if out.subject == "" {
			out.subject = prefix
		}
		out.rows = append(out.rows, row{num: num, name: name, title: title})
	}
	sort.SliceStable(out.rows, func(i, j int) bool { return lessNum(out.rows[i].num, out.rows[j].num) })
	return out, nil
}

// render builds CATALOG.md. The header keeps the generator's historical name so the bytes match.
func render(b scanned) string {
	subject := b.subject
	if subject == "" {
		subject = "<subject>"
	}
	var sb strings.Builder
	sb.WriteString("<!-- AUTOGENERATED by research-sdd gen-catalog.py — DO NOT EDIT BY HAND. " +
		"Regenerated by research-sdd-archive.sh (kit generator over the corpus root). -->\n\n")
	fmt.Fprintf(&sb, "# Block catalog — %s\n\n", subject)
	fmt.Fprintf(&sb, "Total: **%d blocks**\n\n", len(b.rows))
	sb.WriteString("| Block | File | Title |\n|-------|------|-------|\n")
	for _, r := range b.rows {
		fmt.Fprintf(&sb, "| %s | [%s](%s) | %s |\n", r.num, r.name, r.name, r.title)
	}
	return sb.String()
}
