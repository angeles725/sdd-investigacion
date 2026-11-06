package fidelity

import (
	"fmt"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// toolbeltDir is the directory holding decompile-java.sh and tests/fixtures: --toolbelt, else the resolved kit's.
func toolbeltDir(flagValue string, s cli.Stdio) (string, error) {
	if flagValue != "" {
		return flagValue, nil
	}
	// The resolver's warnings are dropped here: this function runs once per missing flag and a run can need both, so
	// printing them would repeat the line.
	root, _, err := kit.ResolveKitRoot(kit.Getenv(s.Env))
	if err != nil {
		return "", fmt.Errorf("cannot resolve the toolbelt directory (pass --toolbelt DIR or set RESEARCH_SDD_KIT): %w", err)
	}
	return filepath.Join(root, "toolbelt"), nil
}
