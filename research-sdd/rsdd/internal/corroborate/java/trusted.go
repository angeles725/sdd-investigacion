package java

import (
	"errors"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// DefaultPins are the SHA-256 digests the three decompiler JARs must match unless <NAME>_SHA256 overrides them.
// They were DEFAULT_PINS in corroborate_java.py; toolbelt/DEPENDENCIES.md names this table as their home.
var DefaultPins = map[string]string{
	"vineflower": "1dfcfe974395734fa467ce620661c7623d05ba83670de0529b1fbd63ff548b9d",
	"cfr":        "f686e8f3ded377d7bc87d216a90e9e9512df4156e75b06c655a16648ae8765b2",
	"procyon":    "821da96012fc69244fa1ea298c90455ee4e021434bc796d3b9546ab24601b779",
}

func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// stageTrustedArtifact is stage_trusted_artifact: the decompiler JAR copied through one descriptor into the
// stage, hashed on the way, and kept only if its digest equals the trusted pin. An empty value means the engine
// is unavailable (nil record, no error).
func (e *env) stageTrustedArtifact(name, value, stage string) (map[string]any, error) {
	if value == "" {
		return nil, nil
	}
	pin, set := e.lookup(strings.ToUpper(name) + "_SHA256")
	if !set {
		pin = DefaultPins[name]
	}
	pin = strings.TrimPrefix(pin, "sha256:")
	if !isHex64(pin) {
		return nil, fail("%s trusted SHA-256 pin is absent or invalid", name)
	}
	rel := "trusted-tools/" + name + ".jar"
	src, staged, err := fsx.StageFile(value, stage+"/"+rel, rel, 0o400, fsx.NoLimit)
	if err != nil {
		return nil, e.trustedFailure(name, err)
	}
	if src.SHA256 != "sha256:"+pin {
		// StageFile has already removed nothing the pin could have kept: the private copy is dropped here so an
		// unpinned JAR never sits in the stage.
		return nil, fail("%s SHA-256 does not match trusted pin", name)
	}
	return map[string]any{
		"schema": "trusted-tool-copy.v1",
		"source": map[string]any{"path": src.Path, "size": src.Size, "sha256": src.SHA256},
		"staged": map[string]any{"path": staged.Path, "size": staged.Size, "sha256": staged.SHA256},
	}, nil
}

// trustedFailure maps the staging helper's typed errors to the refusals the script printed.
func (e *env) trustedFailure(name string, err error) error {
	switch {
	case errors.Is(err, fsx.ErrSourceOpen):
		return fail("%s source cannot be opened safely", name)
	case errors.Is(err, fsx.ErrSourceNotRegular):
		return fail("%s source is not regular", name)
	case errors.Is(err, fsx.ErrSourceChanged):
		return fail("%s source changed while copying", name)
	case errors.Is(err, fsx.ErrStagedMismatch):
		return fail("%s private copy verification failed", name)
	}
	return osFailure(err, "")
}
