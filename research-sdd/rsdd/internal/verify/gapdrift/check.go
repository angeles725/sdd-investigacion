package gapdrift

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gaprows"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// DefaultThreshold is the overlap percent below which a row is suspected drift. Observed drift scored 0-17 %, honest
// paraphrases on the real corpus >= 33 %.
const DefaultThreshold = 20

// maxDepth is find's -maxdepth for the block files.
const maxDepth = 3

// rowTextMax is how many characters of a row's text a DRIFT? line shows.
const rowTextMax = 90

// Options selects what Check compares.
type Options struct {
	Threshold int  // integer percent 0-100; overlap strictly below it is drift
	All       bool // also check non-pending rows
}

// Outcome is the typed state of a whole check, so a zero count cannot hide an input that was not looked at.
type Outcome uint8

const (
	// OutcomeChecked: at least one row was compared with its bullet.
	OutcomeChecked Outcome = iota + 1
	// OutcomeEmptyInput: the state text has no bytes.
	OutcomeEmptyInput
	// OutcomeNoRows: the state has text but no comparable B<n>-G<m> backlog row (no-match). Counts.Unparsed may be
	// non-zero: rows the grammar could not parse are findings, not rows.
	OutcomeNoRows
	// OutcomeNoPending: backlog rows exist but none is pending and All was not set (no-match).
	OutcomeNoPending
	// OutcomeDegraded: rows were in scope but not one could be compared (no block, no bullet or no content word).
	OutcomeDegraded
)

// FindingKind is the type of one finding line.
type FindingKind uint8

const (
	// FindingDrift (DRIFT?): the row shares too few content words with its bullet.
	FindingDrift FindingKind = iota + 1
	// FindingNoBullet: the block exists but defines the gap only in prose, or not at all.
	FindingNoBullet
	// FindingNoBlock: no block file for that number under the target.
	FindingNoBlock
	// FindingNoWords: the row has no comparable content word (not drift, not checked).
	FindingNoWords
	// FindingUnparsed: a gap-id table row the row grammar could not parse.
	FindingUnparsed
)

// Finding is one report line.
type Finding struct {
	Kind    FindingKind
	ID      string // B<n>-G<m> (empty for FindingUnparsed)
	Block   string // the block number
	Line    int    // 1-based line of the state text
	Overlap int    // FindingDrift: the integer percent
	Text    string // FindingDrift: the row text, whole
	Source  string // FindingUnparsed: the first 90 bytes of the line
}

// Counts are the numbers of the summary line.
type Counts struct {
	Checked, Suspects, NoBullet, NoBlock, NoWords, Unparsed, SkippedNonPending, SkippedClosed int
}

// Result is one check's typed answer.
type Result struct {
	Outcome  Outcome
	Findings []Finding // in report order: drift, no-bullet, no-block, no-words, unparsed
	Counts   Counts
	Rows     int // backlog rows (pending or not), the script's `rows`
	Blocks   int // block files found under the target
	Target   string
	State    string // the label of the state, as the caller wrote it
}

// ExitCode is the command's code for this result: 1 for drift or unparsed rows, else 0.
func (r Result) ExitCode() int {
	if r.Counts.Suspects > 0 || r.Counts.Unparsed > 0 {
		return 1
	}
	return 0
}

// ErrorKind says which operational failure an Error is.
type ErrorKind uint8

const (
	ErrUsage ErrorKind = iota + 1
	ErrThreshold
	ErrStateUnreadable
	ErrListBlocks
	ErrReadBlock
)

// Error is an operational failure (the script's exit 2). Msg is the line the script printed on stderr.
type Error struct {
	Kind ErrorKind
	Msg  string
	Err  error
}

func (e *Error) Error() string { return e.Msg }
func (e *Error) Unwrap() error { return e.Err }

// Corpus is the block-file side of a target: the listing is read once and every block file at most once, so checking
// many state files of one corpus does not repeat the work.
type Corpus struct {
	target string
	cwd    string
	blocks []string // sorted, as printed (target as given + "/" + relative path)
	byNum  map[string][]string
	files  map[string]*fileEntry
	read   func(string) ([]byte, error)
}

type fileEntry struct {
	bullets *gaprows.Bullets
	err     error
}

