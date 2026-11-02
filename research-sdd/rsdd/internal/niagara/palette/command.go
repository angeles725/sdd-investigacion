// Package palette is `rsdd niagara palette-lexicon-agents`: the palette/lexicon/agent census of an extracted
// N4 module directory (palette-lexicon.v1). It is a faithful port of the former palette_lexicon_agents.py.
package palette

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const (
	tool   = "palette-lexicon-agents"
	schema = "palette-lexicon.v1"

	maxPaletteBytes   = 16 * 1024 * 1024 // per module.palette
	maxLexiconBytes   = 4 * 1024 * 1024  // per .lexicon file
	maxModuleXMLBytes = 1 * 1024 * 1024  // per module.xml
	maxArtifacts      = 500              // artifact subdirs per module

	usage = "usage: palette-lexicon-agents [-h] --input MODULE_DIR --output JSON"
)

// limitations is emitted verbatim in every document.
var limitations = []any{
	fmt.Sprintf("module.palette read capped at %d bytes; a pathological XML tree can still exceed available memory during parse and terminate the process.", maxPaletteBytes),
	fmt.Sprintf(".lexicon read capped at %d bytes per file.", maxLexiconBytes),
	fmt.Sprintf("module.xml read capped at %d bytes.", maxModuleXMLBytes),
	fmt.Sprintf("Artifact subdirs capped at %d per module.", maxArtifacts),
	"Lexicon values are never read or emitted (secrets discipline).",
	"Only '=' key separator recognized; backslash-continuation not supported.",
	"JAR fallback (absent extracted/) is not supported.",
	"*.lexicon files scanned recursively under extracted/ (symlinks not followed).",
	"Duplicate detection is per-file: a key appearing once per file is not flagged even if it appears in multiple .lexicon files (each file is a separate namespace).",
}

// expandAbbrev mimics argparse's unique-prefix matching of long options (--inp for --input).
func expandAbbrev(args []string) []string {
	longs := []string{"--help", "--input", "--output"}
	out := make([]string, len(args))
	for i, a := range args {
		out[i] = a
		if !strings.HasPrefix(a, "--") || len(a) == 2 {
			if a == "--" {
				copy(out[i:], args[i:])
				return out
			}
			continue
		}
		name, val, hasVal := strings.Cut(a, "=")
		var hits []string
		for _, l := range longs {
			if l == name {
				hits = []string{l}
				break
			}
			if strings.HasPrefix(l, name) {
				hits = append(hits, l)
			}
		}
		if len(hits) == 1 {
			out[i] = hits[0]
			if hasVal {
				out[i] += "=" + val
			}
		}
	}
	return out
}

// Run is `rsdd niagara palette-lexicon-agents --input MODULE_DIR --output JSON`.
// Exit 0 complete, 1 an artifact file was malformed (status:failed JSON is still written), 2 I/O or usage error.
func Run(args []string, s cli.Stdio) int {
	var input, output string
	fs := flag.NewFlagSet(tool, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&input, "input", "", "N4 module directory (non-symlink, with artifact subdirs containing extracted/)")
	fs.StringVar(&output, "output", "", "output JSON evidence file (must not already exist)")
	help := fs.Bool("help", false, "")
	fs.BoolVar(help, "h", false, "")
	usageErr := func(msg string) int {
		fmt.Fprintln(s.Err, usage)
		fmt.Fprintf(s.Err, "%s: error: %s\n", tool, msg)
		return cli.ExitUsage
	}
	if err := fs.Parse(expandAbbrev(args)); err != nil {
		msg := err.Error()
		if rest, ok := strings.CutPrefix(msg, "flag provided but not defined: "); ok {
			return usageErr("unrecognized arguments: -" + rest)
		}
		if rest, ok := strings.CutPrefix(msg, "flag needs an argument: -"); ok {
			return usageErr("argument --" + strings.TrimPrefix(rest, "-") + ": expected one argument")
		}
		return usageErr(msg)
	}
	if *help {
		fmt.Fprintln(s.Out, usage)
		return cli.ExitOK
	}
	if fs.NArg() > 0 {
		return usageErr("unrecognized arguments: " + strings.Join(fs.Args(), " "))
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	var missing []string
	for _, n := range []string{"input", "output"} {
		if !set[n] {
			missing = append(missing, "--"+n)
		}
	}
	if len(missing) > 0 {
		return usageErr("the following arguments are required: " + strings.Join(missing, ", "))
	}
	return scan(s, input, output)
}

func abs(cwd, p string) string {
	if strings.HasPrefix(p, "/") || cwd == "" {
		return p
	}
	return strings.TrimRight(cwd, "/") + "/" + p
}

func scan(s cli.Stdio, input, output string) int {
	moduleDir := strings.TrimRight(input, "/")
	if moduleDir == "" {
		moduleDir = "/"
	}
	root := abs(s.Cwd, moduleDir)
	fi, err := os.Lstat(root)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: input not found: %s\n", tool, pyRepr(moduleDir))
		return cli.ExitUsage
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		fmt.Fprintf(s.Err, "%s: input is a symbolic link (rejected): %s\n", tool, pyRepr(moduleDir))
		return cli.ExitUsage
	}
	if !fi.IsDir() {
		fmt.Fprintf(s.Err, "%s: input is not a directory: %s\n", tool, pyRepr(moduleDir))
		return cli.ExitUsage
	}

	names := findArtifacts(root)
	truncated := len(names) > maxArtifacts
	if truncated {
		names = names[:maxArtifacts]
	}
	errs := []any{}
	artifacts := []any{}
	var tPal, tLex, tDup, tAgents int
	for _, n := range names {
		a := collectArtifact(root, n, &errs)
		artifacts = append(artifacts, a)
		tPal += a["palette_count"].(int)
		tLex += a["lexicon_keys"].(int)
		tDup += a["duplicate_bare_keys_count"].(int)
		tAgents += a["agents_count"].(int)
	}
	failed := len(errs) > 0
	status := "complete"
	if failed {
		status = "failed"
	}
	doc := map[string]any{
		"artifacts":   artifacts,
		"errors":      errs,
		"limitations": limitations,
		"schema":      schema,
		"status":      status,
		"summary": map[string]any{
			"agents":              tAgents,
			"artifacts_scanned":   len(artifacts),
			"duplicate_bare_keys": tDup,
			"keys_examined":       tLex,
			"lexicon_keys":        tLex,
			"palette_entries":     tPal,
		},
		"truncated": truncated,
	}
	b, err := jsonout.Indented(doc)
	if err == nil {
		err = writeNew(abs(s.Cwd, output), b)
	}
	if err != nil {
		fmt.Fprintf(s.Err, "%s: output %s: %s\n", tool, output, strerror(err))
		return cli.ExitUsage
	}
	if failed {
		return cli.ExitOperational
	}
	return cli.ExitOK
}

