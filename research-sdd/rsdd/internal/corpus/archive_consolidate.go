package corpus

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// archiveConsolidate is the best-effort bookkeeping: regenerate CATALOG.md and touch INDEX.md. A failure is surfaced
// loudly (stderr and the checklist) but never flips the exit code, the gate already decided the close is legitimate.
//
// The kit generator is the default authority, but a target's LOCAL tools/gen-catalog.py wins when present: mature
// corpora ship a bespoke generator for structures the generic one cannot express. A SYMLINK to the shared generator is
// handed the corpus as argv (else it resolves its own location and writes into the kit tree); a real file is run with
// no argument, its parent.parent being the corpus.
func (e *archiveEnv) archiveConsolidate() {
	genKit := e.here + "/../templates/gen-catalog.py"
	genLocal := e.corpus + "/tools/gen-catalog.py"
	var cmd []string
	desc := ""
	switch {
	case archiveIsFile(genLocal):
		if st, err := os.Lstat(genLocal); err == nil && st.Mode()&os.ModeSymlink != 0 {
			cmd = []string{"python3", genLocal, e.corpus}
		} else {
			cmd = []string{"python3", genLocal}
		}
		desc = "local generator (" + genLocal + ")"
	case archiveIsFile(genKit):
		desc = "kit generator (" + genKit + ")"
		cmd = []string{"python3", genKit, e.corpus}
	}
	var catalog string
	switch {
	case desc == "":
		catalog = "skipped (no generator: neither " + genLocal + " nor " + genKit + ")"
	case e.dry:
		catalog = "would regenerate via " + desc
	default:
		if _, rc := e.archiveRunArgv(cmd, false); rc == 0 {
			catalog = "regenerated CATALOG.md (via " + desc + ")"
		} else {
			catalog = "ERROR — gen-catalog.py failed (CATALOG.md NOT regenerated / left stale)"
			e.consolidateErr = "CATALOG regen failed — run: " + strings.Join(cmd, " ")
			e.warn("WARNING: %s", e.consolidateErr)
		}
	}
	index := "skipped (no INDEX*.md)"
	idx := e.corpus + "/INDEX.md"
	if !archiveIsFile(idx) {
		idx = e.archiveFirstIndex()
	}
	if idx != "" && archiveIsFile(idx) {
		base := filepath.Base(idx)
		switch {
		case e.dry:
			index = "would touch " + base
		case e.hooks.touch(idx, e.s.Clock()) == nil:
			index = "touched " + base
		default:
			index = "ERROR — could not touch " + base + " (permission?)"
			if e.consolidateErr == "" {
				e.consolidateErr = "touch INDEX failed"
			}
		}
	}
	e.say("  -- consolidate --")
	e.say("    catalog        : %s", catalog)
	e.say("    index          : %s", index)
}

// archiveFirstIndex is `find corpus -maxdepth 1 -name 'INDEX*.md' | sort | head -1`.
func (e *archiveEnv) archiveFirstIndex() string {
	ents, err := os.ReadDir(e.corpus)
	if err != nil {
		return ""
	}
	var names []string
	for _, en := range ents {
		n := en.Name()
		if strings.HasPrefix(n, "INDEX") && strings.HasSuffix(n, ".md") && len(n) >= len("INDEX.md") {
			names = append(names, e.corpus+"/"+n)
		}
	}
	sort.Strings(names)
	if len(names) == 0 {
		return ""
	}
	return names[0]
}
