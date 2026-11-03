package corpus

// Fixture builders: Go ports of the mk* helpers of the retired research-sdd-archive.test.sh. Dates of every commit are
// pinned so commit ids (printed by the ONE-BLOCK-PER-COMMIT report) are the same on every run.

import (
	"fmt"
	"path/filepath"
	"strings"
)

const archiveStateText = `# T — Research State

## Coverage

- **Covered blocks**: 1 (B1)
- **Coverage metric**: 2 / 3 closed

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | still-open gap | web | pending |

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-07-07 | first gap | B1 | no · inline | 1 |

## Stop control

- **Open gaps — read-only investigable**: 1
`

const archiveBlockText = "# Block 1 — the first thing\nBody.\n"
const archiveCloseRetro = "<!-- review-status: pending -->\n# Close retro — test fixture\n"

func archiveFocusState(name, block, date string) string {
	return fmt.Sprintf(`# %s — Research State
> Active focus.

## Coverage

- **Covered blocks**: 1 (%s)
- **Coverage metric**: 1 / 1 closed

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | %s | first gap | %s | no · inline | 0 |

## Stop control

- **Open gaps — read-only investigable**: 0
`, name, block, date, block)
}

// runState is the two-block state of the mkrun_git family.
func archiveRunState() string {
	return strings.Replace(archiveStateText, "- **Covered blocks**: 1 (B1)", "- **Covered blocks**: 2 (B1, B2)", 1)
}

func (f *archiveFx) mkgood(c string) {
	f.t.Helper()
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), archiveStateText)
	f.write(filepath.Join(c, "t-block1.md"), archiveBlockText)
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.sync(c)
	f.closeRetro(c)
}

func (f *archiveFx) mkgoodGit(c, rdate, bdate, rmtime, bmtime string) {
	f.t.Helper()
	f.gitInit(c)
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), archiveStateText)
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.git(c, "add", "-A")
	f.commit(c, "2026-01-01T00:00:00", "baseline")
	f.write(filepath.Join(c, "retros", "2026-retro-focus.md"), "# retro\n")
	f.git(c, "add", "-A")
	f.commit(c, rdate, "add retro")
	f.chtimes(filepath.Join(c, "retros", "2026-retro-focus.md"), rmtime)
	f.write(filepath.Join(c, "t-block1.md"), archiveBlockText)
	f.git(c, "add", "-A")
	f.commit(c, bdate, "add block1")
	f.chtimes(filepath.Join(c, "t-block1.md"), bmtime)
	f.sync(c)
}

func (f *archiveFx) mkgoodGitClean(c string) {
	f.t.Helper()
	f.gitInit(c)
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), archiveStateText)
	f.write(filepath.Join(c, "t-block1.md"), archiveBlockText)
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.write(filepath.Join(c, "retros", "2099-01-01-close.md"), archiveCloseRetro)
	f.sync(c)
	f.git(c, "add", "-A")
	f.commit(c, "2026-06-01T00:00:00", "seed corpus")
}

func (f *archiveFx) mkgoodGitPresync(c string) {
	f.t.Helper()
	f.gitInit(c)
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), archiveStateText)
	f.write(filepath.Join(c, "t-block1.md"), archiveBlockText)
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.write(filepath.Join(c, "retros", "2099-01-01-close.md"), archiveCloseRetro)
	f.git(c, "add", "-A")
	f.commit(c, "2026-06-01T00:00:00", "seed corpus (pre-sync)")
}

func (f *archiveFx) mkNestedTarget(outer, nested string) {
	f.t.Helper()
	f.gitInit(outer)
	f.write(filepath.Join(outer, "README.md"), "# outer repo\n")
	f.git(outer, "add", "-A")
	f.commit(outer, "2026-06-01T00:00:00", "outer repo baseline")
	f.write(filepath.Join(nested, "RESEARCH-STATE.md"), archiveStateText)
	f.write(filepath.Join(nested, "t-block1.md"), archiveBlockText)
	f.write(filepath.Join(nested, "INDEX.md"), "")
	f.write(filepath.Join(nested, "retros", "2099-01-01-close.md"), archiveCloseRetro)
	f.chtimes(filepath.Join(nested, "retros", "2099-01-01-close.md"), "2099-01-01") // the bash fixture relied on same-second mtimes
	f.sync(nested)
}

