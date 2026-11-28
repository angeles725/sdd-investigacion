// Package loopevidence answers one question about a session transcript: did this session run the research loop?
// The return-token gate (kit issues #2792, #2841) holds a final report to a continuation token only when the answer
// is yes. A target that merely HAS a RESEARCH-STATE file is not evidence: the kit repository is itself a corpus, so
// every kit-maintenance session in it used to be asked for a token it never earned.
//
// Evidence is positive and structural, read from tool calls and slash commands, never from prose:
//   - a Bash tool call that RUNS the status instrument (research-sdd-status.sh or `rsdd status`) with --next or
//     --emit-token, naming this target or none (a run on another target is that target's loop);
//   - a write tool call (Write, Edit, MultiEdit, NotebookEdit) on a research block file or a RESEARCH-STATE file
//     inside this target, outside fixture, template and test-data trees;
//   - the Skill tool called for research-sdd, or the user's /research-sdd slash command.
//
// The three states of kit CLAUDE.md section 7 stay distinct: a transcript that cannot be read is ErrUnreadable, an
// empty one is Scan{Lines: 0}, and a read one with no match is Scan{Found: false, Lines: n} (Oversize says how many
// lines were too long to inspect, so a "no" over such a transcript is not a proof).
package loopevidence

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
)

// Kind names the rule that matched.
type Kind string

const (
	KindStatusRun    Kind = "status-run"    // a Bash tool call ran the status instrument with --next or --emit-token
	KindBlockWrite   Kind = "block-write"   // a write tool call targeted a research block file
	KindStateWrite   Kind = "state-write"   // a write tool call targeted a RESEARCH-STATE file
	KindSkill        Kind = "skill"         // the research-sdd skill was invoked through the Skill tool
	KindSlashCommand Kind = "slash-command" // the user ran /research-sdd
)

// Evidence is the first matching fact; Detail is a bounded excerpt (the command or the path).
type Evidence struct {
	Kind   Kind
	Detail string
}

// Options tune a scan.
type Options struct {
	Target       string // the gate target; a write or status run that names another target is not evidence
	MaxLineBytes int    // 0 = DefaultMaxLineBytes
}

// DefaultMaxLineBytes bounds one transcript line; a longer line is skipped and counted, never silently dropped.
const DefaultMaxLineBytes = 4 << 20

// Scan is what a pass over a transcript saw.
type Scan struct {
	Found    bool
	First    Evidence
	Lines    int // lines read (the pass stops at the first evidence)
	Oversize int // lines over MaxLineBytes that were NOT inspected
}

// ErrUnreadable: the transcript could not be opened or read, so the absence of evidence is unproven.
var ErrUnreadable = errors.New("loopevidence: transcript unreadable")

// ScanReader reads transcript lines from r until the first evidence. A read error after evidence was found is
// ignored (the answer is already yes); without evidence it is ErrUnreadable.
func ScanReader(r io.Reader, o Options) (Scan, error) {
	max := o.MaxLineBytes
	if max <= 0 {
		max = DefaultMaxLineBytes
	}
	var sc Scan
	br := bufio.NewReaderSize(r, 64<<10)
	var line []byte
	over := false
	flush := func() {
		sc.Lines++
		line = trimEOL(line)
		if over || len(line) > max {
			sc.Oversize++
		} else if ev, ok := Classify(line, o); ok {
			sc.Found, sc.First = true, ev
		}
		line, over = line[:0], false
	}
	for !sc.Found {
		chunk, err := br.ReadSlice('\n')
		if !over {
			// bounded memory: past max+2 bytes (room for a CRLF) the line is over and its bytes are dropped
			if line = append(line, chunk...); len(line) > max+2 {
				over, line = true, line[:0]
			}
		}
		switch {
		case err == nil:
			flush()
		case errors.Is(err, bufio.ErrBufferFull):
			// the line continues in the next chunk
		case errors.Is(err, io.EOF):
			if len(line) > 0 || over {
				flush()
			}
			return sc, nil
		default:
			return sc, fmt.Errorf("%w: %v", ErrUnreadable, err)
		}
	}
	return sc, nil
}

func trimEOL(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}

// ScanTranscript scans the regular file at path.
func ScanTranscript(path string, o Options) (Scan, error) {
	f, err := os.Open(path)
	if err != nil {
		return Scan{}, fmt.Errorf("%w: %v", ErrUnreadable, err)
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil || !st.Mode().IsRegular() {
		return Scan{}, fmt.Errorf("%w: not a regular file: %s", ErrUnreadable, path)
	}
	return ScanReader(f, o)
}
