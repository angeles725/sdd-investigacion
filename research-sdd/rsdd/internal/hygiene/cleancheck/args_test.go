package cleancheck

import (
	"reflect"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/cleancheck"
)

func TestParseAccepts(t *testing.T) {
	def := cleancheck.Options{StaleHours: 24, BackupDays: 14}
	with := func(f func(o *cleancheck.Options)) cleancheck.Options { o := def; f(&o); return o }
	for name, c := range map[string]struct {
		args []string
		want cleancheck.Options
	}{
		"none":          {nil, def},
		"target":        {[]string{"--target", "t"}, with(func(o *cleancheck.Options) { o.Target = "t" })},
		"tmp":           {[]string{"--tmp", "x"}, with(func(o *cleancheck.Options) { o.Tmp = "x" })},
		"scratchpad":    {[]string{"--scratchpad", "s"}, with(func(o *cleancheck.Options) { o.Scratchpad = "s" })},
		"base":          {[]string{"--base", "b"}, with(func(o *cleancheck.Options) { o.Base = "b" })},
		"evidence":      {[]string{"--evidence", "e"}, with(func(o *cleancheck.Options) { o.Evidence = "e" })},
		"stale":         {[]string{"--stale-hours", "5"}, with(func(o *cleancheck.Options) { o.StaleHours = 5 })},
		"backup":        {[]string{"--backup-days", "7"}, with(func(o *cleancheck.Options) { o.BackupDays = 7 })},
		"zero":          {[]string{"--stale-hours", "0", "--backup-days", "0"}, with(func(o *cleancheck.Options) { o.StaleHours, o.BackupDays = 0, 0 })},
		"leading0":      {[]string{"--stale-hours", "08", "--backup-days", "010"}, with(func(o *cleancheck.Options) { o.StaleHours, o.BackupDays = 8, 10 })},
		"nine digits":   {[]string{"--stale-hours", "999999999"}, with(func(o *cleancheck.Options) { o.StaleHours = 999999999 })},
		"last wins":     {[]string{"--target", "a", "--target", "b", "--stale-hours", "1", "--stale-hours", "2"}, with(func(o *cleancheck.Options) { o.Target = "b"; o.StaleHours = 2 })},
		"flag as value": {[]string{"--target", "--tmp"}, with(func(o *cleancheck.Options) { o.Target = "--tmp" })},
		"all": {[]string{"--target", "t", "--tmp", "m", "--stale-hours", "3", "--scratchpad", "s", "--base", "b", "--evidence", "e", "--backup-days", "4"},
			cleancheck.Options{Target: "t", Tmp: "m", StaleHours: 3, Scratchpad: "s", Base: "b", Evidence: "e", BackupDays: 4}},
	} {
		p, bad := parse(c.args)
		if bad != "" || p.help || !reflect.DeepEqual(p.opts, c.want) {
			t.Errorf("%s: %+v %q, want %+v", name, p.opts, bad, c.want)
		}
	}
}

func TestParseRefuses(t *testing.T) {
	for name, c := range map[string]struct {
		args []string
		want refusal
	}{
		"unknown":             {[]string{"--bogus"}, "unknown argument: --bogus"},
		"positional":          {[]string{"dir"}, "unknown argument: dir"},
		"empty word":          {[]string{""}, "unknown argument: "},
		"target no value":     {[]string{"--target"}, "--target needs a value"},
		"tmp no value":        {[]string{"--tmp"}, "--tmp needs a value"},
		"scratch no value":    {[]string{"--scratchpad"}, "--scratchpad needs a value"},
		"base no value":       {[]string{"--base"}, "--base needs a value"},
		"evidence no value":   {[]string{"--evidence"}, "--evidence needs a value"},
		"backup no value":     {[]string{"--backup-days"}, "--backup-days needs a value"},
		"stale no value":      {[]string{"--stale-hours"}, "--stale-hours needs a value"},
		"empty target":        {[]string{"--target", ""}, "--target needs a non-empty value"},
		"empty tmp":           {[]string{"--tmp", ""}, "--tmp needs a non-empty value"},
		"empty scratchpad":    {[]string{"--scratchpad", ""}, "--scratchpad needs a non-empty value"},
		"empty base":          {[]string{"--base", ""}, "--base needs a non-empty value"},
		"empty evidence":      {[]string{"--evidence", ""}, "--evidence needs a non-empty value"},
		"stale text":          {[]string{"--stale-hours", "abc"}, "--stale-hours must be a decimal integer of at most 9 digits: 'abc'"},
		"stale empty":         {[]string{"--stale-hours", ""}, "--stale-hours must be a decimal integer of at most 9 digits: ''"},
		"stale negative":      {[]string{"--stale-hours", "-1"}, "--stale-hours must be a decimal integer of at most 9 digits: '-1'"},
		"stale plus":          {[]string{"--stale-hours", "+1"}, "--stale-hours must be a decimal integer of at most 9 digits: '+1'"},
		"stale ten digits":    {[]string{"--stale-hours", "1234567890"}, "--stale-hours must be a decimal integer of at most 9 digits: '1234567890'"},
		"stale decimal":       {[]string{"--stale-hours", "1.5"}, "--stale-hours must be a decimal integer of at most 9 digits: '1.5'"},
		"backup text":         {[]string{"--backup-days", "x1"}, "--backup-days must be a decimal integer of at most 9 digits: 'x1'"},
		"backup empty":        {[]string{"--backup-days", ""}, "--backup-days must be a decimal integer of at most 9 digits: ''"},
		"backup ten digits":   {[]string{"--backup-days", "0000000001"}, "--backup-days must be a decimal integer of at most 9 digits: '0000000001'"},
		"stale checked first": {[]string{"--backup-days", "z", "--stale-hours", "y"}, "--stale-hours must be a decimal integer of at most 9 digits: 'y'"},
		"unknown first":       {[]string{"--bogus", "--stale-hours", "abc"}, "unknown argument: --bogus"},
		"value then unknown":  {[]string{"--target", "t", "--bogus"}, "unknown argument: --bogus"},
	} {
		if _, bad := parse(c.args); bad != c.want {
			t.Errorf("%s: %q, want %q", name, bad, c.want)
		}
	}
}

func TestParseHelpEndsTheParse(t *testing.T) {
	for _, args := range [][]string{{"-h"}, {"--help"}, {"-h", "--bogus"}, {"--help", "--stale-hours", "abc"}, {"--target", "t", "-h"}} {
		if p, bad := parse(args); !p.help || bad != "" {
			t.Errorf("%v: help=%v %q", args, p.help, bad)
		}
	}
	if p, bad := parse([]string{"--bogus", "-h"}); p.help || bad == "" {
		t.Error("an unknown argument before -h wins")
	}
	if p, _ := parse([]string{"--target", "-h"}); p.help || p.opts.Target != "-h" {
		t.Error("-h is a value after a value flag")
	}
}
