package grammar

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRecords(t *testing.T) {
	for src, want := range map[string][]string{
		"": nil, "\n": {""}, "a": {"a"}, "a\n": {"a"}, "a\n\nb": {"a", "", "b"}, "a\r\nb\r\n": {"a\r", "b\r"},
	} {
		if got := records(src); !reflect.DeepEqual(got, want) {
			t.Errorf("records(%q) = %q, want %q", src, got, want)
		}
	}
}

func TestDefence(t *testing.T) {
	cases := []struct {
		name string
		src  string
		keep string
		open int
	}{
		{"closed backtick fence dropped", "a\n```\nx\n```\nb\n", "a\nb", 0},
		{"tilde fence, longer closer", "a\n~~~ info\nx\n~~~~~\nb", "a\nb", 0},
		{"closer shorter than opener stays open", "````\nx\n```\ny\n````\nz", "z", 0},
		{"other char does not close", "```\n~~~\n```\nz", "z", 0},
		{"closer with trailing text does not close", "```\n``` x\n```\nz", "z", 0},
		{"closer with CR and blanks closes", "```\nx\n``` \t\r\nz", "z", 0},
		{"three-space indent opens", "   ```\nx\n```\nz", "z", 0},
		{"four-space indent is code, never a fence", "    ```\nx\n```\nz\n```", "    ```\nx", 0},
		{"tab indent is code", "\t```\nx", "\t```\nx", 0},
		{"spaces then tab is code", " \t```\nx", " \t```\nx", 0},
		{"backtick info with backtick is inline code", "```a`b\nx\n```\ny\n```", "```a`b\nx", 0},
		{"tilde info may hold a backtick", "~~~a`b\nx\n~~~\ny", "y", 0},
		{"two backticks are no fence", "``\nx", "``\nx", 0},
		{"indented closer does not close", "```\n    ```\n```\nz", "z", 0},
		{"unclosed fence keeps its lines", "a\n```\nx\n", "a\n```\nx", 2},
		{"last unclosed opener is reported", "```\n```\nq\n~~~\nr", "q\n~~~\nr", 4},
		{"empty source", "", "", 0},
	}
	for _, c := range cases {
		d := Parse("f.md", c.src)
		if got := strings.Join(d.Lines, "\n"); got != c.keep || d.UnclosedFence != c.open {
			t.Errorf("%s: lines %q open %d, want %q open %d", c.name, got, d.UnclosedFence, c.keep, c.open)
		}
	}
}

func TestFenceWarning(t *testing.T) {
	if w := Parse("x/r.md", "```\n").FenceWarning(); w != "WARN: unclosed code fence opened at line 1 in x/r.md — treated as text\n" {
		t.Errorf("warning %q", w)
	}
	if w := Parse("x/r.md", "```\n```\n").FenceWarning(); w != "" {
		t.Errorf("closed fence warned %q", w)
	}
}

func TestReadTypedStates(t *testing.T) {
	dir := t.TempDir()
	for _, p := range []string{"", filepath.Join(dir, "missing.md"), dir} {
		if _, err := Read(p); !errors.Is(err, ErrAbsentInput) {
			t.Errorf("Read(%q) = %v, want ErrAbsentInput", p, err)
		}
	}
	empty := filepath.Join(dir, "empty.md")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if d, err := Read(empty); err != nil || len(d.Raw) != 0 || d.Path != empty {
		t.Errorf("empty file: %+v %v", d, err)
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, the unreadable premise is unavailable (NOT a pass)")
	}
	locked := filepath.Join(dir, "locked.md")
	if err := os.WriteFile(locked, []byte("x\n"), 0); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(locked); !errors.Is(err, ErrUnreadable) {
		t.Errorf("Read(locked) = %v, want ErrUnreadable", err)
	}
}
