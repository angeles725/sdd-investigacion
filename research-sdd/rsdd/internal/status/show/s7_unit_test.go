package show

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Unit tests of slice S7: the intended divergences from the script (which the differential cannot pin, because the
// script cannot do them) and the pieces under the scenario table.

// s7Ctx is a context over a one-state corpus holding state; Err collects the typed lines, env is the environment.
func s7Ctx(t *testing.T, state string, env map[string]string) (*ctx, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	must(t, os.WriteFile(filepath.Join(root, "RESEARCH-STATE.md"), []byte(state), 0o644))
	var out, errb bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &errb, Env: func(k string) string { return env[k] }, Cwd: root,
		Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }}
	return &ctx{s: s, target: root, state: filepath.Join(root, "RESEARCH-STATE.md"), corpus: root, opts: options{mode: modeStatus, stallMinutes: 15}}, &out, &errb
}

// The age of a timestamp date -d understood only as a phrase is `unknown`, never a number (declared difference).
func TestCampaignAgeRefusesWhatOnlyGNUDateReads(t *testing.T) {
	c, _, errb := s7Ctx(t, "", nil)
	for _, ts := range []string{"yesterday", "now", "@0", "10:00", "1 hour ago", "2026-1-1", "2026-01-01T25:00:00Z", ""} {
		if got := c.campaignAgeMin(ts); got != "unknown" {
			t.Errorf("age of %q = %q, want unknown", ts, got)
		}
	}
	if errb.Len() != 0 {
		t.Errorf("an unreadable timestamp is not a WARN: %q", errb.String())
	}
}

// Without the test hook the clock is the Stdio one; the hook wins over it; a hook that is not an integer is ignored.
func TestCampaignAgeClock(t *testing.T) {
	const ts = "2025-12-31T23:00:00Z"
	for name, c := range map[string]struct {
		env  map[string]string
		want string
	}{
		"clock":         {nil, "60"},
		"hook wins":     {map[string]string{nowEpochHook: "1767229200"}, "120"},
		"hook garbage":  {map[string]string{nowEpochHook: "later"}, "60"},
		"hook negative": {map[string]string{nowEpochHook: "-60"}, "unknown"},
	} {
		cc, _, _ := s7Ctx(t, "", c.env)
		if got := cc.campaignAgeMin(ts); got != c.want {
			t.Errorf("%s: age = %q, want %q", name, got, c.want)
		}
	}
}

// A timestamp in the future is `unknown` with the typed WARN naming the (negative) age.
func TestCampaignAgeInTheFutureWarns(t *testing.T) {
	c, _, errb := s7Ctx(t, "", nil)
	if got := c.campaignAgeMin("2026-01-01T02:00:00Z"); got != "unknown" ||
		errb.String() != "WARN: campaign: last_iteration_ts 2026-01-01T02:00:00Z is in the future relative to now (age -120 min) — reporting unknown\n" {
		t.Errorf("age=%q stderr=%q", got, errb.String())
	}
}

// A timestamp with no zone is local time, as date's is; the forms are the ISO ones the kit writes.
func TestParseISOZoneless(t *testing.T) {
	for _, ts := range []string{"2025-12-31T23:00:00", "2025-12-31T23:00", "2025-12-31"} {
		want, err := time.ParseInLocation(map[int]string{19: "2006-01-02T15:04:05", 16: "2006-01-02T15:04", 10: "2006-01-02"}[len(ts)], ts, time.Local)
		must(t, err)
		if got, ok := parseISO(ts); !ok || got != want.Unix() {
			t.Errorf("%s: got %d %v, want %d", ts, got, ok, want.Unix())
		}
	}
}

// An Outline row whose item cell is empty keeps its status: the script read its rows back through a tab-separated
// `read` that collapsed the empty field and shifted the status into the item (declared difference).
func TestOutlineRowWithAnEmptyItemKeepsItsStatus(t *testing.T) {
	c, _, _ := s7Ctx(t, docState(outlineSection(orow("1", "", "covered"), orow("2", "b", "pending"))), nil)
	if got := c.outlineLine(); got != "  outline         : 1/2 covered · drafted=0 · pending=1" {
		t.Errorf("outline line = %q", got)
	}
	if got := c.outlineNextStep(); got != "NEXT | outline #2 | b" {
		t.Errorf("next step = %q", got)
	}
}

// A tab inside an item is part of the item (the same tab-separated read split it).
func TestOutlineItemMayHoldATab(t *testing.T) {
	c, _, _ := s7Ctx(t, docState(outlineSection(orow("1", "a\tb", "pending"))), nil)
	if got := c.outlineNextStep(); got != "NEXT | outline #1 | a\tb" {
		t.Errorf("next step = %q", got)
	}
}

// summarize keeps the three table states and the first open row apart.
func TestSummarize(t *testing.T) {
	rows := []outlineRow{{"1", "<x>", "pending"}, {"2", "a", "covered"}, {"3", "b", "wip"}, {"4", "c", "drafted"}}
	s := summarize(rows)
	if s.state != "seeded" || s.total != 3 || s.cov != 1 || s.other != 1 || s.dra != 1 || s.pen != 0 || s.first == nil || s.first.num != "3" {
		t.Errorf("summary = %+v", s)
	}
	if s := summarize(rows[:1]); s.state != "unseeded" || s.first != nil {
		t.Errorf("placeholder only = %+v", s)
	}
	if s := summarize(nil); s.state != "empty" {
		t.Errorf("no rows = %+v", s)
	}
	if s := summarize(rows[1:2]); s.first != nil || s.cov != 1 {
		t.Errorf("all covered = %+v", s)
	}
}

// The detection answers the three modes and ignores a corpus with more than one state file.
func TestDocModeOf(t *testing.T) {
	for name, c := range map[string]struct {
		state string
		want  docMode
	}{
		"outline":    {docState(outlineSection()), docOutline},
		"no heading": {docState(""), docNoHeading},
		"other":      {envWith(st6(0, ""), "method: sweep"), docNone},
		"external":   {envWith(st6(0, outlineSection()), "method: document-cycle-external"), docNone},
		"no method":  {st6(0, outlineSection()), docNone},
		"unreadable": {"", docNone},
	} {
		cc, _, _ := s7Ctx(t, c.state, nil)
		if got := cc.docModeOf(); got != c.want {
			t.Errorf("%s: mode = %v, want %v", name, got, c.want)
		}
	}
	c, _, _ := s7Ctx(t, docState(outlineSection()), nil)
	must(t, os.WriteFile(filepath.Join(c.corpus, "RESEARCH-STATE-b.md"), []byte(st6(0, "")), 0o644))
	if got := c.docModeOf(); got != docNone {
		t.Errorf("two state files: mode = %v, want none", got)
	}
}

// sectionField strips the key, the colon and the blanks, and keeps the rest of the line.
func TestSectionField(t *testing.T) {
	sec := "x: 1\nlast_audit:  \t a b  \nlast_audit: second\n  last_audit: indented\n"
	if got := sectionField(sec, "last_audit"); got != "a b  " {
		t.Errorf("got %q", got)
	}
	if got := sectionField(sec, "campaign_stop"); got != "" {
		t.Errorf("absent key = %q", got)
	}
	if got := sectionField(strings.ReplaceAll(sec, "  \t ", "\r"), "last_audit"); got != "a b  " {
		t.Errorf("a CR counts as space: %q", got)
	}
}
