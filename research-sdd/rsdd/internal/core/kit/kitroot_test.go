package kit

import (
	"errors"
	"strings"
	"testing"
)

const (
	envWarnFmt  = "kit-run: DEGRADED: RESEARCH_SDD_KIT=%s invalid (no toolbelt/ directory); trying the launcher files and the default checkout"
	notFoundMsg = "research-sdd kit not found (set RESEARCH_SDD_KIT)"
)

// rootCase is one state of the kit-root resolution. want is the root relative to HOME ("" when none resolves).
type rootCase struct {
	label string
	setup func(e *kitEnv)
	want  string
	warn  string // the expected warning with "$H" for HOME ("" for none)
	err   string // the expected error text with "$H" for HOME ("" for none)
	typed error  // the extra sentinel the error must match (besides ErrKitUnresolved)
}

const defaultKit = "investigacion/sdd-investigacion/research-sdd"

var rootCases = []rootCase{
	{label: "the only candidate is the default checkout", setup: func(e *kitEnv) { e.kit(defaultKit) }, want: defaultKit},
	{label: "the first candidate wins", setup: func(e *kitEnv) {
		e.env["RESEARCH_SDD_KIT"] = e.kit("envkit")
		e.kit(defaultKit)
	}, want: "envkit"},
	{label: "a middle candidate wins over the later ones", setup: func(e *kitEnv) {
		e.kit("mid")
		e.kit(defaultKit)
		e.launcher(".claude/CLAUDE.md", "Kit checkout: ~/mid\n")
	}, want: "mid"},
	{label: "the last candidate wins when the others are not kits", setup: func(e *kitEnv) {
		e.kit(defaultKit)
		e.launcher(".claude/CLAUDE.md", "Kit checkout: ~/absent\n")
	}, want: defaultKit},
	{label: "the winner is returned as written", setup: func(e *kitEnv) {
		e.env["RESEARCH_SDD_KIT"] = e.kit("envkit") + "/"
	}, want: "envkit/"},
	{label: "an invalid RESEARCH_SDD_KIT warns once and resolution goes on", setup: func(e *kitEnv) {
		e.env["RESEARCH_SDD_KIT"] = e.home + "/nokit"
		e.kit(defaultKit)
	}, want: defaultKit, warn: "$H/nokit"},
	{label: "an invalid RESEARCH_SDD_KIT that exists warns too", setup: func(e *kitEnv) {
		write(e.t, e.home+"/bare/x", "")
		e.env["RESEARCH_SDD_KIT"] = e.home + "/bare"
		e.kit(defaultKit)
	}, want: defaultKit, warn: "$H/bare"},
	{label: "no candidate is a directory", setup: func(e *kitEnv) {}, err: notFoundMsg},
	{label: "no candidate is a directory after an invalid RESEARCH_SDD_KIT", setup: func(e *kitEnv) {
		e.env["RESEARCH_SDD_KIT"] = e.home + "/nokit"
	}, warn: "$H/nokit", err: notFoundMsg},
	{label: "a directory without toolbelt is named", setup: func(e *kitEnv) {
		write(e.t, e.home+"/bare/x", "")
		e.env["RESEARCH_SDD_KIT"] = e.home + "/bare"
	}, warn: "$H/bare", err: "research-sdd kit has no toolbelt/ directory: $H/bare (set RESEARCH_SDD_KIT)", typed: ErrKitNoToolbelt},
	{label: "the first such directory is the one named", setup: func(e *kitEnv) {
		e.env["RESEARCH_SDD_KIT"] = e.home + "/nokit"
		write(e.t, e.home+"/first/x", "")
		write(e.t, e.home+"/second/x", "")
		e.launcher(".claude/CLAUDE.md", "Kit checkout: ~/absent\nKit path: ~/first\nKit checkout: ~/second\n")
	}, warn: "$H/nokit", err: "research-sdd kit has no toolbelt/ directory: $H/first (set RESEARCH_SDD_KIT)", typed: ErrKitNoToolbelt},
	{label: "a file is not a directory", setup: func(e *kitEnv) {
		write(e.t, e.home+"/afile", "")
		e.env["RESEARCH_SDD_KIT"] = e.home + "/afile"
	}, warn: "$H/afile", err: notFoundMsg},
}

func TestResolveKitRoot(t *testing.T) {
	for _, c := range rootCases {
		t.Run(c.label, func(t *testing.T) {
			e := newKitEnv(t)
			c.setup(e)
			got, warns, err := ResolveKitRoot(envOf(e.env))
			want := ""
			if c.want != "" {
				want = e.home + "/" + c.want
			}
			if got != want {
				t.Errorf("root %q, want %q", got, want)
			}
			var wantWarns []string
			if c.warn != "" {
				wantWarns = []string{sprintfH(envWarnFmt, c.warn, e.home)}
			}
			if len(warns) != len(wantWarns) || (len(warns) == 1 && warns[0] != wantWarns[0]) {
				t.Errorf("warnings %q, want %q", warns, wantWarns)
			}
			reason := ""
			if err != nil {
				reason = err.Error()
			}
			if reason != strings.ReplaceAll(c.err, "$H", e.home) {
				t.Errorf("error %q, want %q", reason, strings.ReplaceAll(c.err, "$H", e.home))
			}
			if c.err != "" && !errors.Is(err, ErrKitUnresolved) {
				t.Errorf("not an ErrKitUnresolved: %v", err)
			}
			if got := errors.Is(err, ErrKitNoToolbelt); got != (c.typed != nil) {
				t.Errorf("errors.Is(ErrKitNoToolbelt) = %v, want %v", got, c.typed != nil)
			}
		})
	}
}

// sprintfH expands the "$H" of arg and puts it in the one %s of format.
func sprintfH(format, arg, home string) string {
	return strings.Replace(format, "%s", strings.ReplaceAll(arg, "$H", home), 1)
}

// A directory that is no kit leaves ResolveKitScript's text as it was: the typed "no toolbelt" state is the
// resolver's own, never printed by the hook port.
func TestResolveKitScriptKeepsNotFoundTextForABareDirectory(t *testing.T) {
	e := newKitEnv(t)
	write(e.t, e.home+"/bare/x", "")
	e.env["RESEARCH_SDD_KIT"] = e.home + "/bare"
	got, warns, err := ResolveKitScript("toolbelt/probe.sh", envOf(e.env))
	if got != "" || len(warns) != 1 || err == nil || err.Error() != notFoundMsg || !errors.Is(err, ErrKitUnresolved) || errors.Is(err, ErrKitNoToolbelt) {
		t.Fatalf("got %q %q %v", got, warns, err)
	}
}