// strerror is the libc text Python's OSError.strerror carries for the errno behind err.
func strerror(err error) string {
	var en syscall.Errno
	if errors.As(err, &en) {
		t := en.Error()
		r, n := utf8.DecodeRuneInString(t)
		return string(unicode.ToUpper(r)) + t[n:]
	}
	return err.Error()
}

// writeNew creates path (O_CREAT|O_EXCL|O_NOFOLLOW) and writes b: a pre-existing file or symlink is refused.
func writeNew(path string, b []byte) error {
	fd, err := fsx.OpenWONew(path)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), path)
	_, werr := f.Write(b)
	_ = f.Close()
	return werr
}

// readBounded reads a regular file through O_NOFOLLOW|O_NONBLOCK without trusting its declared size, up to
// max bytes (one more is read to detect truncation). ok is false for an absent, unreadable, symlink or
// non-regular file.
func readBounded(path string, max int) (data []byte, truncated, ok bool) {
	fd, _, err := fsx.OpenRO(path)
	if err != nil {
		return nil, false, false
	}
	f := os.NewFile(uintptr(fd), path)
	defer func() { _ = f.Close() }()
	data, err = io.ReadAll(io.LimitReader(f, int64(max)+1))
	if err != nil {
		return nil, false, false
	}
	if len(data) > max {
		return data[:max], true, true
	}
	return data, false, true
}

// realpath is os.path.realpath (non-strict): symlinks are resolved as far as the path exists and the rest is
// appended lexically.
func realpath(p string) string {
	p = filepath.Clean(p)
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	parent, base := filepath.Split(p)
	parent = filepath.Clean(parent)
	if parent == p {
		return p
	}
	return filepath.Join(realpath(parent), base)
}

// insideRoot is the containment guard: sub resolves, through real paths, to root or below it.
func insideRoot(root, sub string) bool {
	r, c := realpath(root), realpath(sub)
	return c == r || strings.HasPrefix(c, strings.TrimRight(r, "/")+"/")
}

// sortedNames lists dir in byte order; os.ReadDir already returns entries sorted by filename.
func sortedNames(dir string) ([]os.DirEntry, error) { return os.ReadDir(dir) }

// findArtifacts lists the non-symlink artifact subdirs that hold a non-symlink extracted/ directory.
func findArtifacts(root string) []string {
	ents, err := sortedNames(root)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		art := root + "/" + e.Name()
		if !insideRoot(root, art) {
			continue
		}
		if fi, err := os.Lstat(art); err != nil || fi.Mode()&os.ModeSymlink != 0 || !fi.IsDir() {
			continue
		}
		ext := art + "/extracted"
		if !insideRoot(root, ext) {
			continue
		}
		if fi, err := os.Lstat(ext); err == nil && fi.Mode()&os.ModeSymlink == 0 && fi.IsDir() {
			out = append(out, e.Name())
		}
	}
	return out
}

