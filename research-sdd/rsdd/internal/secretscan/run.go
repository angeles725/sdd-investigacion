package secretscan

import (
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	engine "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/secretscan"
)

// Run is `rsdd secrets scan [--committed | --files-from <list|->] <target-dir>`: the leaked-secret-value scanner.
// Exit: 0 clean in scope (or only advisory warnings), 1 a high-confidence secret value leaked, 2 bad arguments,
// 3 degraded. The scan itself is internal/core/secretscan, shared with the corpus archive gate.
func Run(args []string, s cli.Stdio) int {
	o, exit, ok := parseArgs(args, s)
	if !ok {
		return exit
	}
	return engine.Run(engine.Request{
		Target:    o.target,
		Cwd:       s.Cwd,
		Committed: o.committed,
		FilesFrom: o.filesFrom,
		Stdin:     s.In,
		Env:       environ(s),
		KitDir:    kitDir(o, s),
	}, s.Out, s.Err)
}

func environ(s cli.Stdio) []string {
	if s.Environ == nil {
		return nil
	}
	return s.Environ()
}

// kitDir is the kit root that holds TARGETS.md: the parent of the shim's directory when the shim passes it, else
// the kit the resolution order finds; "" (no live-install reminder) when neither exists.
func kitDir(o options, s cli.Stdio) string {
	if o.toolbelt != "" {
		tb := o.toolbelt
		if !filepath.IsAbs(tb) {
			tb = filepath.Join(s.Cwd, tb)
		}
		if real, err := filepath.EvalSymlinks(tb); err == nil {
			return filepath.Dir(real)
		}
		return ""
	}
	if p, _, err := kit.ResolveKitScript("TARGETS.md", s.Env); err == nil {
		return filepath.Dir(p)
	}
	return ""
}
