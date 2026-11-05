package secretscan

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// findings is what a scan found, ready to print: leaks[i] are the locations ("path:line", or "path@sha:line" for
// history) of rule i in report order; warns the advisory locations in report order; nuls the in-scope files with a
// NUL byte. No value is ever stored here: a verdict that echoed one would itself leak it.
type findings struct {
	leaks [][]string
	warns []string
	nuls  int
}

// oneLine keeps a path on one report line: a newline in a file name is shown as \n (the legacy report split the
// line and lost the name from the location).
func oneLine(p string) string { return strings.ReplaceAll(p, "\n", `\n`) }

// analyzeFiles analyses every file of the set in order. readErr is true when a file could not be read: grep exits 2
// on an unreadable file, and a scan that could not look is never a clean verdict.
func analyzeFiles(set fileSet) (f findings, readErr bool) {
	f.leaks = make([][]string, len(rules))
	for _, file := range set.Files {
		data, err := os.ReadFile(file.Abs)
		if err != nil {
			readErr = true
			continue
		}
		a := analyze(data, analyzeOpts{})
		if a.NUL {
			f.nuls++
		}
		for _, h := range a.HC {
			f.leaks[h.Rule] = append(f.leaks[h.Rule], oneLine(file.Display)+":"+strconv.Itoa(h.Line))
		}
		for _, h := range a.Adv {
			f.warns = append(f.warns, oneLine(file.Display)+":"+strconv.Itoa(h.Line))
		}
	}
	return f, readErr
}

func (s *session) say(format string, a ...any) { fmt.Fprintf(s.out, format+"\n", a...) }

// printLeaks writes the high-confidence section body: up to capLeaksPerRule lines per rule.
func (s *session) printLeaks(f findings) {
	for i, r := range rules {
		locs := f.leaks[i]
		for k, loc := range locs {
			if k == capLeaksPerRule {
				s.say("   (%d more %s hit(s) not shown: capped at %d per rule)", len(locs)-k, r.Label, capLeaksPerRule)
				break
			}
			s.say("   LEAK!   %s — %s (value redacted)", r.Label, loc)
			s.rc, s.hits = rcLeak, s.hits+1
		}
	}
	if s.hits == 0 {
		s.say("   (none)")
	}
}

// printAdvisory writes the advisory section: WARN lines never change the exit code.
func (s *session) printAdvisory(f findings) {
	s.say("-- possible credential assignments (advisory) --")
	for k, loc := range f.warns {
		if k == capAdvisoryWarns {
			s.say("   (%d more advisory warning(s) not shown: capped at %d)", len(f.warns)-k, capAdvisoryWarns)
			break
		}
		s.say("   WARN    %s (credential-looking assignment; value redacted)", loc)
		s.warns++
	}
	if s.warns == 0 {
		s.say("   (none)")
	}
}

// printCommitMessages writes the commit-object section from the stream line numbers of the matches.
func (s *session) printCommitMessages(lines []int) {
	s.say("-- commit messages (full history) --")
	for k, n := range lines {
		if k == capCommitMessages {
			s.say("   (%d more commit message hit(s) not shown: capped at %d)", len(lines)-k, capCommitMessages)
			break
		}
		s.say("   LEAK!   [commit msg] line %d (value redacted)", n)
		s.rc, s.hits = rcLeak, s.hits+1
	}
	if len(lines) == 0 {
		s.say("   (none)")
	}
}

// printBinary writes the binary-skip report: working-tree files with a NUL byte were skipped by the text
// (advisory) scan and are surfaced with a real count, never a false zero.
func (s *session) printBinary(nuls int) {
	if s.req.Committed {
		s.say("-- binary files: cat-file blob scan; every blob NUL-stripped and re-scanned unconditionally (B6) — UTF-16/UTF-32 tokens caught --")
		return
	}
	s.nulls = nuls
	if nuls > 0 {
		s.say("-- ⚠ %d in-scope file(s) contain a NUL byte and were SKIPPED by the text scan — inspect manually.", nuls)
	}
}

// printSummary writes the closing lines.
func (s *session) printSummary() {
	s.say("-- summary: %d high-confidence leak(s) · %d advisory warning(s) · %d binary-skipped --", s.hits, s.warns, s.nulls)
	if s.rc == rcOK && s.hits == 0 {
		s.say("   clean IN SCOPE — no secret values in *.md/config files. NOT scanned: non-.md sources/ artifacts")
		s.say("   (decompiled code, snapshots) + vendored trees + Bearer/Basic headers + all-alpha literals — judge those yourself.")
	}
	s.say("== exit %d ==", s.rc)
}
