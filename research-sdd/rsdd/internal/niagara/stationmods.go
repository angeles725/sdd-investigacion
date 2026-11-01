package niagara

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
)

// Evidence schema and caps of station-modules.v1 (research-sdd/toolbelt/station-modules.v1.md).
const (
	stationSchema = "station-modules.v1"
	maxJars       = 2000 // JARs read from modules/
	stationProg   = "station-modules"
	stationUsage  = "usage: station-modules [-h] --input BOG --install ROOT --output JSON\n"
	stationHelp   = stationUsage + "\nNiagara N4 station module dependency checker. Read-only: resolves module\n" +
		"aliases and type references from a config.bog and reports missing module-parts\n" +
		"in the install.\n\n" +
		"options:\n" +
		"  -h, --help      show this help message and exit\n" +
		"  --input BOG     config.bog (ZIP-compressed file.xml) or bare XML file\n" +
		"  --install ROOT  Niagara N4 install root directory (contains modules/)\n" +
		"  --output JSON   output JSON evidence file (must not already exist)\n"
)

var stationSpec = argSpec{
	prog: stationProg, usage: stationUsage, help: stationHelp,
	opts: []optDef{{"--input", true}, {"--install", true}, {"--output", true}},
}

// RunStationModules is `rsdd niagara station-modules --input BOG --install ROOT --output JSON`, the port of
// station_modules.py: it resolves the module aliases and type references a station (config.bog, a ZIP holding
// file.xml or bare XML) names and reports which module parts the install's modules/ directory lacks. It emits
// module names, part names and installed part lists only, never a version, vendor, JAR path, slot value or key.
//
// Exit codes: 0 evidence complete (missing_parts may be empty; zero modules is also complete); 1 the bog is
// malformed, unreadable or over a cap, or modules/ could not be indexed (status "failed" JSON is still written);
// 2 the input or install root is absent, not what it must be or a symlink, or the output could not be created
// (no JSON written), or a usage error.
func RunStationModules(args []string, s cli.Stdio) int {
	pa, st := stationSpec.parse(args)
	if st != nil {
		fmt.Fprint(s.Out, st.out)
		fmt.Fprint(s.Err, st.err)
		return st.code
	}
	input, installArg, output := pa.vals["--input"], pa.vals["--install"], pa.vals["--output"]

	h, err := bog.Open(input)
	if err != nil {
		var re *bog.ReadError
		if errors.As(err, &re) && !re.IO {
			fmt.Fprintf(s.Err, "%s: %s: %s\n", stationProg, escapeSurrogates(input), re.Msg)
		} else {
			fmt.Fprintf(s.Err, "%s: I/O error: %s\n", stationProg, errMsg(err))
		}
		return 2
	}
	defer h.Close()

	sum, err := h.SHA256()
	if err != nil {
		fmt.Fprintf(s.Err, "%s: I/O error: %s\n", stationProg, errMsg(err))
		return 2
	}

	// Strip trailing separators: lstat("link/") follows the link.
	root := strings.TrimRight(installArg, "/")
	if root == "" {
		root = "/"
	}
	li, err := os.Lstat(root)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: install root not found: %s\n", stationProg, bog.PyReprPath(root))
		return 2
	}
	if li.Mode()&os.ModeSymlink != 0 {
		fmt.Fprintf(s.Err, "%s: install root is a symbolic link (rejected): %s\n", stationProg, bog.PyReprPath(root))
		return 2
	}
	// stat, not lstat: the type check is on the real target even if the symlink check above were gone.
	di, err := os.Stat(root)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: I/O error: %s\n", stationProg, osErrorText(err, root))
		return 2
	}
	if !di.IsDir() {
		fmt.Fprintf(s.Err, "%s: install root is not a directory: %s\n", stationProg, bog.PyReprPath(root))
		return 2
	}

	doc := inspect(s.Cwd, h, root)
	if doc.ioErr != "" {
		fmt.Fprintf(s.Err, "%s: I/O error: %s\n", stationProg, doc.ioErr)
		return 2
	}
	doc.sha256, doc.size = sum, h.Size
	result := doc.evidence()
	content, err := jsonout.Indented(result)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: cannot encode evidence: %v\n", stationProg, err)
		return cli.ExitOperational
	}
	if err := writeNew(output, content); err != nil {
		fmt.Fprintf(s.Err, "%s: output %s: %s\n", stationProg, escapeSurrogates(output), bog.StrError(err))
		return 2
	}
	if doc.failed {
		return 1
	}
	return 0
}

