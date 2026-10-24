package parity

import (
	"path/filepath"
	"strings"
	"testing"
)

func norm(name, pattern string) string {
	s := `{"normalise":"` + name + `","reason":"volatile value"`
	if pattern != "" {
		s += `,"pattern":"` + pattern + `"`
	}
	return s + `}`
}

func intendedFile(entries ...string) map[string]string {
	return map[string]string{"intended.json": "[" + strings.Join(entries, ",") + "]"}
}

func TestNormalisersEqualiseVolatileValues(t *testing.T) {
	tests := []struct {
		name         string
		entries      []string
		legacy, rsdd string
	}{
		{"time rfc3339 utc vs offset", []string{norm("time", "")}, "at 2026-10-19T10:00:00Z", "at 2027-01-02T03:04:05.123+02:00"},
		{"time compact offset", []string{norm("time", "")}, "t=2026-10-19T10:00:00-0600", "t=1999-12-31T23:59:59Z"},
		{"pid declared regex", []string{norm("pid", `pid=[0-9]+`)}, "run pid=123 ok", "run pid=98765 ok"},
		{"temproot", []string{norm("temproot", "")}, "{{sandbox}}/tmp/x", "<TMP>/tmp/x"},
		{"several", []string{norm("time", ""), norm("pid", `pid=[0-9]+`)}, "pid=1 2026-01-01T00:00:00Z", "pid=2 2026-02-02T01:01:01Z"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Without the normaliser the same case must diverge, otherwise the test proves nothing.
			bare := newRig(t)
			res, _ := bare.run([]string{"out=" + tt.legacy}, []string{"out=" + tt.rsdd}, nil)
			if res.Status != StatusFailed {
				t.Fatalf("control: without normalisers this case should fail, got %s", res.Status)
			}
			r := newRig(t)
			res, _ = r.run([]string{"out=" + tt.legacy, "err=" + tt.legacy}, []string{"out=" + tt.rsdd, "err=" + tt.rsdd}, intendedFile(tt.entries...))
			if res.Status != StatusEqual {
				t.Fatalf("normalised streams must compare equal: %s\n%s", res.Status, joined(res.Problems))
			}
		})
	}
}

func TestNormalisersApplyToBothSides(t *testing.T) {
	// A timestamp only on ONE side is a real difference after normalisation (<TIME> vs nothing).
	r := newRig(t)
	res, _ := r.run([]string{"out=x 2026-10-19T10:00:00Z"}, []string{"out=x"}, intendedFile(norm("time", "")))
	if res.Status != StatusFailed || !hasKind(res.Problems, KindUndeclared) {
		t.Fatalf("a one-sided timestamp must still diverge: %s %s", res.Status, joined(res.Problems))
	}
	// Each side's own value is normalised: <TIME> appears in the diff excerpt of the stream.
	if !strings.Contains(joined(res.Problems), "<TIME>") {
		t.Fatalf("diff should show the normalised text: %s", joined(res.Problems))
	}
}

func TestNormaliserAppliesToTheEffectStream(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "x"})
	res := runCorpusCase(t, r, c1,
		[]string{"put={{corpus}}/state|saved 2026-10-19T10:00:00Z"},
		[]string{"put={{corpus}}/state|saved 2030-01-01T00:00:00Z"},
		intendedFile(norm("time", "")))
	if res.Status != StatusEqual {
		t.Fatalf("timestamps inside written files are normalised too: %s %s", res.Status, joined(res.Problems))
	}
}

func TestNormaliserDoesNotMaskRealDifferences(t *testing.T) {
	r := newRig(t)
	res, _ := r.run([]string{"out=at 2026-10-19T10:00:00Z done"}, []string{"out=at 2026-10-19T10:00:00Z gone"}, intendedFile(norm("time", "")))
	if res.Status != StatusFailed {
		t.Fatalf("%s", res.Status)
	}
}

func TestStaleNormalisers(t *testing.T) {
	tests := []struct {
		name  string
		entry string
	}{
		{"time", norm("time", "")},
		{"pid", norm("pid", `pid=[0-9]+`)},
		{"temproot", norm("temproot", "")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t)
			res, _ := r.run([]string{"out=plain"}, []string{"out=plain"}, intendedFile(tt.entry))
			if res.Status != StatusFailed || !hasKind(res.Problems, KindStale) || !strings.Contains(joined(res.Problems), tt.name) {
				t.Fatalf("a normaliser that changed nothing is stale: %s %s", res.Status, joined(res.Problems))
			}
		})
	}
	// Changing only ONE side is enough to not be stale.
	r := newRig(t)
	res, _ := r.run([]string{"out=pid=7"}, []string{"out=pid=7"}, intendedFile(norm("pid", `pid=[0-9]+`)))
	if res.Status != StatusEqual {
		t.Fatalf("a normaliser that did change both sides is live: %s %s", res.Status, joined(res.Problems))
	}
	r = newRig(t)
	res, _ = r.run([]string{"out=pid=7"}, []string{"out=other"}, intendedFile(norm("pid", `pid=[0-9]+`)))
	if hasKind(res.Problems, KindStale) {
		t.Fatalf("a normaliser that changed one side is not stale: %s", joined(res.Problems))
	}
}

