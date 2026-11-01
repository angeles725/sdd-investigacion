package hook

import (
	"path/filepath"
	"testing"
)

func TestAbsPath(t *testing.T) {
	tests := []struct {
		name, cwd, in, want string
	}{
		{"absolute stays", "/w", "/a/b", "/a/b"},
		{"relative joins cwd", "/w", "foo", "/w/foo"},
		{"dot is cwd", "/w", ".", "/w"},
		{"dotdot climbs", "/w/x", "..", "/w"},
		{"dotdot at root stays at root", "/", "..", "/"},
		{"dotdot above root stays at root", "/w", "../../x", "/x"},
		{"dotdot collapsed textually", "/w", "/a/b/../c", "/a/c"},
		{"trailing dotdot collapses", "/w", "/a/b/..", "/a"},
		{"dot components dropped", "/w", "/a/./b/.", "/a/b"},
		{"repeated and trailing slashes dropped", "/w", "//a///b/", "/a/b"},
		{"root", "/w", "/", "/"},
		{"only dotdots to root", "/w", "/..", "/"},
		{"empty target is cwd", "/w", "", "/w"},
		{"embedded newline kept", "/w", "/a/b\nc", "/a/b\nc"},
		{"cwd root joins without doubling", "/", "x", "/x"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := within(t, func() string { return AbsPath(tt.cwd, tt.in) }); got != tt.want {
				t.Errorf("AbsPath(%q, %q) = %q, want %q", tt.cwd, tt.in, got, tt.want)
			}
		})
	}
}