// mkrunGit: baseline + old retro, then B1/B2 together or split, then a close retro committed last; dirty on return.
// preRow is committed into the baseline state (an earlier run's iteration-history row).
func (f *archiveFx) mkrunGit(c string, together bool, preRow string) {
	f.t.Helper()
	f.gitInit(c)
	st := archiveRunState()
	if preRow != "" {
		var out []string
		for _, l := range strings.Split(st, "\n") {
			out = append(out, l)
			if strings.HasPrefix(l, "| 1 | 2026-07-07") {
				out = append(out, preRow)
			}
		}
		st = strings.Join(out, "\n")
	}
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), st)
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.git(c, "add", "-A")
	f.commit(c, "2026-01-01T00:00:00", "baseline")
	f.write(filepath.Join(c, "retros", "2026-retro-focus.md"), "# retro\n")
	f.git(c, "add", "-A")
	f.commit(c, "2026-02-01T00:00:00", "add retro")
	f.write(filepath.Join(c, "t-block1.md"), "# Block 1\nBody.\n")
	f.write(filepath.Join(c, "t-block2.md"), "# Block 2\nBody.\n")
	if together {
		f.git(c, "add", "-A")
		f.commit(c, "2026-03-01T00:00:00", "B1+B2 (violation)")
	} else {
		f.git(c, "add", "t-block1.md")
		f.commit(c, "2026-03-01T00:00:00", "B1")
		f.git(c, "add", "t-block2.md")
		f.commit(c, "2026-03-02T00:00:00", "B2")
	}
	f.write(filepath.Join(c, "retros", "2026-close-retro.md"), archiveCloseRetro)
	f.git(c, "add", "retros/2026-close-retro.md")
	f.commit(c, "2026-04-01T00:00:00", "close retro")
	f.sync(c)
}

// mkrunGitPSA is mkrun_git(together) plus a row (or a raw line) inserted after the last numbered table row.
func (f *archiveFx) mkrunGitPSA(c, marker, date, raw, preRow string) {
	f.t.Helper()
	f.mkrunGit(c, true, preRow)
	if date == "" {
		date = "2026-07-08"
	}
	ins := raw
	if ins == "" {
		ins = fmt.Sprintf("| 2 | %s | import | B1,B2 | no · inline · %s | 0 |", date, marker)
	}
	lines := strings.Split(f.read(filepath.Join(c, "RESEARCH-STATE.md")), "\n")
	last := -1
	for i, l := range lines {
		if archiveNumRow.MatchString(l) {
			last = i
		}
	}
	var out []string
	for i, l := range lines {
		out = append(out, l)
		if i == last {
			out = append(out, ins)
		}
	}
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), strings.Join(out, "\n"))
}

func (f *archiveFx) mkrunGitBacklink(c string) {
	f.t.Helper()
	f.gitInit(c)
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), archiveRunState())
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.git(c, "add", "-A")
	f.commit(c, "2026-01-01T00:00:00", "baseline")
	f.write(filepath.Join(c, "retros", "2026-retro-focus.md"), "# retro\n")
	f.git(c, "add", "-A")
	f.commit(c, "2026-02-01T00:00:00", "add retro")
	f.write(filepath.Join(c, "t-block1.md"), "# Block 1\nOriginal claim.\n")
	f.git(c, "add", "t-block1.md")
	f.commit(c, "2026-02-15T00:00:00", "B1")
	f.write(filepath.Join(c, "t-block2.md"), "# Block 2\nRefines [Block 1] §1.\n")
	f.write(filepath.Join(c, "t-block1.md"), "# Block 1\nOriginal claim.\n\n> Note: corrected in B2.\n")
	f.git(c, "add", "-A")
	f.commit(c, "2026-03-01T00:00:00", "B2 + §14 backlink into B1")
	f.write(filepath.Join(c, "retros", "2026-close-retro.md"), archiveCloseRetro)
	f.git(c, "add", "retros/2026-close-retro.md")
	f.commit(c, "2026-04-01T00:00:00", "close retro")
	f.sync(c)
}

