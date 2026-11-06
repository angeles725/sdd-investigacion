package fidelity

import (
	"fmt"
	"path/filepath"
	"sync"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// toolbeltLookup returns the directory holding decompile-java.sh and tests/fixtures: --toolbelt, else the resolved
// kit's. A run can need it twice (the fixtures, then the decompiler), so the kit is resolved at most once per run
// and the resolver's warnings are printed once, on the process's stderr.
func toolbeltLookup(flagValue string, s cli.Stdio) func() (string, error) {
	return sync.OnceValues(func() (string, error) {
		if flagValue != "" {
			return flagValue, nil
		}
		root, warns, err := kit.ResolveKitRoot(kit.Getenv(s.Env))
		for _, w := range warns {
			fmt.Fprintln(s.Err, w)
		}
		if err != nil {
			return "", fmt.Errorf("cannot resolve the toolbelt directory (pass --toolbelt DIR or set RESEARCH_SDD_KIT): %w", err)
		}
		return filepath.Join(root, "toolbelt"), nil
	})
}
