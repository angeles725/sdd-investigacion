package sweep

import (
	"fmt"
	"io"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// resolveKit is `cd -P -- "$_RSDD_SELF/.." && pwd -P`: the physical kit directory.
// A run without --kit finds the kit root without naming a script; the resolver's warnings go to errw.
func resolveKit(o options, s cli.Stdio, errw io.Writer) (string, error) {
	k := o.kit
	if k == "" {
		root, warns, err := kit.ResolveKitRoot(s.Env)
		for _, w := range warns {
			if !o.hook { // a hook run merges stderr into the context it hands the model: the line stays out of it
				fmt.Fprintln(errw, w)
			}
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
