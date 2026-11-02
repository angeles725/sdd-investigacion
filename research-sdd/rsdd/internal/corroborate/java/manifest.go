package java

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// The analysis manifest of each engine. corroborate_java.py loaded toolbelt/analysis_manifest.py through
// --manifest-module and called its build_manifest / canonical_bytes / verify_artifacts / _file_identity /
// _atomic_write. Those are ported in internal/core/adapter, so the calls are made in-process (as
// corroborate kaitai does); the manifest module path is still accepted, validated for collisions with the output
// root, and never loaded.

// fileIdentity is the manifest module's _file_identity(path, root): size and "sha256:<hex>" of one stable
// descriptor, and the opened file must live under root when root is not empty.
func fileIdentity(path, root string) (resolved string, size int64, digest string, err error) {
	id, err := fsx.Identity(path, fsx.NoLimit)
	switch {
	case err == nil:
	case errors.Is(err, fsx.ErrOpen):
		return "", 0, "", fail("file identity cannot be opened safely")
	case errors.Is(err, fsx.ErrNotRegular):
		return "", 0, "", fail("file identity is not a regular file")
	case errors.Is(err, fsx.ErrChanged):
		return "", 0, "", fail("file changed while hashing")
	default:
		return "", 0, "", osFailure(err, "")
	}
	if root != "" && id.Resolved != root && !strings.HasPrefix(id.Resolved, strings.TrimRight(root, "/")+"/") {
		return "", 0, "", fail("opened file escapes analysis root")
	}
	return id.Resolved, id.Size, id.SHA256, nil
}

// atomicWriteNew is _atomic_write(path, payload, overwrite=False): a 0600 sibling temp is written and fsynced,
// then linked under the final name (an existing file is refused) and the directory is fsynced.
func atomicWriteNew(path string, payload []byte) error {
	dir, name := filepath.Dir(path), filepath.Base(path)
	tmp, err := os.CreateTemp(dir, "."+name+".*.tmp")
	if err != nil {
		return osFailure(err, dir)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(payload); err != nil {
		_ = tmp.Close()
		return osFailure(err, "")
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return osFailure(err, "")
	}
	if err := tmp.Close(); err != nil {
		return osFailure(err, "")
	}
	if err := os.Link(tmp.Name(), path); err != nil {
		if errors.Is(err, os.ErrExist) {
			return fail("manifest exists; use --overwrite to replace it")
		}
		return osFailure(err, path)
	}
	if err := fsx.SyncDir(dir); err != nil {
		return osFailure(err, dir)
	}
	return nil
}

// canonicalBytes is the manifest module's canonical_bytes.
func canonicalBytes(v any) ([]byte, error) {
	b, err := adapter.CanonicalBytes(v)
	if err != nil {
		return nil, fail("%v", err)
	}
	return b, nil
}

// asSpec round-trips a value through JSON so numbers arrive as json.Number, the form the manifest builder reads
// (a spec file in the original flow).
func asSpec(v any) (any, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var out any
	if err := dec.Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

// manifestInput is everything make_manifest records about one engine run.
type manifestInput struct {
	name      string
	command   []string
	artifacts []boundArtifact
	evidence  []string
	outcome   outcome
	outputs   []outputRecord
}

// boundArtifact is a tool artifact bound to an argv position.
type boundArtifact struct {
	path      string
	argvIndex int
}

// makeManifest is make_manifest: build, write and re-verify engines/<name>/analysis-manifest.v1.json. It returns
// the manifest's path relative to the stage and its identity.
func (e *env) makeManifest(stage string, m manifestInput) (string, string, error) {
	engineRoot := "engines/" + m.name
	errs := []string{}
	if m.outcome.status != "success" {
		errs = append(errs, "adapter status: "+m.outcome.status)
	}
	bound := make([]map[string]any, len(m.artifacts))
	for i, a := range m.artifacts {
		bound[i] = map[string]any{"path": a.path, "argv_index": a.argvIndex}
	}
	outputs := []string{}
	for _, o := range m.outputs {
		outputs = append(outputs, engineRoot+"/output/"+o.path)
	}
	outputs = append(outputs, m.evidence...)
	completeness := "complete"
	if len(errs) > 0 {
		completeness = "partial"
	}
	var exitCode, signal any
	if m.outcome.returncode >= 0 {
		exitCode = m.outcome.returncode
	} else {
		signal = -m.outcome.returncode
	}
	spec := map[string]any{
		"schema_version": "analysis-manifest.v1",
		"input":          map[string]any{"path": "input/target.jar", "detected_type": "Java archive"},
		"tool": map[string]any{"name": m.name, "version": "artifact-bound", "executable": m.command[0],
			"artifacts": bound},
		"argv": m.command, "environment": e.runEnv,
		"run": map[string]any{"started_at": m.outcome.startedAt, "ended_at": m.outcome.endedAt,
			"duration_ms": m.outcome.durationMS, "exit_code": exitCode, "signal": signal},
		"stdout_path": engineRoot + "/stdout.txt", "stderr_path": engineRoot + "/stderr.txt",
		"outputs":  outputs,
		"findings": []any{},
		"limitations": []string{"This adapter provides corroborating static evidence, not source or runtime equivalence.",
			"WSL2 is not a security boundary; use a disposable VM for hostile artifacts."},
		"errors": errs, "completeness": completeness,
		"isolation_profile": adapter.NamedProfiles()["PROFILE_BWRAP_STATIC_NETWORK_DENIED"].Map(),
	}
	norm, err := asSpec(spec)
	if err != nil {
		return "", "", fail("%v", err)
	}
	menv := adapter.Env{Cwd: e.s.Cwd, Get: e.s.Env}
	manifest, err := adapter.BuildManifest(norm, stage, menv)
	if err != nil {
		return "", "", manifestFailure(err)
	}
	payload, err := canonicalBytes(manifest)
	if err != nil {
		return "", "", err
	}
	relative := engineRoot + "/analysis-manifest.v1.json"
	if err := atomicWriteNew(stage+"/"+relative, payload); err != nil {
		return "", "", err
	}
	if err := adapter.VerifyArtifacts(manifest, stage, menv); err != nil {
		return "", "", manifestFailure(err)
	}
	identity, _ := manifest["identity"].(string)
	return relative, identity, nil
}

// manifestFailure carries a manifest error's own text, which is what the script printed for ManifestError.
func manifestFailure(err error) error {
	var pe *adapter.PyError
	if errors.As(err, &pe) {
		return &failure{pe.Msg}
	}
	return &failure{err.Error()}
}