func (f *archiveFx) mkrunGitRename(c string) {
	f.t.Helper()
	f.gitInit(c)
	f.git(c, "config", "diff.renames", "false")
	f.write(filepath.Join(c, "RESEARCH-STATE.md"), archiveRunState())
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.git(c, "add", "-A")
	f.commit(c, "2026-01-01T00:00:00", "baseline")
	f.write(filepath.Join(c, "retros", "2026-retro-focus.md"), "# retro\n")
	f.git(c, "add", "-A")
	f.commit(c, "2026-02-01T00:00:00", "add retro")
	f.write(filepath.Join(c, "t-block1.md"), "# Block 1\nOriginal claim, long enough that a naive similarity heuristic still calls it a rename.\n")
	f.git(c, "add", "t-block1.md")
	f.commit(c, "2026-02-15T00:00:00", "B1")
	f.git(c, "mv", "t-block1.md", "t-block1-renamed.md")
	f.write(filepath.Join(c, "t-block2.md"), "# Block 2\nGenuinely new block.\n")
	f.git(c, "add", "-A")
	f.commit(c, "2026-03-01T00:00:00", "rename B1 + add B2")
	f.write(filepath.Join(c, "retros", "2026-close-retro.md"), archiveCloseRetro)
	f.git(c, "add", "retros/2026-close-retro.md")
	f.commit(c, "2026-04-01T00:00:00", "close retro")
	f.sync(c)
}

func (f *archiveFx) mkvcorr(c string) {
	f.t.Helper()
	f.mkgood(c)
	f.write(filepath.Join(c, "t-block2.md"), "# Block 2 — correction\nCorrects [Block 1] §1.1 — the earlier claim was wrong.\n")
	f.sync(c)
}

func (f *archiveFx) mkmulti(c string) {
	f.t.Helper()
	f.write(filepath.Join(c, "RESEARCH-STATE-alpha.md"), archiveFocusState("Alpha", "alpha-block1", "2026-07-27"))
	f.write(filepath.Join(c, "RESEARCH-STATE-beta.md"), archiveFocusState("Beta", "beta-block1", "2026-07-27"))
	f.write(filepath.Join(c, "alpha-block1.md"), "# Alpha Block 1\nBody.\n")
	f.write(filepath.Join(c, "beta-block1.md"), "# Beta Block 1\nBody.\n")
	f.write(filepath.Join(c, "INDEX.md"), "")
	f.sync(c, "alpha")
	f.sync(c, "beta")
	f.closeRetro(c)
}

func (f *archiveFx) mkvfocus(c, focus string) {
	f.t.Helper()
	f.mkmulti(c)
	f.write(filepath.Join(c, focus+"-block2.md"), "# Block 2 — correction\nCorrects [Block 1] §1.1 — the earlier claim was wrong.\n")
	f.sync(c, focus)
}

func (f *archiveFx) mksplit(c string) {
	f.t.Helper()
	for _, n := range []string{"alpha", "beta"} {
		d := filepath.Join(c, n)
		title := strings.ToUpper(n[:1]) + n[1:]
		f.write(filepath.Join(d, "RESEARCH-STATE.md"), archiveFocusState(title, n+"-block1", "2026-07-28"))
		f.write(filepath.Join(d, n+"-block1.md"), "# "+title+" Block 1\nBody.\n")
		f.write(filepath.Join(d, "INDEX.md"), "")
		f.sync(d)
	}
	f.closeRetro(filepath.Join(c, "alpha"))
	f.closeRetro(filepath.Join(c, "beta"))
}

const archiveSecretLine = "Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n"
