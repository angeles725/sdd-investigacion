package state

import "testing"

var stateCases = []struct {
	s    State
	name string
	exit int
}{
	{OK, "ok", 0},
	{AbsentInput, "absent-input", 0},
	{EmptyInput, "empty-input", 0},
	{NoMatch, "no-match", 0},
	{Degraded, "degraded", 3},
}

func TestStateStringParseExit(t *testing.T) {
	for _, c := range stateCases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.s.String(); got != c.name {
				t.Fatalf("String() = %q, want %q", got, c.name)
			}
			p, err := Parse(c.name)
			if err != nil || p != c.s {
				t.Fatalf("Parse(%q) = %v, %v; want %v", c.name, p, err, c.s)
			}
			code, err := c.s.ExitCode()
			if err != nil || code != c.exit {
				t.Fatalf("ExitCode() = %d, %v; want %d", code, err, c.exit)
			}
		})
	}
}

func TestStateAllIsExhaustiveAndOrdered(t *testing.T) {
	all := All()
	if len(all) != len(stateCases) {
		t.Fatalf("All() has %d states, want %d", len(all), len(stateCases))
	}
	for i, c := range stateCases {
		if all[i] != c.s {
			t.Fatalf("All()[%d] = %v, want %v", i, all[i], c.s)
		}
	}
}

func TestStateRejectsUnknown(t *testing.T) {
	for _, in := range []string{"", "OK", "Ok", " ok", "ok ", "unclassifiable", "absent", "degrade", "nomatch"} {
		if s, err := Parse(in); err == nil || s != Invalid {
			t.Errorf("Parse(%q) = %v, %v; want Invalid and an error", in, s, err)
		}
	}
}

func TestInvalidStateNeverDefaults(t *testing.T) {
	for _, s := range []State{Invalid, State(-1), State(99)} {
		if s.String() != "invalid" {
			t.Errorf("State(%d).String() = %q, want invalid", int(s), s.String())
		}
		if code, err := s.ExitCode(); err == nil {
			t.Errorf("State(%d).ExitCode() = %d, nil; want an error", int(s), code)
		}
	}
}

var inputCases = []struct {
	c    InputClass
	name string
}{
	{InputAbsent, "absent-input"},
	{InputEmpty, "empty-input"},
	{InputUnclassifiable, "unclassifiable"},
	{InputNoMatch, "no-match"},
}

func TestInputClassStringParse(t *testing.T) {
	all := AllInputClasses()
	if len(all) != len(inputCases) {
		t.Fatalf("AllInputClasses() has %d, want %d", len(all), len(inputCases))
	}
	for i, c := range inputCases {
		if all[i] != c.c {
			t.Errorf("AllInputClasses()[%d] = %v, want %v", i, all[i], c.c)
		}
		if got := c.c.String(); got != c.name {
			t.Errorf("String() = %q, want %q", got, c.name)
		}
		p, err := ParseInputClass(c.name)
		if err != nil || p != c.c {
			t.Errorf("ParseInputClass(%q) = %v, %v; want %v", c.name, p, err, c.c)
		}
	}
}

func TestInputClassRejectsUnknownAndStates(t *testing.T) {
	// "ok" and "degraded" are states, not input classes; "unclassifiable" is an input class, not a state.
	for _, in := range []string{"", "ok", "degraded", "Unclassifiable", "absent"} {
		if c, err := ParseInputClass(in); err == nil || c != InvalidInput {
			t.Errorf("ParseInputClass(%q) = %v, %v; want InvalidInput and an error", in, c, err)
		}
	}
	if s, err := Parse("unclassifiable"); err == nil {
		t.Errorf("Parse(unclassifiable) = %v, nil; want an error (not an envelope state)", s)
	}
	if InvalidInput.String() != "invalid" || InputClass(42).String() != "invalid" {
		t.Error("invalid InputClass must stringify as invalid")
	}
}
