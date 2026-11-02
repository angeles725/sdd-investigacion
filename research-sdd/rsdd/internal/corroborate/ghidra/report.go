package ghidra

import (
	"fmt"
	"runtime"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

const (
	schema       = "ghidra-corroboration.v1"
	manifestFile = "analysis-manifest.v1.json"
)

// record is the {path,size,sha256} identity of one file.
func record(r fsx.Record) map[string]any {
	return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// runRecord is the run dict shared by the manifest spec and the report: wall-clock stamps, duration and how the
// process ended (an exit code, or the signal that killed it).
func runRecord(started, ended time.Time, rc int) map[string]any {
	m := map[string]any{
		"started_at": isoZ(started), "ended_at": isoZ(ended), "duration_ms": ended.Sub(started).Milliseconds(),
		"exit_code": nil, "signal": nil,
	}
	if rc >= 0 {
		m["exit_code"] = rc
	} else {
		m["signal"] = -rc
	}
	return m
}

// isoZ is datetime.isoformat() of a UTC time with "Z" for "+00:00": microseconds appear only when non-zero.
func isoZ(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05Z")
	}
	return fmt.Sprintf("%s.%06dZ", t.Format("2006-01-02T15:04:05"), t.Nanosecond()/1000)
}

// limitationsFor are the disclosed epistemic limits; the last applies only to the test-only launcher.
func limitationsFor(isolated bool) []string {
	l := []string{
		"Listed launch-chain files, exporter, Java, and Bubblewrap have byte provenance; Bubblewrap executes from its staged FD and argv[0] binds that staged artifact; the read-only remainder of Ghidra and JDK trees is unbound.",
		"Ghidra parses untrusted input in-process; Bubblewrap is not a hostile-parser boundary.",
	}
	if !isolated {
		l = append(l, "TEST ONLY: the untrusted Bubblewrap launcher does not establish an isolation claim.")
	}
	return l
}

// evidence is everything report.json reports.
type evidence struct {
	cfg          config
	source       fsx.Record
	staged       fsx.Record
	bwrap        fsx.Record // the staged launcher
	provenance   []map[string]any
	version      string
	inner        []string
	run          map[string]any
	isolated     bool
	errs         []string
	completeness string
}

func (e evidence) report() map[string]any {
	c := e.cfg
	return map[string]any{
		"schema": schema, "status": e.completeness,
		"input":      map[string]any{"source": record(e.source), "staged": record(e.staged)},
		"provenance": e.provenance,
		"ghidra":     map[string]any{"version": e.version, "argv": e.inner, "manifest": manifestFile},
		"run":        map[string]any{"exit_code": e.run["exit_code"], "signal": e.run["signal"]},
		"caps": map[string]any{"wall_seconds": c.timeout, "analysis_seconds": c.analysisTimeout,
			"diagnostic_bytes": c.maxDiagnostic, "output_bytes": c.maxOutput, "files": c.maxFiles,
			"functions": c.maxFunctions, "strings": c.maxStrings, "references": c.maxReferences,
			"string_chars": c.maxStringChars, "heap_mb": c.heapMB, "cpus": c.cpus},
		"isolation": map[string]any{"launcher": record(e.bwrap), "network_access": !e.isolated, "target_execution": false,
			"read_only_host_root": e.isolated, "new_session": e.isolated, "synthetic_user_state": e.isolated},
		"runtime":     map[string]any{"go": runtime.Version(), "kernel": kernelRelease()},
		"limitations": limitationsFor(e.isolated), "errors": nonNil(e.errs),
	}
}

// manifestSpec is the analysis-manifest.v1 spec: the sandbox command, the bound tools tied to their argv slots,
// the captured streams and the published outputs.
func manifestSpec(ev evidence, sb sandbox, outputs []string, profile map[string]any) map[string]any {
	env := map[string]any{}
	for _, e := range sb.env {
		env[e.k] = e.v
	}
	var artifacts []any
	for _, logical := range sb.bound {
		artifacts = append(artifacts, map[string]any{"path": logical, "argv_index": indexOf(sb.command, logical)})
	}
	return map[string]any{
		"schema_version": "analysis-manifest.v1",
		"input":          map[string]any{"path": "input/target.bin", "detected_type": nil},
		"tool":           map[string]any{"name": "Ghidra", "version": ev.version, "executable": sb.command[0], "artifacts": artifacts},
		"argv":           sb.command, "environment": env, "run": ev.run,
		"stdout_path": "logs/stdout.txt", "stderr_path": "logs/stderr.txt",
		"outputs": outputs, "findings": []any{}, "limitations": limitationsFor(ev.isolated),
		"errors": nonNil(ev.errs), "completeness": ev.completeness, "isolation_profile": profile,
	}
}

// indexOf is list.index: the first element equal to s.
func indexOf(list []string, s string) int {
	for i, v := range list {
		if v == s {
			return i
		}
	}
	return -1
}