// OpenCorpus lists the canonical block files under target (found up to three levels deep, nested git worktrees and
// .git excluded; the discriminator is core/kit's). Relative paths resolve against cwd. A directory that cannot be
// listed is an *Error: nothing was proven.
func OpenCorpus(cwd, target string) (*Corpus, error) {
	c := &Corpus{target: target, cwd: cwd, byNum: map[string][]string{}, files: map[string]*fileEntry{}, read: os.ReadFile}
	cand, ok := c.listMarkdown()
	if !ok {
		return nil, &Error{Kind: ErrListBlocks, Msg: "check-gap-drift: cannot list block files under " + target}
	}
	// A canonical block file name contains "-block" or "-bloque": a literal test is a cheap necessary condition, so the
	// POSIX regexp of the discriminator runs only on the plausible candidates (kit issue #2645).
	plausible := cand[:0:0]
	for _, p := range cand {
		if strings.Contains(p, "-block") || strings.Contains(p, "-bloque") {
			plausible = append(plausible, p)
		}
	}
	if blocks, err := kit.FilterBlockFiles(plausible, false, ""); err == nil {
		c.blocks = blocks
		sort.Strings(c.blocks)
	} // ErrNoMatch / ErrEmptyInput: no block file at all, a legitimate state
	return c, nil
}

// BlockFiles is how many canonical block files the corpus has.
func (c *Corpus) BlockFiles() int { return len(c.blocks) }

func (c *Corpus) at(p string) string {
	if c.cwd == "" || strings.HasPrefix(p, "/") {
		return p
	}
	return c.cwd + "/" + p
}

// listMarkdown is `find -H target -maxdepth 3 ( -path target/.claude/worktrees -o -name .git ) -prune -o -type f
// -name '*.md' -print`. ok is false where find would have exited non-zero (a directory it could not read).
func (c *Corpus) listMarkdown() (out []string, ok bool) {
	root := strings.TrimRight(c.target, "/")
	if i := strings.LastIndexByte(root, '/'); root != "" && root[i+1:] == ".git" {
		return nil, true // -name .git matches the start point: pruned, nothing printed
	}
	ok = true
	var walk func(dir, abs, rel string, depth int)
	walk = func(dir, abs, rel string, depth int) {
		ents, err := os.ReadDir(abs)
		if err != nil {
			ok = false
		}
		for _, e := range ents {
			name := e.Name()
			if name == ".git" {
				continue
			}
			p, a, r := join(dir, name), abs+"/"+name, rel+name
			switch {
			case e.Type().IsRegular():
				if strings.HasSuffix(name, ".md") {
					out = append(out, p)
				}
			case e.IsDir() && depth < maxDepth && r != ".claude/worktrees":
				walk(p, a, r+"/", depth+1)
			}
		}
	}
	walk(c.target, c.at(c.target), "", 1)
	return out, ok
}

func join(dir, name string) string {
	if strings.HasSuffix(dir, "/") {
		return dir + name
	}
	return dir + "/" + name
}

// filesFor are the block files of block number num: `grep -E -- "-(block|bloque)NUM(-[[:alnum:]_-]+)?\.md$"` over
// the printed paths.
func (c *Corpus) filesFor(num string) []string {
	if f, ok := c.byNum[num]; ok {
		return f
	}
	re := regexp.MustCompilePOSIX(`-(block|bloque)` + regexp.QuoteMeta(num) + `(-[[:alnum:]_-]+)?\.md$`)
	var files []string
	for _, b := range c.blocks {
		if re.MatchString(b) {
			files = append(files, b)
		}
	}
	c.byNum[num] = files
	return files
}

func (c *Corpus) bullets(path string) (*gaprows.Bullets, error) {
	if e, ok := c.files[path]; ok {
		return e.bullets, e.err
	}
	e := &fileEntry{}
	if b, err := c.read(c.at(path)); err != nil {
		e.err = &Error{Kind: ErrReadBlock, Msg: "check-gap-drift: cannot read " + path, Err: err}
	} else {
		e.bullets = gaprows.ParseBullets(string(b))
	}
	c.files[path] = e
	return e.bullets, e.err
}

