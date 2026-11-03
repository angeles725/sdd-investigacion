package pcap

import (
	"bytes"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// emission is what a command hands over once its analyzers have run: the domain part of the evidence, the
// error list, the command and run record the analysis manifest describes, and how long each manifest-tool
// call may take.
type emission struct {
	schema      string
	domain      map[string]any
	limitations []string
	errors      []string
	argv        []string // the sandboxed tshark command the manifest records
	run         map[string]any
	timeout     int
}

func recordMap(r fsx.Record) map[string]any {
	return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
}

// emit publishes the evidence: the envelope, the analysis manifest created, validated and verified by the
// manifest tool, then the atomic no-replace rename of the stage to the destination.
func (c *session) emit(e emission) error {
	profile := adapter.NamedProfiles()["PROFILE_BWRAP_PCAP_OFFLINE"].Map()
	status := "complete"
	if len(e.errors) > 0 {
		status = "failed"
	}
	errs := append([]string{}, e.errors...)
	tsharkIdx := 0
	for i, a := range e.argv {
		if a == c.tsharkPath {
			tsharkIdx = i
			break
		}
	}
	env := environMap()
	spec := map[string]any{
		"argv": e.argv, "completeness": status, "environment": env, "errors": errs, "findings": []any{},
		"input":             map[string]any{"detected_type": "network capture (pcap/pcapng)", "path": "input/capture.pcap"},
		"isolation_profile": profile, "limitations": e.limitations, "outputs": []string{e.schema + ".json"},
		"run": e.run, "schema_version": "analysis-manifest.v1",
		"stderr_path": "engine/stderr.txt", "stdout_path": "engine/stdout.txt",
		"tool": map[string]any{
			"artifacts":  []any{map[string]any{"argv_index": tsharkIdx, "path": c.tsharkPath}},
			"executable": c.bwrapPath, "name": "tshark", "version": c.version,
		},
	}
	return helpers.EmitEvidence(helpers.EmitConfig{
		Stage: c.stage, Schema: e.schema, Domain: e.domain,
		InputIdentity: map[string]any{"source": recordMap(c.source), "staged": recordMap(c.staged)},
		Isolation:     map[string]any{"launcher": recordMap(c.bwrap), "profile": profile},
		Limitations:   e.limitations, Errors: e.errors, ManifestSpec: spec,
		ManifestCLI: []string{inProcess, "manifest"},
		Destination: c.destination, Timeout: e.timeout,
		Env: c.s.Environ(), Stdout: c.s.Out, Stderr: c.s.Err, Run: manifestRunner(c.s),
	})
}

// inProcess marks the manifest "CLI" that EmitEvidence invokes: the manifest steps run inside this process through
// core/adapter, so there is no interpreter and no script to resolve (--manifest-cli is accepted and ignored).
const inProcess = "rsdd-in-process"

// manifestVerb runs one analysis-manifest verb (create, validate, verify); tests replace it with a fake tool.
var manifestVerb = adapter.ManifestRun

// manifestRunner executes the analysis-manifest verbs in process; the verb and its arguments follow the marker.
func manifestRunner(s cli.Stdio) func(proc.Spec) (proc.Result, error) {
	return func(spec proc.Spec) (proc.Result, error) {
		var out, errb bytes.Buffer
		inner := s
		inner.In, inner.Out, inner.Err = strings.NewReader(""), &out, &errb
		rc := manifestVerb(spec.Argv[2:], inner)
		return proc.Result{Stdout: out.Bytes(), Stderr: errb.Bytes(), ReturnCode: rc}, nil
	}
}

// published marks the stage as handed over: there is nothing left to clean up.
func (c *session) published() { c.stage = "" }
