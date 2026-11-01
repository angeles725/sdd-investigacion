package niagara

import (
	"errors"
	"fmt"
	"os"
	"sort"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
)

// Evidence schema and caps of bog-nav.v1 (research-sdd/toolbelt/bog-nav.v1.md).
const (
	bogNavSchema  = "bog-nav.v1"
	maxComponents = 50_000 // component list cap, truncation is visible
	maxLinks      = 20_000 // link list cap, truncation is visible
)

// RunBogNav is `rsdd niagara bog-nav --input BOG --output JSON`, the port of bog_nav.py: it reads a Niagara N4
// config.bog (a ZIP holding file.xml, or bare Baja XML) and writes key-sorted JSON structure evidence: the
// component tree (paths, types, handles, modules), the link list with sourceOrd handles resolved to component
// paths, and the module prefix map. It never emits a slot value (a config.bog may hold credentials).
//
// Exit codes: 0 evidence complete (an empty bog is complete with zero components); 1 the file exists but its
// content is malformed or over a cap (status "failed" JSON is still written); 2 input or output I/O refused
// (absent, not a regular file, symlink, output already present) or a usage error, and no JSON is written.
func RunBogNav(args []string, s cli.Stdio) int {
	p, st := parseArgs(args)
	if st != nil {
		fmt.Fprint(s.Out, st.out)
		fmt.Fprint(s.Err, st.err)
		return st.code
	}

	file, err := bog.ReadFile(p.input)
	if err != nil {
		var re *bog.ReadError
		if errors.As(err, &re) && re.IO {
			fmt.Fprintf(s.Err, "%s: I/O error: %s\n", progName, re.Msg)
		} else if errors.As(err, &re) {
			fmt.Fprintf(s.Err, "%s: %s: %s\n", progName, p.input, re.Msg)
		} else {
			fmt.Fprintf(s.Err, "%s: I/O error: %v\n", progName, err)
		}
		return 2
	}

	ev, failed := buildEvidence(file)
	content, err := jsonout.Indented(ev)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: cannot encode evidence: %v\n", progName, err)
		return cli.ExitOperational
	}
	if err := writeNew(p.output, content); err != nil {
		fmt.Fprintf(s.Err, "%s: output %s: %s\n", progName, p.output, bog.StrError(err))
		return 2
	}
	if failed {
		return 1
	}
	return 0
}

// buildEvidence turns one read .bog into the bog-nav.v1 document and reports whether its status is "failed".
// Truncation by the component or link caps is a visibility note, not a failure.
func buildEvidence(file bog.File) (map[string]any, bool) {
	ext := bog.Extract(file.Data, bog.MaxInflate)

	errs := []string{}
	components := []any{}
	links := []any{}
	prefixes := map[string]string{}
	truncated := ext.Truncated

	if ext.Err != "" {
		errs = append(errs, ext.Err)
	} else {
		st := bog.Parse(ext.Lines())
		prefixes = st.Prefixes

		all := st.Components()
		sort.SliceStable(all, func(i, j int) bool { return all[i].Path < all[j].Path })
		if len(all) > maxComponents {
			all = all[:maxComponents]
			truncated = true
			errs = append(errs, fmt.Sprintf("component list truncated at %d entries", maxComponents))
		}
		for _, c := range all {
			components = append(components, map[string]any{
				"handle": c.Handle, "module": c.Module, "path": c.Path, "type": c.Type,
			})
		}

		rows := make([]any, 0, len(st.Links))
		for _, lk := range st.Links {
			rows = append(rows, linkRow(lk, st))
		}
		if len(rows) > maxLinks {
			rows = rows[:maxLinks]
			truncated = true
			errs = append(errs, fmt.Sprintf("link list truncated at %d entries", maxLinks))
		}
		links = rows
	}

	failed := ext.Err != ""
	status := "complete"
	if failed {
		status = "failed"
	}
	return map[string]any{
		"components": components,
		"errors":     errs,
		"input": map[string]any{
			"format":     string(ext.Format),
			"sha256":     file.SHA256,
			"size_bytes": file.Size,
		},
		"limitations": []string{
			fmt.Sprintf("Component list capped at %d entries.", maxComponents),
			fmt.Sprintf("Link list capped at %d entries.", maxLinks),
			"ZIP file.xml inflate capped at 32 MiB (zip-bomb protection).",
			"Slot values are never emitted (secrets discipline).",
		},
		"links":  links,
		"schema": bogNavSchema,
		"status": status,
		"summary": map[string]any{
			"components": len(components),
			"links":      len(links),
			"prefixes":   prefixes,
		},
		"truncated": truncated,
	}, failed
}

// linkRow renders one link the way the legacy output does, including its "None" for an absent slot name and its
// "?" / "h:<handle>" placeholders for a source that did not resolve.
func linkRow(lk bog.Link, st *bog.Structure) map[string]any {
	var src *bog.Comp
	if lk.SrcHandle != nil {
		src, _ = st.Lookup(*lk.SrcHandle)
	}
	srcPath := "?"
	switch {
	case src != nil:
		srcPath = src.Path
	case lk.SrcHandle != nil && *lk.SrcHandle != "":
		srcPath = "h:" + *lk.SrcHandle
	}
	return map[string]any{
		"link_name":    lk.Name,
		"source":       srcPath + "." + orNone(lk.SrcSlot),
		"src_resolved": src != nil,
		"target":       lk.ContainerPath + "." + orNone(lk.TgtSlot),
	}
}

func orNone(s *string) string {
	if s == nil {
		return "None"
	}
	return *s
}

// writeNew creates path exclusively (no symlink, no overwrite, mode 0600) and writes content in full.
func writeNew(path string, content []byte) error {
	fd, err := fsx.OpenWONew(path)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), path)
	_, werr := f.Write(content)
	cerr := f.Close()
	if werr != nil {
		return werr
	}
	return cerr
}
