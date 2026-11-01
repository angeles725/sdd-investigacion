package corpus

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// archiveDiscover resolves the state file and the corpus directory and prints the banner. done is true when the run
// ends here (nothing to archive, unknown focus, unresolvable state).
func (e *archiveEnv) archiveDiscover() (code int, done bool) {
	var state string
	var err error
	if e.focus != "" {
		state, err = kit.ResolveStateFile(e.target, kit.ResolveOptions{FocusSet: true, Focus: e.focus})
		if errors.Is(err, kit.ErrStateAbsent) {
			if len(e.archiveListState(e.target)) == 0 {
				fmt.Fprintf(e.s.Err, "research-sdd-archive: no RESEARCH-STATE*.md under %s — nothing to archive (run research-sdd-init.sh)\n", e.target)
				return cli.ExitUsage, true
			}
			fmt.Fprintf(e.s.Err, "research-sdd-archive: focus '%s' not found under %s (no RESEARCH-STATE-%s.md)\n", e.focus, e.target, e.focus)
			return cli.ExitUsage, true
		}
	} else {
		state, err = kit.ResolveStateFile(e.target, kit.ResolveOptions{})
		if errors.Is(err, kit.ErrStateAbsent) {
			fmt.Fprintf(e.s.Err, "research-sdd-archive: no RESEARCH-STATE*.md under %s — nothing to archive (run research-sdd-init.sh)\n", e.target)
			return cli.ExitUsage, true
		}
	}
	// rc 2 (ambiguous: the split layout) is legitimate; the resolver's first pick is the corpus. Any other status is a
	// loud refusal, never a silent pick.
	status := 0
	switch {
	case err == nil:
	case errors.Is(err, kit.ErrStateAmbiguous):
		status = 2
	default:
		status = 3
	}
	if (status != 0 && status != 2) || state == "" || !archiveIsFile(state) {
		fmt.Fprintf(e.s.Err, "research-sdd-archive: cannot resolve a RESEARCH-STATE file under %s (resolver status %d)\n", e.target, status)
		return cli.ExitUsage, true
	}
	e.state = state
	e.corpus = filepath.Dir(state)
	rel := strings.TrimPrefix(strings.TrimPrefix(e.corpus, e.target), "/")
	if e.corpus == e.target || rel == "" {
		rel = "(flat)"
	}
	dry := ""
	if e.dry {
		dry = "  ·  DRY-RUN"
	}
	e.say("== research-sdd-archive: %s  ·  corpus: %s%s ==", filepath.Base(e.target), rel, dry)
	return 0, false
}

// archiveListState is list_state_files: the paths, empty on any failure (the bash swallows its errors).
func (e *archiveEnv) archiveListState(dir string) []string {
	l, err := e.hooks.listState(dir)
	if err != nil {
		return nil
	}
	return l
}

func archiveIsFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}
