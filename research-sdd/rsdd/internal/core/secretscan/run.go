package secretscan

import (
	"fmt"
	"io"
	"path/filepath"
)

// Exit codes (the scan-secrets.sh contract): clean, a high-confidence leak, usage, degraded.
const (
	rcOK       = 0
	rcLeak     = 1
	rcUsage    = 2
	rcDegraded = 3
)

// Request is one scan. The domain command validates its arguments; this is what is left to do.
type Request struct {
	Target    string    // the directory to scan, as the caller wrote it (it names the report)
	Cwd       string    // what a relative Target and FilesFrom resolve against
	Committed bool      // scan the committed history instead of the working tree
	FilesFrom string    // a NUL-delimited list of absolute paths to scan ("-" = Stdin); "" = walk the target
	Stdin     io.Reader // the list when FilesFrom is "-"
	Env       []string  // the environment git runs with (KEY=VALUE)
	KitDir    string    // the kit root holding TARGETS.md ("" = no live-install banner)
	Git       Git       // nil = the real git found on Env's PATH
}

// session is the state of one Run.
type session struct {
	req         Request
	out, errw   io.Writer
	abs         string
	git         Git
	rc          int
	hits, warns int
	nulls       int
	name        string
}

// stop ends a run early with an exit code (its message is already written to stderr).
type stop struct{ rc int }

func (s *session) fail(rc int, msg string) *stop {
	fmt.Fprintln(s.errw, msg)
	return &stop{rc}
}

// resolve makes a relative path absolute against the request's working directory.
func (s *session) resolve(p string) string {
	if filepath.IsAbs(p) || s.req.Cwd == "" {
		return p
	}
	return filepath.Join(s.req.Cwd, p)
}

// Run scans per req, writing the report to out and the diagnostics to errw, and returns the exit code: 0 clean in
// scope (or only advisory warnings), 1 a high-confidence secret value leaked, 2 bad input, 3 degraded.
func Run(req Request, out, errw io.Writer) int {
	s := &session{req: req, out: out, errw: errw}
	s.abs = s.resolve(req.Target)
	s.name = targetBase(req.Target, s.abs)
	if st := s.run(); st != nil {
		return st.rc
	}
	return s.rc
}

func (s *session) run() *stop {
	var (
		set      fileSet
		hist     findings
		blobsErr *stop
	)
	switch {
	case s.req.Committed:
		if st := s.preflightHistory(); st != nil {
			return st
		}
		hist, blobsErr = s.loadHistory()
		if blobsErr != nil {
			return blobsErr
		}
	case s.req.FilesFrom != "":
		var st *stop
		if set, st = s.loadFilesFrom(); st != nil {
			return st
		}
	default:
		set = walkSet(s.req.Target, s.abs)
	}
	s.printHeader(set)
	s.say("-- high-confidence secret values --")
	f := hist
	if !s.req.Committed {
		var readErr bool
		f, readErr = analyzeFiles(set)
		if readErr || set.Unreadable {
			return s.fail(rcDegraded, "DEGRADED: grep read error (rc=2) scanning for '"+rules[0].Label+"' — an unreadable in-scope file? scan incomplete")
		}
	}
	s.printLeaks(f)
	s.printAdvisory(f)
	if s.req.Committed {
		lines, st := s.scanCommits()
		if st != nil {
			return st
		}
		s.printCommitMessages(lines)
	}
	s.printBinary(f.nuls)
	s.printSummary()
	return nil
}

// loadHistory enumerates and scans the committed blobs.
func (s *session) loadHistory() (findings, *stop) {
	enum := s.enumerate()
	if enum.RC[0] != 0 || enum.RC[1] != 0 {
		return findings{}, s.fail(rcDegraded, fmt.Sprintf("DEGRADED: rev-list|diff-tree enumeration failed (rc=%d %d) — cannot enumerate committed blobs", enum.RC[0], enum.RC[1]))
	}
	if enum.Fail != "" {
		return findings{}, s.fail(rcDegraded, enum.Fail+"\nDEGRADED: blob filter pipeline failed (rc=1 0 0) — blob enumeration unreliable")
	}
	if len(enum.Blobs) == 0 && enum.Records > 0 {
		return findings{}, s.fail(rcDegraded, "DEGRADED: 0 in-scope blobs found but rev-list|diff-tree produced output — filter pipeline may have failed silently")
	}
	return s.scanBlobs(enum.Blobs)
}

// printHeader writes the opening lines: the title, the mode or corpus root, the file-set counters and the
// live-install reminder.
func (s *session) printHeader(set fileSet) {
	if s.req.Committed {
		s.say("== scan-secrets --committed: %s ==", s.name)
		s.say("-- mode: committed — scanning ALL committed history reachable from HEAD (files + commit messages)")
	} else {
		s.say("== scan-secrets: %s ==", s.name)
		if set.CorpusRel != "" {
			s.say("-- corpus root: %s/", set.CorpusRel)
		}
		if s.req.FilesFrom != "" {
			s.say("-- file set: %d listed · %d in scope · %d skipped (not a regular file) — explicit --files-from list, no corpus narrowing", set.Listed, set.InScope, set.NonReg)
		}
	}
	if liveInstall(s.req.KitDir, s.name) {
		s.say("-- target registered LIVE-INSTALL: SECRETS DISCIPLINE is a hard invariant here (zero secrets exfiltrated).")
	}
}
