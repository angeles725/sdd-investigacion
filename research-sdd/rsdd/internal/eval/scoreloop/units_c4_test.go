package scoreloop

import (
	"math"
	"strings"
	"testing"
)

// Guard-to-test table:
//   classifyNext forms ........................... TestClassifyNext
//   parseQueue / countsOf / queueState.name ...... TestParseQueue
//   statusFailure reasons ........................ TestStatusFailure
//   stripMarkdownWrap, lastLine .................. TestStopLineHelpers
//   graceDeadline saturation ..................... TestGraceDeadline
//   c4Verdict outcome table ...................... TestC4Verdict

func TestClassifyNext(t *testing.T) {
	for _, c := range []struct {
		in        string
		zeroOpen  bool
		qualifier string
	}{
		{"", false, ""}, {"CONTINUE | 3 open", false, ""}, {"STOP", false, ""}, {"STOPPED | x", false, ""},
		{"STOP | read-only-investigable exhausted (0)", true, ""}, {"STOP | outline fully covered (3/4)", true, ""},
		{"STOP | outline fully covered (a/b)", true, "unrecognized STOP form: outline fully covered (a/b)"},
		{"STOP | read-only-investigable exhausted (0) [issue-coverage: unverified]", true, "[issue-coverage: unverified]"},
		{"STOP | exhausted [a: 1] [b: 2] tail", true, "[a: 1] [b: 2]"},
		{"STOP | exhausted [a [b] tail", true, "[a [b]"},
		{"STOP | no active focus (x)", true, "no active focus"},
		{"STOP | no active focus", true, "no active focus"},
		{"STOP | no active focus (x) [m: 1] [n]", true, "no active focus [m: 1] [n]"},
		{"STOP | something else", true, "unrecognized STOP form: something else"},
		{"STOP | ", true, "unrecognized STOP form: "},
		{"STOP x", true, "unrecognized STOP form: STOP x"},
		{"STOP | " + strings.Repeat("0123456789", 9), true, "unrecognized STOP form: " + strings.Repeat("0123456789", 8)},
		{"STOP | " + strings.Repeat("0123456789", 8), true, "unrecognized STOP form: " + strings.Repeat("0123456789", 8)},
		{"STOP | read-only-investigable exhausted (0)\nSTOP | second [z]", true, ""},
		{"info\nSTOP | read-only-investigable exhausted (0)", false, ""},
	} {
		got := classifyNext(c.in)
		if got.zeroOpen != c.zeroOpen || got.qualifier != c.qualifier {
			t.Errorf("classifyNext(%q) = %+v, want zeroOpen=%v qualifier=%q", c.in, got, c.zeroOpen, c.qualifier)
		}
	}
}

func TestParseQueue(t *testing.T) {
	for _, c := range []struct {
		name, report, state string
	}{
		{"empty report", "", "undeclared"},
		{"no campaign line", "x\ny", "undeclared"},
		{"drained", "  campaign : pending=0 active=0 done=2", "empty"},
		{"open pending", "campaign : pending=1 active=0", "non-empty"},
		{"open active", "campaign : pending=0 active=1", "non-empty"},
		{"no counts", "campaign : none (2 active focus(es), 0 with a queue)", "undeclared"},
		{"pending only", "campaign : pending=0", "undeclared"},
		{"active only", "campaign : active=0", "undeclared"},
		{"two drained foci", "campaign[a] : pending=0 active=0\ncampaign[b] : pending=0 active=0", "empty"},
		{"open sibling last", "campaign[a] : pending=0 active=0\ncampaign[b] : pending=2 active=1", "non-empty"},
		{"open sibling first", "campaign[a] : pending=2 active=1\ncampaign[b] : pending=0 active=0", "non-empty"},
		{"countless label then drained", "campaign[a] : none\ncampaign[b] : pending=0 active=0", "empty"},
		{"zero padded", "campaign : pending=00 active=0", "non-empty"},
		{"repeated count is open", "campaign : pending=0 pending=0 active=0", "non-empty"},
		{"colon without spaces", "campaign:pending=0 active=0", "empty"},
		{"label with spaces", "campaign[a b] : pending=0 active=0", "empty"},
		{"embedded in a word", "recampaign : pending=0 active=0", "empty"},
		{"counts but no campaign word", "queue : pending=0 active=0", "undeclared"},
		{"campaign word but no colon", "campaign pending=0 active=0", "undeclared"},
	} {
		if got := parseQueue(c.report).name(); got != c.state {
			t.Errorf("%s: queue %q, want %q", c.name, got, c.state)
		}
	}
}