func TestFindGitRoot(t *testing.T) {
	type want struct {
		root   func(r string) string
		isRoot bool
	}
	at := func(rel string) func(string) string {
		return func(r string) string {
			if rel == "" {
				return ""
			}
			return filepath.Join(r, rel)
		}
	}
	tests := []struct {
		name   string
		setup  func(t *testing.T, r string)
		cwd    string // relative to the sandbox; "" = the sandbox itself
		target string // relative targets are resolved against cwd; "ROOT/..." is made absolute
		env    map[string]string
		noCeil bool
		want   want
	}{
		{
			name:   "target owning a .git is its own root (raw check)",
			setup:  func(t *testing.T, r string) { gitInit(t, filepath.Join(r, "a")) },
			target: "ROOT/a",
			want:   want{root: func(r string) string { return r + "/a" }, isRoot: true},
		},
		{
			name: "nested target finds the enclosing repo",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "p"))
				mkdirs(t, filepath.Join(r, "p", "n"))
			},
			target: "ROOT/p/n",
			want:   want{root: at("p")},
		},
		{
			name:   "no repository anywhere below the ceiling gives no root",
			setup:  func(t *testing.T, r string) { mkdirs(t, filepath.Join(r, "x")) },
			target: "ROOT/x",
			want:   want{root: at("")},
		},
		{
			name: "a .git FILE (linked worktree) counts as a root",
			setup: func(t *testing.T, r string) {
				writeFile(t, filepath.Join(r, "w", ".git"), "gitdir: /elsewhere\n")
				mkdirs(t, filepath.Join(r, "w", "n"))
			},
			target: "ROOT/w/n",
			want:   want{root: at("w")},
		},
		{
			name: "13a: without a ceiling an enclosing repo bleeds in",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "encl"))
				mkdirs(t, filepath.Join(r, "encl", "sub", "t"))
			},
			target: "ROOT/encl/sub/t",
			noCeil: true,
			want:   want{root: at("encl")},
		},
		{
			name: "13b: a ceiling stops the walk before the enclosing repo",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "encl"))
				mkdirs(t, filepath.Join(r, "encl", "sub", "t"))
			},
			target: "ROOT/encl/sub/t",
			env:    map[string]string{envCeiling: "ROOT/encl/sub"},
			want:   want{root: at("")},
		},
		{
			name: "17: a ceiling with a trailing slash is normalised",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "encl"))
				mkdirs(t, filepath.Join(r, "encl", "sub", "t"))
			},
			target: "ROOT/encl/sub/t",
			env:    map[string]string{envCeiling: "ROOT/encl/sub/"},
			want:   want{root: at("")},
		},
		{
			name:   "15a: relative dot at its own root",
			setup:  func(t *testing.T, r string) { gitInit(t, filepath.Join(r, "a")) },
			cwd:    "a",
			target: ".",
			want:   want{root: func(r string) string { return r + "/a/." }, isRoot: true},
		},
		{
			name: "15c: relative nested target inside a repo",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "p"))
				mkdirs(t, filepath.Join(r, "p", "nested"))
			},
			cwd:    "p",
			target: "nested",
			want:   want{root: at("p")},
		},
		{
			name:   "no repository above a target directly under the filesystem root terminates",
			setup:  func(t *testing.T, r string) {},
			target: "/rsdd-hook-teeth-no-such-dir",
			noCeil: true,
			want:   want{root: at("")},
		},
		{
			name:   "15b: relative target, no repo, terminates",
			setup:  func(t *testing.T, r string) { mkdirs(t, filepath.Join(r, "bare")) },
			target: "bare",
			want:   want{root: at("")},
		},
		{
			name: "16: dotdot is collapsed before the walk (distractor repo B is not found)",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "A", "B"))
			},
			target: "ROOT/A/B/..",
			want:   want{root: at("")},
		},
		{
			name: "18/22a: symlink followed by dotdot lands on a real root (raw check)",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "P"))
				gitInit(t, filepath.Join(r, "Q", "y"))
				mkdirs(t, filepath.Join(r, "Q", "y", "z"), filepath.Join(r, "P", "sub"))
				symlink(t, filepath.Join(r, "Q", "y", "z"), filepath.Join(r, "P", "sub", "link"))
			},
			target: "ROOT/P/sub/link/..",
			want:   want{root: func(r string) string { return r + "/P/sub/link/.." }, isRoot: true},
		},
		{
			name: "21/22c: the ceiling wins over the raw check when the collapsed path is the ceiling",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "Q", "y"))
				mkdirs(t, filepath.Join(r, "Q", "y", "z"), filepath.Join(r, "P", "sub"))
				symlink(t, filepath.Join(r, "Q", "y", "z"), filepath.Join(r, "P", "sub", "link"))
			},
			target: "ROOT/P/sub/link/..",
			env:    map[string]string{envCeiling: "ROOT/P/sub"},
			want:   want{root: at("")},
		},
		{
			name: "22b/23: ordinary walk keeps the flag clear and returns the collapsed root",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "P"))
				mkdirs(t, filepath.Join(r, "Q", "y", "z"))
				symlink(t, filepath.Join(r, "Q", "y", "z"), filepath.Join(r, "P", "link"))
			},
			target: "ROOT/P/link/..",
			want:   want{root: at("P")},
		},
		{
			name: "19: an embedded newline in the target is not truncated",
			setup: func(t *testing.T, r string) {
				gitInit(t, filepath.Join(r, "t19"))
				gitInit(t, filepath.Join(r, "t19", "a"))
				mkdirs(t, filepath.Join(r, "t19", "a\nb"))
			},
			target: "ROOT/t19/a\nb",
			want:   want{root: at("t19")},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, e := sandbox(t)
			tt.setup(t, r)
			sub := func(s string) string {
				if len(s) >= 4 && s[:4] == "ROOT" {
					return r + s[4:]
				}
				return s
			}
			cwd := r
			if tt.cwd != "" {
				cwd = filepath.Join(r, tt.cwd)
			}
			kv := map[string]string{}
			if !tt.noCeil {
				kv[envCeiling] = filepath.Dir(r)
			}
			for k, v := range tt.env {
				kv[k] = sub(v)
			}
			e = envOf(cwd, kv)
			type rootIs struct {
				root string
				is   bool
			}
			got := within(t, func() rootIs { r, is := FindGitRoot(e, sub(tt.target)); return rootIs{r, is} })
			gotRoot, gotIs := got.root, got.is
			if wr := tt.want.root(r); gotRoot != wr || gotIs != tt.want.isRoot {
				t.Errorf("FindGitRoot(%q) = (%q, %v), want (%q, %v)", tt.target, gotRoot, gotIs, wr, tt.want.isRoot)
			}
		})
	}
}
