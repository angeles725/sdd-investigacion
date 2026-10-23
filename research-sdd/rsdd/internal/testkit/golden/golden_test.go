package golden

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func echoMain(args []string, s cli.Stdio) int {
	s.Out.Write([]byte(strings.Join(args, " ") + "|" + s.Cwd + "|" + s.Env("K") + "|" + s.Clock().Format("2006-01-02") + "\n"))
	s.Err.Write([]byte("err\n"))
	return 1
}

func writeCase(t *testing.T, root, name string, files map[string]string) string {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for f, c := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func goodFiles() map[string]string {
	return map[string]string{
		"cmd.json":      `{"args":["a","b"],"env":{"K":"v"}}`,
		"stdin":         "",
		"stdout":        "a b|/work|v|2000-01-01\n",
		"stderr":        "err\n",
		"exit":          "1\n",
		"intended.json": `[]`,
	}
}

func TestRunCasePasses(t *testing.T) {
	dir := writeCase(t, t.TempDir(), "c", goodFiles())
	if p := runCase(dir, echoMain, false); len(p) != 0 {
		t.Fatalf("unexpected problems: %v", p)
	}
}

func TestRunCaseDetectsDivergence(t *testing.T) {
	for _, f := range []string{"stdout", "stderr", "exit"} {
		t.Run(f, func(t *testing.T) {
			files := goodFiles()
			files[f] = "WRONG\n"
			if f == "exit" {
				files[f] = "0\n"
			}
			dir := writeCase(t, t.TempDir(), "c", files)
			p := runCase(dir, echoMain, false)
			if len(p) != 1 || !strings.Contains(p[0], f) {
				t.Fatalf("want exactly one %s problem, got %v", f, p)
			}
		})
	}
}

func TestMissingRequiredFileFailsNeverSkips(t *testing.T) {
	for f := range goodFiles() {
		t.Run(f, func(t *testing.T) {
			files := goodFiles()
			delete(files, f)
			dir := writeCase(t, t.TempDir(), "c", files)
			p := runCase(dir, echoMain, false)
			if len(p) == 0 || !strings.Contains(p[0], f) {
				t.Fatalf("missing %s must be reported, got %v", f, p)
			}
		})
	}
}

func TestIntendedSchema(t *testing.T) {
	tests := []struct {
		name, body string
		wantErr    bool
	}{
		{"empty list ok", `[]`, false},
		{"valid entry", `[{"field":"stdout","reason":"legacy printed a trailing space"}]`, false},
		{"empty reason", `[{"field":"stdout","reason":""}]`, true},
		{"blank reason", `[{"field":"stdout","reason":"   "}]`, true},
		{"missing reason", `[{"field":"stdout"}]`, true},
		{"unknown field name", `[{"field":"mtime","reason":"x"}]`, true},
		{"unknown key", `[{"field":"stdout","reason":"x","extra":1}]`, true},
		{"not a list", `{"field":"stdout"}`, true},
		{"malformed", `[`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateIntended([]byte(tt.body))
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestUpdateRewritesExpectations(t *testing.T) {
	files := goodFiles()
	files["stdout"], files["stderr"], files["exit"] = "old", "old", "9\n"
	dir := writeCase(t, t.TempDir(), "c", files)
	if p := runCase(dir, echoMain, true); len(p) != 0 {
		t.Fatalf("update must not report problems: %v", p)
	}
	if p := runCase(dir, echoMain, false); len(p) != 0 {
		t.Fatalf("rerun without update must pass: %v", p)
	}
}

func TestNoCasesIsAnError(t *testing.T) {
	if _, err := listCases(t.TempDir()); err == nil {
		t.Fatal("an empty golden dir must be an error, not a silent pass")
	}
	if _, err := listCases(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Fatal("an absent golden dir must be an error")
	}
}

func TestStrictJSONRejectsTrailingData(t *testing.T) {
	tests := []struct {
		name, body string
		wantErr    bool
	}{
		{"one value", `{"args":["a"]}`, false},
		{"trailing whitespace", "{\"args\":[]}\n\n", false},
		{"two objects", `{"args":["a"]}{"args":["b"]}`, true},
		{"object plus garbage", `{"args":[]} xyz`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var spec cmdSpec
			err := strictJSON([]byte(tt.body), &spec)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
	if err := ValidateIntended([]byte(`[] []`)); err == nil {
		t.Error("intended.json with trailing data must be rejected")
	}
}

func TestListCasesReturnsSortedDirsOnly(t *testing.T) {
	root := t.TempDir()
	writeCase(t, root, "b", goodFiles())
	writeCase(t, root, "a", goodFiles())
	if err := os.WriteFile(filepath.Join(root, "README"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := listCases(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || filepath.Base(got[0]) != "a" || filepath.Base(got[1]) != "b" {
		t.Fatalf("got %v, want [a b] and no files", got)
	}
}
