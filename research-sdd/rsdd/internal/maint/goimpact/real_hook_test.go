package goimpact_test

import (
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

var hookCallRe = regexp.MustCompile(`(?:^|&&[ \t]*|;[ \t]*)rsdd_exec_hook[ \t]+([A-Za-z0-9_-]+)[ \t]+([A-Za-z0-9_-]+)[ \t]+([A-Za-z0-9_-]+)`)

// Hook arity: `rsdd_exec_hook <kind> <group> <name>` takes the command from the 2nd and 3rd words, never the 1st
// (the kind may equal the group, as in `sweep sweep audits`, so the pair read from the 2nd and 3rd words is what is pinned).
// Every such call on the real tree must map to a recovered command, and the scanner must report that exact pair.
func TestHookCallsTakeGroupAndNameFromTheSecondAndThirdWords(t *testing.T) {
	repo := realRepo(t)
	m, err := goimpact.Load(repo)
	if err != nil {
		t.Fatal(err)
	}
	known := map[goimpact.Command]bool{}
	for _, c := range m.AllCommands() {
		known[c] = true
	}
	files, err := goimpact.ScanBash(repo, func(c goimpact.Command) bool { return known[c] })
	if err != nil {
		t.Fatal(err)
	}
	found, mentioning := 0, 0
	for _, f := range files {
		if f.Path == "research-sdd/toolbelt/lib/rsdd-exec.sh" {
			continue
		}
		if strings.Contains(f.Text, "rsdd_exec_hook") {
			mentioning++
		}
		hooked := map[goimpact.Command]bool{}
		for _, c := range f.Calls {
			hooked[c.Cmd] = true // a command reached by two forms is reported once, under the first
		}
		calls := 0
		for _, line := range strings.Split(f.Text, "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			mm := hookCallRe.FindStringSubmatch(strings.TrimSpace(line))
			if mm == nil {
				continue
			}
			calls++
			cmd := goimpact.Command{Group: mm[2], Name: mm[3]} // mm[1] is the hook kind (sweep, guard, gate): never the group
			switch {
			case !known[cmd]:
				t.Errorf("%s: %q is not a recovered command (unclassified): %q", f.Path, cmd.String(), strings.TrimSpace(line))
			case !hooked[cmd]:
				t.Errorf("%s: the scanner did not report %q for %q", f.Path, cmd.String(), strings.TrimSpace(line))
			}
		}
		if calls > 0 {
			found++
		}
	}
	// measured on origin/main 512db127: 21 files name the helper (20 outside lib/rsdd-exec.sh), 9 hold a real call
	if mentioning < 10 || found < 9 {
		t.Errorf("walk looks vacuous: %d files name rsdd_exec_hook (want >= 10), %d hold a call (want >= 9)", mentioning, found)
	}
	t.Logf("%d bash files name rsdd_exec_hook, %d hold a real call", mentioning, found)
}