// Check compares every backlog row of state (the text of the state file called label) with its defining bullet.
func (c *Corpus) Check(state, label string, o Options) (Result, error) {
	tbl := gaprows.Parse(state)
	res := Result{Target: c.target, State: label, Blocks: len(c.blocks)}
	var drift, noBullet, noBlock, noWords, unparsed []Finding
	ct := &res.Counts
	for _, r := range tbl.Records {
		switch r.Kind {
		case gaprows.KindSkipped:
			ct.SkippedClosed++
			continue
		case gaprows.KindUnparsed:
			ct.Unparsed++
			unparsed = append(unparsed, Finding{Kind: FindingUnparsed, Line: r.Line, Source: r.Source})
			continue
		}
		res.Rows++
		if !o.All && !r.Pending {
			ct.SkippedNonPending++
			continue
		}
		f := Finding{ID: r.ID, Block: r.Block, Line: r.Line, Text: r.Text}
		files := c.filesFor(r.Block)
		if len(files) == 0 {
			ct.NoBlock++
			f.Kind = FindingNoBlock
			noBlock = append(noBlock, f)
			continue
		}
		bullet, have := "", false
		for _, file := range files {
			b, err := c.bullets(file)
			if err != nil {
				return res, err
			}
			if bullet, have = b.Text(r.ID); have {
				break
			}
		}
		if !have {
			ct.NoBullet++
			f.Kind = FindingNoBullet
			noBullet = append(noBullet, f)
			continue
		}
		shared, total := gaprows.Overlap(r.Text, bullet)
		if total == 0 {
			ct.NoWords++
			f.Kind = FindingNoWords
			noWords = append(noWords, f)
			continue
		}
		ct.Checked++
		if shared*100 < o.Threshold*total {
			ct.Suspects++
			f.Kind, f.Overlap = FindingDrift, shared*100/total
			drift = append(drift, f)
		}
	}
	res.Findings = append(append(append(append(drift, noBullet...), noBlock...), noWords...), unparsed...)
	switch {
	case res.Rows == 0 && tbl.Empty:
		res.Outcome = OutcomeEmptyInput
	case res.Rows == 0:
		res.Outcome = OutcomeNoRows
	case res.Rows == ct.SkippedNonPending:
		res.Outcome = OutcomeNoPending
	case ct.Checked == 0:
		res.Outcome = OutcomeDegraded
	default:
		res.Outcome = OutcomeChecked
	}
	return res, nil
}

// Render writes the script's report: the finding lines, the one-line state message where one applies, and the
// summary line.
func (r Result) Render(w io.Writer) {
	var b strings.Builder
	for _, f := range r.Findings {
		switch f.Kind {
		case FindingDrift:
			fmt.Fprintf(&b, "DRIFT? %s overlap=%d%% row='%s'\n", f.ID, f.Overlap, cutChars(f.Text, rowTextMax))
		case FindingNoBullet:
			fmt.Fprintf(&b, "NO-BULLET %s (no '- **%s**' bullet in its block; prose-only or undefined)\n", f.ID, f.ID)
		case FindingNoBlock:
			fmt.Fprintf(&b, "NO-BLOCK %s (no block file for block %s under %s)\n", f.ID, f.Block, r.Target)
		case FindingNoWords:
			fmt.Fprintf(&b, "NO-WORDS %s (row text has no comparable content word)\n", f.ID)
		case FindingUnparsed:
			fmt.Fprintf(&b, "UNPARSED %s\n", f.Source)
		}
	}
	ct := r.Counts
	switch {
	case r.Rows == 0 && ct.Unparsed == 0:
		fmt.Fprintf(&b, "check-gap-drift: no B<n>-G<m> backlog rows in %s (not applicable)\n", r.State)
	case r.Outcome == OutcomeNoPending:
		fmt.Fprintf(&b, "check-gap-drift: no pending B<n>-G<m> rows (%d non-pending skipped; use --all)\n", ct.SkippedNonPending)
	case r.Outcome == OutcomeDegraded:
		fmt.Fprintf(&b, "DEGRADED: %d row(s) in scope but none could be compared (no_block=%d no_bullet=%d no_words=%d) — this is not a clean result\n",
			r.Rows-ct.SkippedNonPending, ct.NoBlock, ct.NoBullet, ct.NoWords)
	}
	fmt.Fprintf(&b, "checked=%d suspects=%d no_bullet=%d no_block=%d no_words=%d unparsed=%d skipped_nonpending=%d skipped_closed=%d\n",
		ct.Checked, ct.Suspects, ct.NoBullet, ct.NoBlock, ct.NoWords, ct.Unparsed, ct.SkippedNonPending, ct.SkippedClosed)
	_, _ = io.WriteString(w, b.String())
}

// cutChars is ${s:0:n} in a UTF-8 locale: the first n characters, an invalid byte counting as one character.
func cutChars(s string, n int) string {
	i := 0
	for ; n > 0 && i < len(s); n-- {
		_, size := utf8.DecodeRuneInString(s[i:])
		i += size
	}
	return s[:i]
}
