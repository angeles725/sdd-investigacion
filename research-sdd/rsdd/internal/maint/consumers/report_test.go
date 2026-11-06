package consumers

import (
	"fmt"
	"strings"
	"testing"
)

// TestDefaultReportOfASmallRepository pins the whole text of the default report: every string, the column
// layout, the typed words of the empty classes and the order of the lines.
func TestDefaultReportOfASmallRepository(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{
		"research-sdd/toolbelt/a.sh":      "b.sh\n",
		"research-sdd/toolbelt/b.sh":      "a.sh a.sh\nb.sh\n",
		"research-sdd/toolbelt/t.test.sh": "a.sh\n",
		"docs/readme.md":                  "see a.sh and b.sh\n",
		".github/workflows/ci.yml":        "run a.sh\n",
	})
	f.commit()
	row := func(c string, cells ...string) string {
		return fmt.Sprintf("%-25s %8s  %8s  %8s  %10s  %9s\n", c, cells[0], cells[1], cells[2], cells[3], cells[4])
	}
	none := []string{"no files", "n/a", "n/a", "n/a", "n/a"}
	want := "consumers: repository " + f.dir + "\n" +
		"kit: " + f.dir + "/research-sdd\n" +
		"files: 5 listed (tracked, and untracked but not ignored)\n" +
		"scripts: 2 (sh 2)\n" +
		"ambiguous basenames: none\n" +
		"excluded from the script list: `.test.` in the name 1, `fixtures` directory 0, `node_modules` 0\n" +
		row("class", "files", "with-ref", "pairs", "references", "self-only") +
		row("scripts", "2", "2", "2", "3", "none") +
		row("bash tests", "1", "1", "1", "1", "none") +
		row("doctrine and registries", "1", "1", "2", "2", "none") +
		row("CI workflows", "1", "1", "1", "1", "none") +
		row("templates", none...) +
		row("harness wiring", none...) +
		row("lists", none...) +
		row("unclassified", none...) +
		"unclassified files with a reference: no files\n" +
		"not read: fixtures 0, Go module 0, binary 0, not regular 0 (read 5 of 5 listed)\n" +
		"Go classes: not enumerated by this version (production code, tests, generated, assembled, embedded).\n" +
		"limits:\n" + strings.Join([]string{
		"  names that arrive through a flag or an environment variable are not seen",
		"  names built at run time are not seen",
		"  globs are not expanded: a pattern that matches a script is not a reference to it",
		"  names without the extension are not matched",
		"  nothing outside the repository is read: other repositories, installed copies, harness homes, git history",
		"  a match is a whole-name occurrence in text, not proof of a call: prose and comments count",
	}, "\n") + "\n"
	if got := f.run(); got != (ran{want, "", 0}) {
		t.Fatalf("got:\n%s\nwant:\n%s\nerr %q", got.out, want, got.err)
	}
}