// findLexicons lists the regular, non-symlink *.lexicon files under ext in walk order (a directory's files
// first, then its subdirectories depth first), as paths relative to ext. Symlinked directories are not
// descended; a directory that cannot be listed is reported through onErr, never dropped silently.
func findLexicons(root, ext string, onErr func(relDir string)) []string {
	var out []string
	var walk func(dir, rel string)
	walk = func(dir, rel string) {
		if !insideRoot(root, dir) {
			return
		}
		ents, err := sortedNames(dir)
		if err != nil {
			if rel == "" {
				onErr(".")
			} else {
				onErr(rel)
			}
			return
		}
		join := func(n string) string {
			if rel == "" {
				return n
			}
			return rel + "/" + n
		}
		for _, e := range ents {
			if e.Type().IsRegular() && strings.HasSuffix(e.Name(), ".lexicon") && insideRoot(root, dir+"/"+e.Name()) {
				out = append(out, join(e.Name()))
			}
		}
		for _, e := range ents {
			if e.IsDir() {
				walk(dir+"/"+e.Name(), join(e.Name()))
			}
		}
	}
	walk(ext, "")
	return out
}

func collectArtifact(root, name string, errs *[]any) map[string]any {
	ext := root + "/" + name + "/extracted"
	addErr := func(format string, a ...any) { *errs = append(*errs, fmt.Sprintf(format, a...)) }

	palCount, palPresent := 0, false
	if p := ext + "/module.palette"; insideRoot(root, p) {
		if raw, trunc, ok := readBounded(p, maxPaletteBytes); ok {
			palPresent = true
			n, err := parsePalette(pyDecode(raw))
			if err != nil {
				addErr("%s/module.palette: %v", name, err)
			} else {
				palCount = n
			}
			if trunc {
				addErr("%s/module.palette: truncated at %d bytes — XML parse failed", name, maxPaletteBytes)
			}
		}
	}

	lexFiles := findLexicons(root, ext, func(rel string) {
		addErr("%s/%s: unreadable directory (os.walk onerror)", name, rel)
	})
	dupKeys := map[string]any{}
	dupCount, keysExamined := 0, 0
	for _, rel := range lexFiles {
		raw, trunc, ok := readBounded(ext+"/"+rel, maxLexiconBytes)
		if !ok {
			addErr("%s/%s: lexicon file unreadable", name, rel)
			continue
		}
		n, dups := parseLexicon(pyDecodeSig(raw))
		keysExamined += n
		if len(dups) > 0 {
			dupKeys[rel] = dups
		}
		dupCount += len(dups)
		if trunc {
			addErr("%s/%s: truncated at %d bytes", name, rel, maxLexiconBytes)
		}
	}

	agents := []any{}
	xmlPresent := false
	if p := ext + "/META-INF/module.xml"; insideRoot(root, p) {
		if raw, trunc, ok := readBounded(p, maxModuleXMLBytes); ok {
			xmlPresent = true
			parsed, err := parseAgents(pyDecode(raw))
			if err != nil {
				addErr("%s/META-INF/module.xml: %v", name, err)
			} else {
				agents = parsed
			}
			if trunc {
				addErr("%s/META-INF/module.xml: truncated at %d bytes", name, maxModuleXMLBytes)
			}
		}
	}

	return map[string]any{
		"agents":                    agents,
		"agents_count":              len(agents),
		"artifact":                  name,
		"duplicate_bare_keys":       dupKeys,
		"duplicate_bare_keys_count": dupCount,
		"keys_examined":             keysExamined,
		"lexicon_files_seen":        len(lexFiles),
		"lexicon_keys":              keysExamined,
		"module_xml_present":        xmlPresent,
		"palette_count":             palCount,
		"palette_present":           palPresent,
	}
}

// pyRepr is Python's repr() of a str, for the stderr messages that quote the input path.
func pyRepr(s string) string {
	q := byte('\'')
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		q = '"'
	}
	var sb strings.Builder
	sb.WriteByte(q)
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && n == 1:
			fmt.Fprintf(&sb, "\\udc%02x", s[i])
		case r == '\\':
			sb.WriteString(`\\`)
		case r == rune(q):
			sb.WriteString(`\` + string(q))
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case r == '\t':
			sb.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&sb, `\x%02x`, r)
		case unicode.IsPrint(r):
			sb.WriteRune(r)
		case r < 0x100:
			fmt.Fprintf(&sb, `\x%02x`, r)
		case r < 0x10000:
			fmt.Fprintf(&sb, `\u%04x`, r)
		default:
			fmt.Fprintf(&sb, `\U%08x`, r)
		}
		i += n
	}
	sb.WriteByte(q)
	return sb.String()
}
