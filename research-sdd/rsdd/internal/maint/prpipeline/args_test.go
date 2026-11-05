package prpipeline

import "testing"

func TestParseUsageErrors(t *testing.T) {
	for _, c := range []struct {
		name string
		args []string
		want string // "" = accepted
	}{
		{"no arguments", nil, usageLine},
		{"two positionals", []string{"w", "7"}, usageLine},
		{"a value flag with its value and nothing else", []string{"--remote", "r"}, usageLine},
		{"--consent granted and nothing else", []string{"--consent", "granted"}, usageLine},
		{"--consent with a wrong value and nothing else", []string{"--consent", "no"}, "--consent takes the single value: granted"},
		{"four positionals", []string{"w", "7", "b", "x"}, usageLine},
		{"unknown option", []string{"--bogus", "w", "7", "b"}, "unknown option --bogus"},
		{"unknown after a flag", []string{"--serial", "-x", "w", "7", "b"}, "unknown option -x"},
		{"option after positionals", []string{"w", "7", "b", "--serial"}, usageLine},
		{"--consent wrong value", []string{"--consent", "yes", "w", "7", "b"}, "--consent takes the single value: granted"},
		{"--consent last", []string{"--consent"}, "--consent takes the single value: granted"},
		{"--gate-cmd last", []string{"--gate-cmd"}, "--gate-cmd needs a value"},
		{"--size-check last", []string{"--size-check"}, "--size-check needs a value"},
		{"--state-dir last", []string{"--state-dir"}, "--state-dir needs a value"},
		{"--base-ref last", []string{"--base-ref"}, "--base-ref needs a value"},
		{"--remote last", []string{"--remote"}, "--remote needs a value"},
		{"serial with gate-cmd", []string{"--serial", "--gate-cmd", "x", "w", "7", "b"}, "--serial cannot be combined with --gate-cmd"},
		{"gate-cmd with serial", []string{"--gate-cmd", "x", "--serial", "w", "7", "b"}, "--serial cannot be combined with --gate-cmd"},
		{"serial with an empty gate-cmd", []string{"--serial", "--gate-cmd", "", "w", "7", "b"}, ""},
		{"count before combination", []string{"--serial", "--gate-cmd", "x", "w", "7"}, usageLine},
		{"combination before pr", []string{"--serial", "--gate-cmd", "x", "w", "7a", "b"}, "--serial cannot be combined with --gate-cmd"},
		{"pr empty", []string{"w", "", "b"}, "pr must be a number: "},
		{"pr letters", []string{"w", "7a", "b"}, "pr must be a number: 7a"},
		{"pr negative", []string{"w", "-7", "b"}, "pr must be a number: -7"},
		{"double dash", []string{"--", "w", "7", "b"}, ""},
		{"double dash dashed worktree", []string{"--", "-w", "7", "b"}, ""},
		{"help wins over a later error", []string{"-h", "--bogus"}, ""},
		{"help after an error is never reached", []string{"--bogus", "-h"}, "unknown option --bogus"},
		{"flag value may look like a flag", []string{"--remote", "--serial", "w", "7", "b"}, ""},
		{"every option", []string{"--dry-run", "--consent", "granted", "--serial", "--no-gate", "--size-check", "s", "--state-dir", "d", "--base-ref", "B", "--remote", "R", "w", "7", "b"}, ""},
	} {
		_, err := parse(c.args)
		got := ""
		if err != nil {
			got = err.Error()
		}
		if got != c.want {
			t.Errorf("%s: error %q, want %q", c.name, got, c.want)
		}
	}
}

func TestParseValues(t *testing.T) {
	o, err := parse([]string{"--dry-run", "--consent", "granted", "--serial", "--no-gate", "--size-check", "S", "--gate-cmd", "", "--state-dir", "D", "--base-ref", "B", "--remote", "R", "W", "42", "br"})
	want := options{dryRun: true, consent: "granted", serial: true, noGate: true, sizeCheck: "S", state: "D", base: "B", remote: "R", wt: "W", pr: "42", branch: "br"}
	if err != nil || o != want {
		t.Errorf("%+v %v", o, err)
	}
	if o, _ = parse([]string{"W", "1", "b"}); o.base != "origin/main" || o.remote != "origin" || o.consent != "" || o.dryRun || o.noGate || o.serial {
		t.Errorf("defaults: %+v", o)
	}
	if o, _ = parse([]string{"--remote", "a", "--remote", "b", "W", "1", "x"}); o.remote != "b" {
		t.Errorf("the last --remote wins: %+v", o)
	}
	if o, err = parse([]string{"--help"}); err != nil || !o.help {
		t.Errorf("--help: %+v %v", o, err)
	}
}
