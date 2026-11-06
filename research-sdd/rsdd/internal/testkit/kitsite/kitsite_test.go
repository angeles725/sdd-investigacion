package kitsite

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func TestCompare(t *testing.T) {
	tests := []struct {
		name             string
		gotOut, gotErr   string
		gotRC            int
		wantOut, wantErr string
		wantRC           int
		wantInReport     []string
	}{
		{name: "all three match", gotOut: "o", gotErr: "e", gotRC: 2, wantOut: "o", wantErr: "e", wantRC: 2},
		{name: "wrong stdout", gotOut: "x", gotErr: "e", gotRC: 2, wantOut: "o", wantErr: "e", wantRC: 2, wantInReport: []string{`stdout "x"`, `stdout "o"`}},
		{name: "wrong stderr", gotOut: "o", gotErr: "x", gotRC: 2, wantOut: "o", wantErr: "e", wantRC: 2, wantInReport: []string{`stderr "x"`, `stderr "e"`}},
		{name: "wrong exit code", gotOut: "o", gotErr: "e", gotRC: 1, wantOut: "o", wantErr: "e", wantRC: 2, wantInReport: []string{"got rc=1", "want rc=2"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			msg := Compare(tc.gotOut, tc.gotErr, tc.gotRC, tc.wantOut, tc.wantErr, tc.wantRC)
			if len(tc.wantInReport) == 0 {
				if msg != "" {
					t.Fatalf("a match reported %q", msg)
				}
				return
			}
			if msg == "" {
				t.Fatal("a mismatch reported nothing")
			}
			for _, part := range tc.wantInReport {
				if !strings.Contains(msg, part) {
					t.Errorf("message %q lacks %q", msg, part)
				}
			}
		})
	}
}

func TestExpand(t *testing.T) {
	for placeholder, want := range map[string]string{
		"@K@": "/h/investigacion/sdd-investigacion/research-sdd",
		"@T@": "/h/investigacion/sdd-investigacion/research-sdd/toolbelt",
		"@P@": "/h/investigacion/sdd-investigacion",
		"@H@": "/h",
	} {
		if got := Expand("<"+placeholder+">", "/h/investigacion/sdd-investigacion/research-sdd", "/h"); got != "<"+want+">" {
			t.Errorf("%s expanded to %q, want %q", placeholder, got, want)
		}
	}
}

func TestInvalidKitWarning(t *testing.T) {
	want := "kit-run: DEGRADED: RESEARCH_SDD_KIT=/b invalid (no toolbelt/ directory); trying the launcher files and the default checkout\n"
	if got := InvalidKitWarning("/b"); got != want {
		t.Fatalf("got %q", got)
	}
}

func TestNewBuildsTheKit(t *testing.T) {
	k := New(t, SystemPath, map[string]string{"TARGETS.md": "# targets\n"}, "TARGETS.md", "toolbelt/x.sh", "install/keep")
	if k.Root != filepath.Join(k.Home, "investigacion", "sdd-investigacion", "research-sdd") {
		t.Fatalf("root %q", k.Root)
	}
	if fi, err := os.Stat(filepath.Join(k.Root, "toolbelt")); err != nil || !fi.IsDir() {
		t.Fatalf("no toolbelt/ directory: %v", err)
	}
	for file, body := range map[string]string{"TARGETS.md": "# targets\n", "toolbelt/x.sh": "", "install/keep": ""} {
		b, err := os.ReadFile(filepath.Join(k.Root, file))
		if err != nil || string(b) != body {
			t.Errorf("%s: %q, %v; want %q", file, b, err, body)
		}
	}
	bare := k.Bare(t)
	if _, err := os.Stat(bare + "/toolbelt"); err == nil {
		t.Fatal("the bare directory holds toolbelt/")
	}
	if fi, err := os.Stat(bare); err != nil || !fi.IsDir() {
		t.Fatalf("no bare directory: %v", err)
	}
}

func TestRunProfiles(t *testing.T) {
	echo := func(args []string, s cli.Stdio) int {
		_, _ = s.Out.Write([]byte(s.Env("PATH") + "|" + s.Env("RESEARCH_SDD_KIT") + "|" + s.Env("TMPDIR") + "|" + s.Cwd))
		return 3
	}
	sys := New(t, SystemPath, nil)
	if out, errOut, rc := sys.Run(echo, nil, "k", "/c"); out != "/usr/bin:/bin|k||/c" || errOut != "" || rc != 3 {
		t.Fatalf("SystemPath: %q %q %d", out, errOut, rc)
	}
	np := New(t, NoPath, nil)
	if out, _, _ := np.Run(echo, nil, "k", "/c"); out != np.Home+"/nobin|k|"+np.Home+"|/c" {
		t.Fatalf("NoPath: %q", out)
	}
}
