package native

import (
	"runtime"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

const (
	schema       = "native-static.v1"
	manifestPath = "engine/analysis-manifest.v1.json"
)

// limitations are disclosed in both the report and the manifest.
var limitations = []string{
	"radare2 aaa is heuristic and can miss or over-identify functions.",
	"The trusted analyzer can read the host filesystem through Bubblewrap's read-only root bind.",
	"Bubblewrap on WSL2 reduces filesystem and network exposure but is not a hostile-sample security boundary; use a disposable VM.",
}

// record is the {path,size,sha256} identity of one file.
func record(r fsx.Record) map[string]any {
	return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
}

// outcome is the three-way evidence status.
func outcome(errs []string, truncated bool) string {
	switch {
	case len(errs) > 0:
		return "failed"
	case truncated:
		return "partial"
	}
	return "complete"
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// manifestSpec is the analysis-manifest.v1 spec of the run: the sandbox command, the staged analyzer bound to
// its argv slot, the captured streams and the single published output.
type manifestSpec struct {
	version       string
	bwrap         string
	command       []string
	env           []envVar
	run           map[string]any
	errs          []string
	completeness  string
	r2ArgvIndex   int
	isolationName map[string]any
}

func (m manifestSpec) value() map[string]any {
	env := map[string]any{}
	for _, e := range m.env {
		env[e.k] = e.v
	}
	return map[string]any{
		"schema_version": adapter.SchemaVersion,
		"input":          map[string]any{"path": "input/target.bin", "detected_type": nil},
		"tool": map[string]any{
			"name": "radare2", "version": m.version, "executable": m.bwrap,
			"artifacts": []any{map[string]any{"path": "engine/r2", "argv_index": m.r2ArgvIndex}},
		},
		"argv": m.command, "environment": env, "run": m.run,
		"stdout_path": "engine/stdout.txt", "stderr_path": "engine/stderr.txt",
		"outputs": []any{"engine/functions.json"}, "findings": []any{},
		"limitations": limitations, "errors": nonNil(m.errs), "completeness": m.completeness,
		"isolation_profile": m.isolationName,
	}
}

// evidence is everything native-static.v1.json reports.
type evidence struct {
	cfg                config
	source, staged     fsx.Record
	bwrap              fsx.Record
	r2Source, r2Staged fsx.Record
	version            string
	inner              []string
	run                map[string]any
	identity           any
	profile            map[string]any
	functions          []map[string]any
	total              int
	truncated          bool
	errs               []string
}

func (e evidence) value() map[string]any {
	return map[string]any{
		"schema": schema, "status": outcome(e.errs, e.truncated),
		"input":     map[string]any{"source": record(e.source), "staged": record(e.staged)},
		"runtime":   map[string]any{"go": runtime.Version(), "kernel": kernelRelease()},
		"isolation": map[string]any{"launcher": record(e.bwrap), "profile": e.profile},
		"engine": map[string]any{
			"name": "radare2", "version": e.version,
			"launcher": map[string]any{"source": record(e.r2Source), "staged": record(e.r2Staged)},
			"argv":     e.inner,
			"run":      map[string]any{"exit_code": e.run["exit_code"], "signal": e.run["signal"]},
			"manifest": manifestPath, "manifest_identity": e.identity,
		},
		"functions": e.functions,
		"counts":    map[string]any{"functions_total": e.total, "functions_emitted": len(e.functions)},
		"caps": map[string]any{"timeout_seconds": e.cfg.timeout, "max_bytes": e.cfg.maxBytes,
			"max_files": e.cfg.maxFiles, "max_functions": e.cfg.maxFunctions},
		"truncated":   map[string]any{"functions": e.truncated},
		"limitations": limitations, "errors": nonNil(e.errs),
	}
}
