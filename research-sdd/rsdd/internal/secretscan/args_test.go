package secretscan

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// stdio is a hermetic Stdio rooted at cwd.
func stdio(cwd, stdin string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	return cli.Stdio{
		In: strings.NewReader(stdin), Out: &out, Err: &errb,
		Env:     func(k string) string { return os.Getenv(k) },
		Environ: os.Environ,
		Clock:   time.Now,
		Cwd:     cwd,
	}, &out, &errb
}

func run(t *testing.T, cwd string, args ...string) (int, string, string) {
	t.Helper()
	s, out, errb := stdio(cwd, "")
	code := cli.Run(Commands, append([]string{"secrets", "scan"}, args...), s)
	return code, out.String(), errb.String()
}

const usage = "usage: scan-secrets.sh [--committed | --files-from <list|->] <target-dir>\n"

func corpus(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "a.md"), []byte("clean\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return d
}

// The legacy usage messages (byte for byte) and exit codes.
func TestUsageErrorsKeepTheLegacyText(t *testing.T) {
	d := corpus(t)
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"no arguments", nil, usage},
		{"target is not a directory", []string{filepath.Join(d, "a.md")}, usage},
		{"empty target", []string{""}, usage},
		{"target is a lone dash", []string{"-"}, usage},
		{"missing target after flag", []string{"--committed"}, usage},
		{"files-from needs a value", []string{"--files-from"}, "usage: scan-secrets.sh --files-from requires a list file (or - for stdin)\n"},
		{"files-from empty value", []string{"--files-from", "", d}, "usage: scan-secrets.sh --files-from requires a list file (or - for stdin)\n"},
		{"files-from with committed", []string{"--files-from", "x", "--committed", d}, "usage: scan-secrets.sh --files-from cannot be combined with --committed (history is not a file set)\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, out, errs := run(t, d, tc.args...)
			if code != 2 || out != "" || errs != tc.want {
				t.Errorf("exit %d stdout %q stderr %q; want exit 2, no stdout, stderr %q", code, out, errs, tc.want)
			}
		})
	}
}

// The strict parser (kit CLAUDE.md section 7: an unknown word is a usage error, never silently ignored).
func TestStrictParserRejectsWhatTheLegacyIgnored(t *testing.T) {
	d := corpus(t)
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"unknown flag", []string{"--bogus", d}, "scan-secrets.sh: unknown argument: --bogus\n" + usage},
		{"unknown flag after target", []string{d, "--bogus"}, "scan-secrets.sh: unknown argument: --bogus\n" + usage},
		{"second target", []string{d, d}, "scan-secrets.sh: unexpected extra argument: " + d + "\n" + usage},
		{"committed twice", []string{"--committed", "--committed", d}, "scan-secrets.sh: --committed given twice\n" + usage},
		{"files-from twice", []string{"--files-from", "a", "--files-from", "b", d}, "scan-secrets.sh: --files-from given twice\n" + usage},
		{"toolbelt without value", []string{"--toolbelt"}, "scan-secrets.sh: --toolbelt needs exactly one directory\n" + usage},
		{"toolbelt twice", []string{"--toolbelt", d, "--toolbelt", d, d}, "scan-secrets.sh: --toolbelt needs exactly one directory\n" + usage},
		{"help is not a target", []string{"--help"}, "scan-secrets.sh: unknown argument: --help\n" + usage},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, out, errs := run(t, d, tc.args...)
			if code != 2 || out != "" || errs != tc.want {
				t.Errorf("exit %d stdout %q stderr %q; want exit 2, no stdout, stderr %q", code, out, errs, tc.want)
			}
		})
	}
}

// A flag after the target is honoured: the legacy script read --committed only as the FIRST word, so
// `scan-secrets.sh dir --committed` silently scanned the working tree instead of the history.
func TestCommittedAfterTheTargetIsHonoured(t *testing.T) {
	d := corpus(t) // not a repository: a history scan must refuse, a working-tree scan would say clean
	code, out, errs := run(t, d, d, "--committed")
	if code != 3 || out != "" || !strings.Contains(errs, "DEGRADED: "+d+" is not a git repository") {
		t.Errorf("exit %d stdout %q stderr %q; want the committed refusal", code, out, errs)
	}
}

func TestDoubleDashEndsTheOptions(t *testing.T) {
	d := corpus(t)
	if code, out, _ := run(t, d, "--", d); code != 0 || !strings.Contains(out, "== scan-secrets: ") {
		t.Errorf("exit %d stdout %q", code, out)
	}
}

func TestFlagsMayFollowTheTarget(t *testing.T) {
	d := corpus(t)
	list := filepath.Join(t.TempDir(), "list")
	if err := os.WriteFile(list, []byte(d+"/a.md\x00"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out, _ := run(t, d, d, "--files-from", list)
	if code != 0 || !strings.Contains(out, "-- file set: 1 listed · 1 in scope") {
		t.Errorf("exit %d stdout %q", code, out)
	}
}

func TestRelativeTargetResolvesAgainstTheWorkingDirectory(t *testing.T) {
	d := corpus(t)
	code, out, _ := run(t, filepath.Dir(d), filepath.Base(d))
	if code != 0 || !strings.Contains(out, "== scan-secrets: "+filepath.Base(d)+" ==") {
		t.Errorf("exit %d stdout %q", code, out)
	}
}

func TestFilesFromStdin(t *testing.T) {
	d := corpus(t)
	s, out, _ := stdio(d, d+"/a.md\x00")
	code := cli.Run(Commands, []string{"secrets", "scan", "--files-from", "-", d}, s)
	if code != 0 || !strings.Contains(out.String(), "1 listed · 1 in scope") {
		t.Errorf("exit %d stdout %q", code, out.String())
	}
}

// --toolbelt names the shim's directory: its parent holds TARGETS.md, whose live-install rows add a reminder.
func TestToolbeltFindsTargetsMd(t *testing.T) {
	kit := t.TempDir()
	tb := filepath.Join(kit, "toolbelt")
	target := filepath.Join(kit, "livecorp")
	for _, d := range []string{tb, target} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(kit, "TARGETS.md"), []byte("| livecorp | live-install |\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out, _ := run(t, kit, "--toolbelt", tb, target)
	if code != 0 || !strings.Contains(out, "-- target registered LIVE-INSTALL: SECRETS DISCIPLINE is a hard invariant here") {
		t.Errorf("exit %d stdout %q", code, out)
	}
	if _, out, _ := run(t, kit, "--toolbelt", filepath.Join(kit, "absent"), target); strings.Contains(out, "LIVE-INSTALL") {
		t.Errorf("an unresolvable toolbelt must not invent a banner: %q", out)
	}
}

func TestCommandIsRegisteredUnderSecretsScan(t *testing.T) {
	if len(Commands) != 1 || Commands[0].Group != "secrets" || Commands[0].Name != "scan" {
		t.Fatalf("Commands = %+v", Commands)
	}
	if err := cli.Validate(Commands); err != nil {
		t.Fatal(err)
	}
}
