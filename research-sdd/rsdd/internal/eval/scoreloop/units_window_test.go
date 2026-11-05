package scoreloop

import (
	"bytes"
	"strings"
	"testing"

	gitrun "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// Guard-to-test table:
//   parseLog examined, short lines, bad dates, sort, warn .... TestParseLog
//   scan failure messages ................................... TestScanFailure
//   loadTranscript unreadable file, span, folds ............. TestLoadTranscript, TestFactsFold
//   operatorGaps boundaries ................................. TestOperatorGaps
//   outOfSpan weights ....................................... TestOutOfSpan

func newWindow(t *testing.T) (*window, *bytes.Buffer) {
	t.Helper()
	var errw bytes.Buffer
	return &window{cfg: cfgWith(t), errw: &errw}, &errw
}

func TestParseLog(t *testing.T) {
	w, errw := newWindow(t)
	log := strings.Join([]string{
		"aaa\t2026-06-01T00:20:00+00:00\tresearch(d): B2 b",
		"",
		"bbb\t2026-06-01T00:10:00+00:00\tresearch(d): B1-B3 a",
		"ccc\tnot-a-date\tresearch(d): B9 bad date",
		"ddd\t2026-06-01T00:15:00+00:00\tchore: nothing",
		"eee\t2026-06-01T00:30:00+00:00\tresearch(d): B1-B99 big",
		"fff\t2026-06-01T00:40:00+00:00",
		"ggg",
		"",
	}, "\n")
	res := w.parseLog(log)
	if res.examined != 7 || res.tsErrors != 1 {
		t.Errorf("examined %d, tsErrors %d", res.examined, res.tsErrors)
	}
	want := []blockEntry{{1780272600, 3}, {1780273200, 1}, {1780273800, 1}}
	if len(res.entries) != len(want) {
		t.Fatalf("entries %+v", res.entries)
	}
	for i := range want {
		if res.entries[i] != want[i] {
			t.Errorf("entry %d = %+v, want %+v", i, res.entries[i], want[i])
		}
	}
	if got, want := errw.String(), "score-loop-transcript.sh: WARN: implausible block range B1-B99 in commit eee (span >50) — counting as 1 block\n"; got != want {
		t.Errorf("warning %q, want %q", got, want)
	}
}

func TestParseLogKeepsTabsOfTheSubject(t *testing.T) {
	w, _ := newWindow(t)
	res := w.parseLog("aaa\t2026-06-01T00:20:00+00:00\tresearch(d): B1\tgap\tmore\n")
	if res.examined != 1 || len(res.entries) != 1 {
		t.Errorf("%+v", res)
	}
}

func TestScanFailure(t *testing.T) {
	w, _ := newWindow(t)
	w.git = gitrun.Runner{Bin: "/nonexistent/git", Env: []string{"PATH=/nonexistent"}}
	w.corpus = t.TempDir()
	_, err := w.scan("", "")
	if err == nil || !strings.HasPrefix(err.Error(), "score-loop-transcript.sh: git log failed (") || !strings.Contains(err.Error(), "for window 'HEAD': ") {
		t.Errorf("missing git: %v", err)
	}
	w.baseRef = "main"
	if _, err = w.scan("", ""); err == nil || !strings.Contains(err.Error(), "for window 'main..HEAD'") {
		t.Errorf("base ref window: %v", err)
	}
	ee := &gitrun.ExitError{Code: 128, Stderr: "fatal: bad\nrevision\n"}
	if gitFailure(ee) != "exit 128" || gitStderr(ee) != "fatal: bad revision " {
		t.Errorf("exit error: %q %q", gitFailure(ee), gitStderr(ee))
	}
}

func TestLoadTranscript(t *testing.T) {
	cfg := cfgWith(t)
	f := loadTranscript("/nonexistent/transcript.jsonl", cfg, nil)
	if !f.Given || !f.ParseFailed || f.usable() {
		t.Errorf("unreadable: %+v", f)
	}
	if f.unrecognized() {
		t.Error("an unreadable transcript is degraded as unparsable, not as unrecognised")
	}
	f = &Facts{Given: true, AnyOrigin: true, OperatorEpochs: []int64{1}}
	if f.unrecognized() {
		t.Error("a transcript with an operator turn and origin is recognised")
	}
	if !(&Facts{Given: true, AnyOrigin: false, OperatorEpochs: []int64{1}}).unrecognized() {
		t.Error("no origin anywhere is unrecognised")
	}
	if !(&Facts{Given: true, AnyOrigin: true}).unrecognized() {
		t.Error("no operator and no assistant record is unrecognised")
	}
	if (&Facts{Given: true, AnyOrigin: true, FinalParas: []string{""}}).unrecognized() {
		t.Error("an assistant record alone is recognised")
	}
	if (&Facts{Given: true, ParseFailed: true}).unrecognized() || (&Facts{Given: true, MissingTool: "jq"}).unrecognized() || (&Facts{}).unrecognized() {
		t.Error("an unusable or absent transcript is never unrecognised")
	}
}

func TestFactsFold(t *testing.T) {
	r := func(ts, typ string, op, cx bool, para string) row {
		when, _ := parseTimestamp(ts)
		return row{when: when, ts: ts, typ: typ, operator: op, compact: cx, para: para}
	}
	rows := []row{
		r("2026-06-01T00:00:00Z", "user", true, false, ""),
		r("2026-06-01T00:05:00Z", "assistant", false, false, "first"),
		r("2026-06-01T00:06:00Z", "assistant", false, true, "second"),
		r("2026-06-01T00:07:00Z", "system", false, true, ""),
		r("2026-06-01T00:08:00Z", "user", true, false, ""),
		r("2026-06-01T00:09:00Z", "assistant", false, false, "third"),
	}
	var f Facts
	f.fold(rows)
	if !f.HasSpan || f.FirstISO != "2026-06-01T00:00:00Z" || f.LastISO != "2026-06-01T00:09:00Z" || f.FirstEpoch != 1780272000 || f.LastEpoch != 1780272540 {
		t.Errorf("span: %+v", f)
	}
	if !f.HasCompaction || f.FirstCompaction != 1780272360 {
		t.Errorf("the first compaction wins: %+v", f)
	}
	if len(f.OperatorEpochs) != 2 || len(f.FinalParas) != 2 || f.FinalParas[0] != "second" || f.FinalParas[1] != "third" || f.FinalEpochs[0] != 1780272360 {
		t.Errorf("operators %v finals %v %v", f.OperatorEpochs, f.FinalParas, f.FinalEpochs)
	}
	var empty Facts
	empty.fold(nil)
	if empty.HasSpan || empty.HasCompaction || len(empty.FinalParas) != 0 {
		t.Errorf("no rows: %+v", empty)
	}
	var tail Facts
	tail.fold([]row{r("2026-06-01T00:00:00Z", "assistant", false, false, "only")})
	if len(tail.FinalParas) != 1 || tail.FinalParas[0] != "only" {
		t.Errorf("a trailing assistant record is a final message: %+v", tail)
	}
}

func TestOperatorGaps(t *testing.T) {
	s := &scorer{facts: &Facts{OperatorEpochs: []int64{15, 25, 25}}}
	s.blocks = []blockEntry{{10, 1}, {20, 3}, {30, 1}, {40, 2}}
	if got := s.operatorGaps(); got != 2 {
		t.Errorf("gaps %d, want 2 (10-20 and 20-30; 30-40 is clear)", got)
	}
	s.facts.OperatorEpochs = []int64{10, 20, 30, 40, 5, 45}
	if got := s.operatorGaps(); got != 0 {
		t.Errorf("a turn exactly at a commit is not between: %d", got)
	}
	s.facts.OperatorEpochs = nil
	if got := s.operatorGaps(); got != 0 {
		t.Errorf("no turns: %d", got)
	}
	s.blocks = []blockEntry{{10, 5}}
	s.facts.OperatorEpochs = []int64{10}
	if got := s.operatorGaps(); got != 0 {
		t.Errorf("one commit has no boundary: %d", got)
	}
}

func TestOutOfSpan(t *testing.T) {
	s := &scorer{facts: &Facts{HasSpan: true, FirstEpoch: 100, LastEpoch: 200}, blocks: []blockEntry{{99, 2}, {100, 1}, {200, 1}, {201, 4}}}
	if got := s.outOfSpan(); got != 6 {
		t.Errorf("outOfSpan = %d, want 6 (the span edges are inside)", got)
	}
	s.facts.HasSpan = false
	if got := s.outOfSpan(); got != 0 {
		t.Errorf("no span: %d", got)
	}
}

func TestReportWrite(t *testing.T) {
	r := &report{}
	r.emit("C1", statusPass, "a")
	r.emit("C2", statusFail, "b")
	r.emit("C3", statusNA, "c")
	r.emit("C4", statusDegraded, "d")
	r.emit("C5", statusDegraded, "e")
	var b bytes.Buffer
	r.write(&b, true)
	if got, want := b.String(), "C1 pass a\nC2 fail b\nC3 n/a c\nC4 degraded d\nC5 degraded e\nSUMMARY pass=1 fail=1 n/a=1 degraded=2\n"; got != want {
		t.Errorf("report %q", got)
	}
	b.Reset()
	r.write(&b, false)
	if strings.Contains(b.String(), "SUMMARY") {
		t.Errorf("an incomplete report has no summary: %q", b.String())
	}
}
