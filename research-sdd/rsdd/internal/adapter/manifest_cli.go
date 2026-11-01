package adapter

import (
	"bytes"
	crand "crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// ManifestRun is `rsdd adapter manifest <create|validate|verify> ...`: the analysis_manifest.py CLI.
// Exit 0 on success, 2 for a usage error or any failure (one line on stderr,
// "analysis-manifest: <message>"). Python's uncaught-exception exit 1 is not reproduced: the inputs
// that make it crash (wrongly typed manifest fields) are reported as a ManifestError.
func ManifestRun(args []string, s cli.Stdio) int {
	env := Env{Cwd: s.Cwd, Get: s.Env}
	ns, help, perr := parseArgs(args)
	switch {
	case help:
		_, _ = io.WriteString(s.Out, usageText)
		return 0
	case perr != nil:
		_, _ = io.WriteString(s.Err, usageText+"analysis_manifest.py: error: "+perr.Error()+"\n")
		return 2
	}
	if err := runManifest(&ns, env); err != nil {
		_, _ = io.WriteString(s.Err, "analysis-manifest: "+err.Error()+"\n")
		return 2
	}
	return 0
}

func runManifest(ns *parsed, env Env) error {
	switch ns.command {
	case "create":
		spec, err := loadJSON(ns.spec, env)
		if err != nil {
			return err
		}
		manifest, err := BuildManifest(spec, ns.root, env)
		if err != nil {
			return err
		}
		payload, err := CanonicalBytes(manifest)
		if err != nil {
			return err
		}
		return atomicWrite(ns.output, payload, ns.overwrite, env)
	case "validate":
		manifest, err := loadJSON(ns.manifest, env)
		if err != nil {
			return err
		}
		return ValidateManifest(manifest, env)
	}
	manifest, err := loadJSON(ns.manifest, env)
	if err != nil {
		return err
	}
	return VerifyArtifacts(manifest, ns.root, env)
}

// loadJSON is _load: a UTF-8 text file holding one JSON object. Numbers stay json.Number.
func loadJSON(path string, env Env) (obj, error) {
	b, err := os.ReadFile(env.absPath(path))
	if err != nil {
		return nil, pathErr(err, path)
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, valueError(err.Error())
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, valueError("extra data after the JSON document")
	}
	d, ok := v.(obj)
	if !ok {
		return nil, mfail("JSON root must be an object")
	}
	return d, nil
}

const tempAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789_"

// newTempName is replaced by tests to force a name collision.
var newTempName = tempName

// tempName is tempfile.mkstemp's name: ".<name>.<8 random characters>.tmp".
func tempName(name string) string {
	var r [8]byte
	_, _ = crand.Read(r[:])
	for i := range r {
		r[i] = tempAlphabet[int(r[i])%len(tempAlphabet)]
	}
	return "." + name + "." + string(r[:]) + ".tmp"
}

// atomicWrite is _atomic_write: write a 0600 sibling temp, fsync it, then publish it under the final
// name (replacing it with overwrite, never replacing otherwise) and fsync the directory. The temp
// never outlives the call.
func atomicWrite(path string, payload []byte, overwrite bool, env Env) error {
	parent, _ := realpath(env.absPath(pyParent(pyNorm(path))), false, env.Cwd)
	name := pyName(pyNorm(path))
	final := parent
	if name != "" {
		final = pyJoin(parent, name)
	}
	var tmp string
	var fd int
	for {
		tmp = pyJoin(parent, newTempName(name))
		var err error
		fd, err = createExcl(tmp)
		if err == nil {
			break
		}
		if err != syscall.EEXIST { // a name taken meanwhile: draw another
			return osError(err, tmp)
		}
	}
	defer func() { _ = os.Remove(tmp) }()
	if err := writeAll(fd, payload); err != nil {
		_ = closeFD(fd)
		return osError(err, "")
	}
	if err := syncFD(fd); err != nil {
		_ = closeFD(fd)
		return osError(err, "")
	}
	if err := closeFD(fd); err != nil {
		return osError(err, "")
	}
	if overwrite {
		if err := renameFile(tmp, final); err != nil {
			return linkErr(err, tmp, final)
		}
	} else if err := publishNew(tmp, final); err != nil {
		return err
	}
	if err := fsx.SyncDir(parent); err != nil {
		return pathErr(err, parent)
	}
	return nil
}

// publishFn is replaced by tests to simulate a filesystem without RENAME_NOREPLACE.
var publishFn = fsx.Publish

// publishNew moves tmp to final without replacing an existing final. A filesystem without
// RENAME_NOREPLACE falls back to the Python's hard link and unlink.
func publishNew(tmp, final string) error {
	err := publishFn(tmp, final)
	if err == nil {
		return nil
	}
	if errors.Is(err, fsx.ErrUnavailable) {
		if lerr := os.Link(tmp, final); lerr != nil {
			err = lerr
		} else {
			return nil
		}
	}
	if errors.Is(err, syscall.EEXIST) {
		return mfail("manifest exists; use --overwrite to replace it")
	}
	return linkErr(err, tmp, final)
}

// linkErr renders a two-path OSError: "[Errno N] text: 'old' -> 'new'".
func linkErr(err error, old, new string) error {
	var le *os.LinkError
	if errors.As(err, &le) {
		err = le.Err
	}
	e := osError(err, old)
	if pe, ok := e.(*PyError); ok {
		pe.Msg += fmt.Sprintf(" -> %s", pyRepr(new))
	}
	return e
}
