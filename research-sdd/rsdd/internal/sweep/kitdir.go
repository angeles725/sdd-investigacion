package sweep

import (
	"fmt"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// resolveKit is `cd -P -- "$_RSDD_SELF/.." && pwd -P`: the physical kit directory.
// A run without --kit finds the kit root without naming a script; the resolver's warnings go to the process's
// stderr (s.Err) in every mode, never into the diagnostics a hook run merges into the context it hands the model.
func resolveKit(o options, s cli.Stdio) (string, error) {
	k := o.kit
	if k == "" {
		root, warns, err := kit.ResolveKitRoot(s.Env)
		for _, w := range warns {
			fmt.Fprintln(s.Err, w)
		}
		if err != nil {
			return "", err
		}
		k = filepath.Clean(root)
	}
	if !filepath.IsAbs(k) {
		k = filepath.Join(s.Cwd, k)
	}
	if r, err := filepath.EvalSymlinks(k); err == nil {
		k = r
	}
	return k, nil
}