func TestNormaliserEntryValidation(t *testing.T) {
	tests := []struct {
		name, entry, kind, want string
	}{
		{"missing reason", `{"normalise":"time"}`, KindNoReason, "time"},
		{"blank reason", `{"normalise":"time","reason":"  "}`, KindNoReason, "time"},
		{"pid without reason", `{"normalise":"pid","pattern":"p[0-9]+"}`, KindNoReason, "pid"},
		{"unknown name", `{"normalise":"uuid","reason":"r"}`, KindSpecInvalid, "uuid"},
		{"pid without pattern", `{"normalise":"pid","reason":"r"}`, KindSpecInvalid, "pattern"},
		{"pid with bad regex", `{"normalise":"pid","pattern":"(","reason":"r"}`, KindSpecInvalid, "pattern"},
		{"pid with empty-matching regex", `{"normalise":"pid","pattern":"x*","reason":"r"}`, KindSpecInvalid, "empty"},
		{"pattern on time", `{"normalise":"time","pattern":"x","reason":"r"}`, KindSpecInvalid, "pattern"},
		{"field and normalise", `{"field":"stdout","normalise":"time","reason":"r"}`, KindSpecInvalid, "exactly one"},
		{"neither", `{"reason":"r"}`, KindSpecInvalid, "exactly one"},
		{"unknown key", `{"normalise":"time","reason":"r","extra":1}`, KindSpecInvalid, "unknown field"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t)
			r.addRaw("c", `{"legacy":["toolbelt/fake.sh","out=a"],"rsdd":["out=a"]}`, intendedFile(tt.entry))
			c := r.load()[0]
			if !hasKind(c.Problems, tt.kind) || !strings.Contains(joined(c.Problems), tt.want) {
				t.Fatalf("want %s containing %q, got %v", tt.kind, tt.want, c.Problems)
			}
			if res := r.runner.RunCase(c, ""); res.Status != StatusFailed {
				t.Fatalf("an invalid normaliser entry must fail the case, got %s", res.Status)
			}
		})
	}
}

func TestGoldenStyleEntriesStillValidNextToNormalisers(t *testing.T) {
	r := newRig(t)
	files := intendedFile(`{"field":"stdout","reason":"golden-format entry"}`, norm("time", ""))
	res, c := r.run([]string{"out=a 2026-01-01T00:00:00Z"}, []string{"out=b 2026-02-02T00:00:00Z"}, files)
	if len(c.Problems) != 0 || res.Status != StatusDeclared {
		t.Fatalf("mixed intended.json: %s %v %s", res.Status, c.Problems, joined(res.Problems))
	}
}

func TestApplyNormalisersUnit(t *testing.T) {
	sb := filepath.Join("/w", "sandbox")
	n, probs := compileNormalisers([]normaliserEntry{{Name: "temproot", Reason: "r"}, {Name: "time", Reason: "r"}})
	if len(probs) != 0 {
		t.Fatal(probs)
	}
	l := Observed{Stdout: []byte(sb + "/a 2026-10-19T10:00:00Z"), Stderr: []byte(sb), Exit: 3, Effect: []byte("t 2026-10-19T10:00:00+01:00")}
	r := Observed{Stdout: []byte("<TMP>/a <TIME>"), Exit: 4}
	nl, nr, sp := applyNormalisers(l, r, n, sb)
	if string(nl.Stdout) != "<TMP>/a <TIME>" || string(nl.Stderr) != "<TMP>" || string(nl.Effect) != "t <TIME>" {
		t.Fatalf("legacy not normalised in every stream: %q %q %q", nl.Stdout, nl.Stderr, nl.Effect)
	}
	if string(nr.Stdout) != "<TMP>/a <TIME>" || nl.Exit != 3 || nr.Exit != 4 {
		t.Fatalf("rsdd/exit mishandled: %q %d %d", nr.Stdout, nl.Exit, nr.Exit)
	}
	if len(sp) != 0 {
		t.Fatalf("both normalisers changed something: %v", sp)
	}
	if string(l.Stdout) != sb+"/a 2026-10-19T10:00:00Z" {
		t.Fatal("inputs must not be mutated in place")
	}
}