// errMsg is the strerror-style text of a read failure.
func errMsg(err error) string {
	var re *bog.ReadError
	if errors.As(err, &re) {
		return re.Msg
	}
	return bog.StrError(err)
}

// escapeSurrogates renders a path as Python writes it to stderr (errors="backslashreplace"): each byte that is
// not valid UTF-8 is a lone surrogate there and prints as \udcXX.
func escapeSurrogates(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			fmt.Fprintf(&b, `\udc%02x`, s[i])
		} else {
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	return b.String()
}

// stationDoc is everything the evidence reports.
type stationDoc struct {
	root            string
	sha256          string
	size            int64
	format          bog.Format
	errs            []string
	failed          bool
	ioErr           string // a read that failed after the open: the run ends with exit 2 and no document
	truncated       bool
	modules         map[string]stationModule
	missing         map[string]string
	idx             installIndex
	unresolved      int
	typesUnresolved int
}

type stationModule struct {
	installed, referenced, unresolved []string
}

// inspect reads the station and the install. It never fails: every fault becomes an errors entry of a "failed"
// document, the way the legacy try/except does.
func inspect(cwd string, h *bog.Handle, root string) (doc stationDoc) {
	doc = stationDoc{root: root, modules: map[string]stationModule{}, missing: map[string]string{}}
	lines, format, readErr, truncated, err := readStation(h)
	doc.format, doc.truncated = format, truncated
	if err != nil {
		doc.ioErr = errMsg(err)
		return doc
	}
	if readErr != "" {
		doc.errs, doc.failed = append(doc.errs, readErr), true
		return doc
	}
	defer func() {
		if r := recover(); r != nil {
			doc.errs, doc.failed = append(doc.errs, fmt.Sprintf("parse error: %v", r)), true
		}
	}()

	moduleTypes, unresolved := parseStationRefs(lines)
	doc.unresolved = unresolved
	// An index that cannot be built is reported as such and the check stops: carrying on would report every
	// referenced module as missing from an install that was never read.
	doc.idx = indexInstall(cwd, root)
	if doc.idx.err != "" {
		doc.errs, doc.failed = append(doc.errs, doc.idx.err), true
		return doc
	}
	if doc.idx.truncated {
		doc.errs = append(doc.errs, fmt.Sprintf("install scan truncated at %d JARs (%d total)", maxJars, doc.idx.total))
		doc.truncated = true
	}

	mods := make([]string, 0, len(moduleTypes))
	for m := range moduleTypes {
		mods = append(mods, m)
	}
	sort.Strings(mods)
	for _, mod := range mods {
		var installed []string
		for part, meta := range doc.idx.parts {
			if meta.moduleName == mod {
				installed = append(installed, part)
			}
		}
		sort.Strings(installed)
		referenced := moduleTypes[mod]
		unresolvedTypes := []string{}
		if len(installed) == 0 {
			// The module is not installed at all: its runtime part is missing.
			key := mod + "-rt"
			if _, dup := doc.missing[key]; !dup {
				if len(referenced) > 0 {
					doc.missing[key] = fmt.Sprintf("module %s not installed (type %s referenced)", mod, referenced[0])
				} else {
					doc.missing[key] = fmt.Sprintf("module %s referenced, no part installed", mod)
				}
			}
		} else {
			// The module is installed: a type no part provides is a version or profile mismatch, not a missing
			// part, and is reported apart.
			for _, tn := range referenced {
				provided := false
				for _, part := range installed {
					if doc.idx.parts[part].types[tn] {
						provided = true
						break
					}
				}
				if !provided {
					unresolvedTypes = append(unresolvedTypes, tn)
					doc.typesUnresolved++
				}
			}
		}
		if installed == nil {
			installed = []string{}
		}
		doc.modules[mod] = stationModule{installed: installed, referenced: referenced, unresolved: unresolvedTypes}
	}
	return doc
}

