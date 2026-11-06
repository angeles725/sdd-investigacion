package budget

import (
	"fmt"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// toolbeltDir is the directory holding lib/session-budget-pi.mjs: the flag, else the resolved kit's.
func (m *meter) toolbeltDir() string {
	if m.toolbelt != "" {
		return m.toolbelt
	}
	root, warns, err := kit.ResolveKitRoot(kit.Getenv(m.s.Env))
	for _, w := range warns {
		fmt.Fprintln(m.s.Err, w)
	}
	if err != nil {
		return ""
	}
	return filepath.Join(root, "toolbelt")
}