func TestStatusFailure(t *testing.T) {
	cases := []struct {
		name string
		st   statusOutcome
		want string
	}{
		{"clean", statusOutcome{next: "STOP | x"}, ""},
		{"problem wins", statusOutcome{problem: "bash not found", rcDef: 1}, "bash not found"},
		{"default failed", statusOutcome{rcDef: 1, rcNext: 0}, "research-sdd-status.sh failed (default exit=1, --next exit=0)"},
		{"next failed with stderr", statusOutcome{rcNext: 3, stderrFirstLine: "boom"}, "research-sdd-status.sh failed (default exit=0, --next exit=3): boom"},
		{"stale", statusOutcome{next: "STALE | x\nmore"}, "research-sdd-status.sh --next reports STALE: STALE | x\nmore"},
		{"stale only at the start", statusOutcome{next: "x STALE"}, ""},
		{"failure outranks stale", statusOutcome{rcDef: 2, next: "STALE"}, "research-sdd-status.sh failed (default exit=2, --next exit=0)"},
	}
	for _, c := range cases {
		if got := statusFailure(c.st); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestStopLineHelpers(t *testing.T) {
	for in, want := range map[string]string{"STOP: x": "STOP: x", "**STOP:** x": "STOP:** x", "> `STOP": "STOP", " _ \t STOP:": "STOP:", "": "", "***": "", "a*": "a*"} {
		if got := stripMarkdownWrap(in); got != want {
			t.Errorf("stripMarkdownWrap(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{"": "", "a": "a", "a\nb": "b", "a\nb\nlast": "last", "\nx": "x"} {
		if got := lastLine(in); got != want {
			t.Errorf("lastLine(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestGraceDeadline(t *testing.T) {
	for _, c := range []struct{ stop, min, want int64 }{
		{100, 0, 100}, {100, 10, 700}, {0, 1, 60}, {math.MaxInt64 - 60, 1, math.MaxInt64}, {math.MaxInt64 - 61, 1, math.MaxInt64 - 1},
		{100, math.MaxInt64, math.MaxInt64}, {100, (math.MaxInt64 - 100) / 60, 100 + ((math.MaxInt64-100)/60)*60}, {100, (math.MaxInt64-100)/60 + 1, math.MaxInt64},
	} {
		if got := graceDeadline(c.stop, c.min); got != c.want {
			t.Errorf("graceDeadline(%d, %d) = %d, want %d", c.stop, c.min, got, c.want)
		}
	}
}

func TestSplitAfterStop(t *testing.T) {
	e := []blockEntry{{99, 1}, {100, 2}, {160, 4}, {161, 8}, {200, 16}, {201, 32}}
	for _, c := range []struct {
		name                       string
		grace, last                int64
		explicit                   bool
		wantAfter, wantUnwitnessed int64
	}{
		{"grace edge is inside, one past is outside", 160, 0, false, 2 + 4, 8 + 16 + 32},
		{"span edge is inside, one past is outside", 100, 200, false, 2 + 4 + 8 + 16, 32},
		{"an explicit window counts everything from the stop", 100, 0, true, 2 + 4 + 8 + 16 + 32, 0},
		{"before the stop never counts", 0, 0, false, 0, 2 + 4 + 8 + 16 + 32},
	} {
		a, u := splitAfterStop(e, 100, c.grace, c.last, c.explicit)
		if a != c.wantAfter || u != c.wantUnwitnessed {
			t.Errorf("%s: after %d unwitnessed %d, want %d %d", c.name, a, u, c.wantAfter, c.wantUnwitnessed)
		}
	}
}

func TestC4Verdict(t *testing.T) {
	stopOK := nextVerdict{zeroOpen: true}
	drained, none := queueState{declared: true, empty: true}, queueState{}
	open := queueState{declared: true}
	cases := []struct {
		name string
		in   c4Inputs
		want string
	}{
		{"pass", c4Inputs{stopPresent: true, next: stopOK, queue: drained}, "C4 pass STOP token present; status --next: STOP; campaign queue empty; 0 block commits after STOP"},
		{"no queue", c4Inputs{stopPresent: true, next: stopOK, queue: none}, "C4 n/a no campaign queue declared — cannot verify queue-drain (stop token present; status --next: STOP; 0 block commits after STOP)"},
		{"open queue", c4Inputs{stopPresent: true, next: stopOK, queue: open}, "C4 fail stop_token=present status_next=STOP queue=non-empty commits_after_stop=0"},
		{"qualified drained", c4Inputs{stopPresent: true, next: nextVerdict{true, "[q]"}, queue: drained}, "C4 degraded STOP is qualified — not a clean zero-open exhaustion: [q] (stop token present; campaign queue empty; 0 block commits after STOP)"},
		{"qualified undeclared", c4Inputs{stopPresent: true, next: nextVerdict{true, "[q]"}, queue: none}, "C4 degraded STOP is qualified — not a clean zero-open exhaustion: [q] (no campaign queue declared; 0 block commits after STOP)"},
		{"qualified open queue fails", c4Inputs{stopPresent: true, next: nextVerdict{true, "[q]"}, queue: open}, "C4 fail stop_token=present status_next=STOP queue=non-empty commits_after_stop=0"},
		{"token absent", c4Inputs{next: stopOK, queue: drained}, "C4 fail stop_token=absent status_next=STOP queue=empty commits_after_stop=0"},
		{"next not stop", c4Inputs{stopPresent: true, queue: none}, "C4 fail stop_token=present status_next=NOT-STOP queue=undeclared commits_after_stop=0"},
		{"after stop", c4Inputs{stopPresent: true, next: stopOK, queue: drained, after: 3}, "C4 fail stop_token=present status_next=STOP queue=empty commits_after_stop=3"},
		{"after and unwitnessed", c4Inputs{stopPresent: true, next: stopOK, queue: drained, after: 1, unwitnessed: 2}, "C4 fail stop_token=present status_next=STOP queue=empty commits_after_stop=1 after_stop_unwitnessed=2"},
		{"unwitnessed degrades", c4Inputs{stopPresent: true, next: stopOK, queue: drained, unwitnessed: 2}, "C4 degraded STOP honored inside the transcript but after_stop_unwitnessed=2: block commit(s) landed more than 10 min after STOP and outside the transcript span — cannot attribute them to this run"},
		{"unwitnessed and qualified", c4Inputs{stopPresent: true, next: nextVerdict{true, "[q]"}, queue: drained, unwitnessed: 1}, "C4 degraded STOP honored inside the transcript but after_stop_unwitnessed=1: block commit(s) landed more than 10 min after STOP and outside the transcript span — cannot attribute them to this run; STOP is also qualified: [q]"},
		{"unwitnessed without token fails", c4Inputs{next: stopOK, queue: drained, unwitnessed: 1}, "C4 fail stop_token=absent status_next=STOP queue=empty commits_after_stop=0 after_stop_unwitnessed=1"},
		{"unwitnessed with status not stop fails", c4Inputs{stopPresent: true, queue: drained, unwitnessed: 1}, "C4 fail stop_token=present status_next=NOT-STOP queue=empty commits_after_stop=0 after_stop_unwitnessed=1"},
	}
	for _, c := range cases {
		cfg := cfgWith(t)
		s := &scorer{cfg: cfg, rep: &report{}}
		s.c4Verdict(c.in)
		if len(s.rep.lines) != 1 || s.rep.lines[0] != c.want {
			t.Errorf("%s: %q, want %q", c.name, s.rep.lines, c.want)
		}
	}
}
