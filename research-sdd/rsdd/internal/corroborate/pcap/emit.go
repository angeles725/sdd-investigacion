package pcap

import (
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
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

// which is shutil.which(name, path=search): the first directory holding an executable regular file.
func which(name, search string) (string, bool) {
	for _, d := range strings.Split(search, ":") {
		if d == "" {
			continue
		}
		p := d + "/" + name
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return p, true
		}
	}
	return "", false
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
	py, ok := which("python3", c.pathVar())
	if !ok {
		return refusal("python3 is required to run the manifest tool")
	}
	return helpers.EmitEvidence(helpers.EmitConfig{
		Stage: c.stage, Schema: e.schema, Domain: e.domain,
		InputIdentity: map[string]any{"source": recordMap(c.source), "staged": recordMap(c.staged)},
		Isolation:     map[string]any{"launcher": recordMap(c.bwrap), "profile": profile},
		Limitations:   e.limitations, Errors: e.errors, ManifestSpec: spec,
		ManifestCLI: []string{py, absolute(c.s.Cwd, c.manifestCLI)},
		Destination: c.destination, Timeout: e.timeout,
		Env: c.s.Environ(), Stdout: c.s.Out, Stderr: c.s.Err,
	})
}

func (c *session) pathVar() string {
	if p := envLookup(c.s, "PATH"); p != nil {
		return *p
	}
	return ""
}

// published marks the stage as handed over: there is nothing left to clean up.
func (c *session) published() { c.stage = "" }
