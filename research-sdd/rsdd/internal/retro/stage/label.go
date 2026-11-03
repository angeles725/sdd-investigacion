package stage

import (
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// targetLabel names the branch and the `Retro:` trailer with the SAME registered Target name stage-retro-issues
// and reconcile-issues use (kit issue #1287 item 8): the nearest registered ancestor, so a nested
// <target>/corpus/retros retro is not labelled `corpus` and a target whose registered name differs from its path
// basename is not labelled with the basename. The label only names a branch and a commit trailer, so an
// unreadable or empty registry and an unregistered retro are a loud WARN and the directory basename here, not the
// hard exit the issue-seeding scripts take: nothing keyed on the name has been written yet.
func (s *stager) targetLabel() string {
	label := filepath.Base(s.targetRoot()) // the fallback
	targets := filepath.Join(s.o.KitRoot, "research-sdd", "TARGETS.md")
	res, err := kit.NameForRetro(targets, s.retro, s.o.Cwd, s.o.Getenv)
	for _, w := range res.Warnings {
		s.errf("%s\n", w)
	}
	switch rc := kit.RC(err); rc {
	case 0:
		return res.Name
	case 1:
		// Operational (kit issue #1369 d): the registry could not be consulted, which is not the same as "this
		// retro is unregistered" (rc 2), so it is typed apart. The reason is the library's own message.
		s.errf("%s\n", err.Error())
		s.errf("WARN: target-name lookup FAILED (rc=1, operational — the registry could not be consulted, see the message above) for '%s' — labelling with directory basename '%s', which may differ from the registered target name\n", s.retro, label)
	default:
		s.errf("WARN: no registered target name for '%s' (target_name_for_retro rc=%d) — labelling with directory basename '%s'\n", s.retro, rc, label)
	}
	return label
}