// readStation is _read_bog_fd: the decoded lines of the bog, its format and, when it could not be read, why.
// Anything that starts with "PK" is read as a ZIP, however short. Reads are length-bounded: neither the inflated
// file.xml nor a plaintext file is taken past 32 MiB, and no size field is trusted.
func readStation(h *bog.Handle) (lines []string, format bog.Format, errText string, truncated bool, err error) {
	head, err := h.Head(2)
	if err != nil {
		return nil, bog.FormatUnknown, "", false, err
	}
	if len(head) == 2 && head[0] == 'P' && head[1] == 'K' {
		z, zerr := h.Zip()
		if zerr != nil {
			return nil, bog.FormatUnknown, "not a valid ZIP: " + zerr.Error(), false, nil
		}
		ext := z.ExtractFile(bog.MaxInflate)
		if ext.Err != "" {
			return nil, ext.Format, ext.Err, ext.Truncated, nil
		}
		return ext.Lines(), bog.FormatZip, "", false, nil
	}

	data, err := h.Head(bog.MaxInflate + 1)
	if err != nil {
		return nil, bog.FormatUnknown, "", false, err
	}
	if len(data) > bog.MaxInflate {
		return nil, bog.FormatUnknown,
			fmt.Sprintf("plaintext bog exceeded read cap (%d bytes); file was not parsed", bog.MaxInflate), true, nil
	}
	text := bog.DecodeReplace(data)
	if !strings.HasPrefix(strings.TrimLeftFunc(text, bog.IsSpace), "<") {
		return nil, bog.FormatUnknown, "content is neither a ZIP nor XML", false, nil
	}
	return bog.SplitLines(text), bog.FormatPlaintext, "", false, nil
}

// evidence renders the station-modules.v1 document. The encoder sorts the keys.
func (d stationDoc) evidence() map[string]any {
	modules := make(map[string]any, len(d.modules))
	for name, m := range d.modules {
		modules[jsonText(name)] = map[string]any{
			"installed_parts":  strList(m.installed),
			"types_referenced": strList(m.referenced),
			"types_unresolved": strList(m.unresolved),
		}
	}
	missing := make(map[string]any, len(d.missing))
	for k, v := range d.missing {
		missing[jsonText(k)] = jsonText(v)
	}
	status := "complete"
	if d.failed {
		status = "failed"
	}
	return map[string]any{
		"errors": strList(d.errs),
		"input": map[string]any{
			"format":     string(d.format),
			"sha256":     d.sha256,
			"size_bytes": d.size,
		},
		"install_root": jsonText(d.root),
		"limitations": []any{
			fmt.Sprintf("Install JAR scan capped at %d entries.", maxJars),
			"ZIP file.xml inflate capped at 32 MiB (zip-bomb protection).",
			"Plaintext bog read capped at 32 MiB (zip-bomb defence).",
			"Slot values are never emitted (secrets discipline).",
			"Fix operations are not performed (read-only tool).",
		},
		"missing_parts": missing,
		"modules":       modules,
		"schema":        stationSchema,
		"status":        status,
		"summary": map[string]any{
			"jars_scanned":           d.idx.scanned,
			"jars_skipped_oversized": d.idx.oversized,
			"jars_total":             d.idx.total,
			"missing_parts":          len(d.missing),
			"modules_referenced":     len(d.modules),
			"types_unresolved":       d.typesUnresolved,
			"unresolved_aliases":     d.unresolved,
		},
		"truncated": d.truncated,
	}
}

func strList(items []string) []any {
	out := make([]any, len(items))
	for i, s := range items {
		out[i] = jsonText(s)
	}
	return out
}
