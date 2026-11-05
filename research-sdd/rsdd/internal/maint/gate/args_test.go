package gate

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

func TestParseUsageErrors(t *testing.T) {
	const usage = "kit-gate.sh [--cmd CMD] [--state-dir DIR] <worktree> <label>"
	for _, c := range []struct {
		name string
		args []string
		want string // "" = accepted
	}{
		{"no arguments", nil, usage},
		{"one positional", []string{"wt"}, usage},
		{"three positionals", []string{"wt", "l", "x"}, usage},
		{"only options", []string{"--serial"}, usage},
		{"a value flag with its value and nothing else", []string{"--state-dir", "d"}, usage},
		{"--cmd with its value and nothing else", []string{"--cmd", "c"}, usage},
		{"unknown option first", []string{"--bogus", "wt", "l"}, "unknown option --bogus"},
		{"unknown option last", []string{"wt", "l", "--bogus"}, usage}, // a positional ended the options
		{"unknown option after flags", []string{"--serial", "-x", "wt", "l"}, "unknown option -x"},
		{"--cmd last", []string{"--cmd"}, "--cmd needs a value"},
		{"--lock-timeout last", []string{"--serial", "--lock-timeout"}, "--lock-timeout needs a value"},
		{"--state-dir last", []string{"--state-dir"}, "--state-dir needs a value"},
		{"--cmd takes the next word whatever it is", []string{"--cmd", "--serial", "wt", "l"}, ""},
		{"label empty", []string{"wt", ""}, "label must match [A-Za-z0-9._-]+"},
		{"label with slash", []string{"wt", "a/b"}, "label must match [A-Za-z0-9._-]+"},
		{"label with space", []string{"wt", "a b"}, "label must match [A-Za-z0-9._-]+"},
		{"label every class", []string{"wt", "aZ09._-"}, ""},
		{"lock timeout letters", []string{"--lock-timeout", "1s", "wt", "l"}, "--lock-timeout must be a number of seconds"},
		{"lock timeout empty", []string{"--lock-timeout", "", "wt", "l"}, "--lock-timeout must be a number of seconds"},
		{"lock timeout negative", []string{"--lock-timeout", "-1", "wt", "l"}, "--lock-timeout must be a number of seconds"},
		{"lock timeout zero", []string{"--lock-timeout", "0", "wt", "l"}, ""},
		{"serial with cmd", []string{"--serial", "--cmd", "true", "wt", "l"}, "--serial cannot be combined with --cmd"},
		{"cmd then serial", []string{"--cmd", "true", "--serial", "wt", "l"}, "--serial cannot be combined with --cmd"},
		{"empty cmd with serial", []string{"--cmd", "", "--serial", "wt", "l"}, "--serial cannot be combined with --cmd"},
		{"label is checked before the lock timeout", []string{"--lock-timeout", "x", "wt", "a/b"}, "label must match [A-Za-z0-9._-]+"},
		{"lock timeout is checked before serial/cmd", []string{"--lock-timeout", "x", "--serial", "--cmd", "c", "wt", "l"}, "--lock-timeout must be a number of seconds"},
		{"double dash ends the options", []string{"--", "-wt", "l"}, ""},
		{"double dash then too few", []string{"--", "wt"}, usage},
		{"options after the dash are positionals", []string{"--", "wt", "--serial"}, ""},
		{"help wins over later errors", []string{"-h", "--bogus"}, ""},
		{"long help", []string{"--serial", "--help"}, ""},
		{"help after an error is never reached", []string{"--bogus", "-h"}, "unknown option --bogus"},
		{"all options", []string{"--state-dir", "s", "--lock-timeout", "5", "--cmd", "c", "wt", "l"}, ""},
	} {
		_, err := parse(c.args, "")
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
	o, err := parse([]string{"--state-dir", "S", "--cmd", "C", "--lock-timeout", "7", "W", "L"}, "")
	if err != nil || o.state != "S" || o.cmd != "C" || !o.cmdGiven || o.lockTimeout != "7" || o.wt != "W" || o.label != "L" || o.serial || o.help {
		t.Errorf("%+v %v", o, err)
	}
	if o, _ = parse([]string{"--serial", "W", "L"}, ""); !o.serial || o.cmdGiven || o.lockTimeout != "14400" {
		t.Errorf("serial/default timeout: %+v", o)
	}
	if o, _ = parse([]string{"W", "L"}, "9"); o.lockTimeout != "9" {
		t.Errorf("env timeout: %+v", o)
	}
	if o, _ = parse([]string{"--lock-timeout", "3", "W", "L"}, "9"); o.lockTimeout != "3" {
		t.Errorf("flag beats env: %+v", o)
	}
	if o, _ = parse([]string{"--", "-W", "L"}, ""); o.wt != "-W" {
		t.Errorf("after --: %+v", o)
	}
	if o, _ = parse([]string{"--cmd", "a", "--cmd", "b", "W", "L"}, ""); o.cmd != "b" {
		t.Errorf("the last --cmd wins: %+v", o)
	}
	if o, err = parse([]string{"-h"}, ""); err != nil || !o.help {
		t.Errorf("-h: %+v %v", o, err)
	}
}

func TestHelpIsTheHeaderOfTheTool(t *testing.T) {
	w := kitworld.New(t)
	r := goRun(w, []string{"--help"})
	if r.rc != 0 || r.err != "" || r.out != help || !strings.HasPrefix(r.out, "# kit-gate.sh [--serial | --cmd CMD] [--state-dir DIR]") ||
		!strings.Contains(r.out, "#   22  gate-lock-timeout  the gate lock was not obtained within --lock-timeout") {
		t.Errorf("%+v", r)
	}
}
