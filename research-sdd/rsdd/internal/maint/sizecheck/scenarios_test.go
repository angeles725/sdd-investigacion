package sizecheck

import "strings"

// The differential test: every scenario builds a repository, runs the frozen legacy kit-size-check.sh
// (testdata/legacy) and run in it, and the two must agree on exit code, stdout and stderr, byte for byte. Declared
// divergences (each pinned by its own Go test): none among these scenarios; awk-less PATH and garbage counts are
// covered in run_test.go.
type scenario struct {
	name  string
	build func(r *repo)
	args  []string
	want  int
}

var tb = "research-sdd/toolbelt/"

func nothing(*repo) {}

func one(path string, n int) func(*repo) {
	return func(r *repo) { r.write(path, gen(n, "q")); r.commit("c") }
}

// excluded builds one authored file and n excluded fixtures; files builds n authored files.
func withExcluded(n int) func(*repo) {
	return func(r *repo) {
		r.write("keep.txt", gen(2, "k"))
		for i := 0; i < n; i++ {
			r.write(tb+"tests/fixtures/ksc/f"+string(rune('a'+i))+".json", gen(i+1, "e"))
		}
		r.commit("c")
	}
}

func withFiles(n int) func(*repo) {
	return func(r *repo) {
		for i := 0; i < n; i++ {
			r.write("src/f"+string(rune('a'+i))+".txt", gen(i+1, "m"))
		}
		r.commit("c")
	}
}

func scenarios() []scenario {
	base := []string{"--base", "base"}
	with := func(extra ...string) []string { return append(append([]string(nil), base...), extra...) }
	fx := tb + "tests/fixtures/ksc/"
	return []scenario{
		{"at-budget", one("src/a.txt", 400), base, 0},
		{"over", one("src/a.txt", 401), base, 0},
		{"over-strict", one("src/a.txt", 401), with("--strict"), 3},
		{"over-strict-json", one("src/a.txt", 401), with("--strict", "--format", "json"), 3},
		{"at-hard", one("src/a.txt", 800), base, 0},
		{"refuse", one("src/a.txt", 801), base, 3},
		{"budget-10", one("src/a.txt", 10), with("--budget", "10"), 0},
		{"budget-10-over", one("src/a.txt", 11), with("--budget", "10", "--hard-limit", "15"), 0},
		{"budget-10-refuse", one("src/a.txt", 16), with("--budget", "10", "--hard-limit", "15"), 3},
		{"hard-eq-budget", one("src/a.txt", 400), with("--budget", "400", "--hard-limit", "400"), 0},
		{"octal-looking", one("src/a.txt", 9), with("--budget", "08"), 0},
		{"head-flag", one("src/a.txt", 3), with("--head", "HEAD"), 0},
		{"fixtures-edges", func(r *repo) {
			r.write("aaa.txt", gen(5, "aa"))
			r.write(fx+"data.json", gen(500, "jj"))
			r.write("zzz.txt", gen(7, "zz"))
			r.commit("c")
		}, base, 0},
		{"fixture-logic", func(r *repo) {
			for _, f := range []string{"shim.sh", "helper.py", "mod.mjs", "sub/deep.sh"} {
				r.write(tb+"tests/fixtures/ksc-logic/"+f, gen(10, "f"))
			}
			r.write(tb+"tests/fixtures/ksc-logic/data.json", gen(100, "d"))
			r.commit("c")
		}, base, 0},
		{"lockfiles", func(r *repo) {
			r.write("src/real.txt", gen(3, "rl"))
			for _, f := range []string{"package-lock.json", "Cargo.lock", "web/pnpm-lock.yaml", "go.sum", "a/b/go.sum", "x.lock"} {
				r.write(f, gen(100, "l"))
			}
			r.commit("c")
		}, base, 0},
		{"all-excluded", func(r *repo) { r.write(fx+"wf.yml", gen(900, "wf")); r.commit("c") }, base, 0},
		{"many-excluded", func(r *repo) {
			r.write("keep.txt", gen(2, "k"))
			for i := 0; i < 13; i++ {
				r.write(fx+string(rune('a'+i))+".json", gen(i+1, "e"))
			}
			r.commit("c")
		}, base, 0},
		{"empty-input", nothing, base, 0},
		{"binary", func(r *repo) {
			r.write("a.bin", "\x00\x01\x02bin\x00")
			r.write("z.txt", gen(3, "z"))
			r.write("zz.bin", "\x00x\x00")
			r.commit("c")
		}, base, 0},
		{"binary-only", func(r *repo) { r.write("a.bin", "\x00\x01\x02bin\x00"); r.commit("c") }, base, 0},
		{"pure-rename", func(r *repo) {
			r.write("old.txt", gen(30, "o"))
			r.commit("add")
			r.git("tag", "mid")
			r.git("mv", "old.txt", "new.txt")
			r.commit("mv")
		}, []string{"--base", "mid"}, 0},
		{"rename-with-edit", func(r *repo) {
			r.write("old.txt", gen(30, "o"))
			r.commit("add")
			r.git("tag", "mid")
			r.git("mv", "old.txt", "new.txt")
			r.write("new.txt", gen(30, "o")+"echo extra\n")
			r.commit("mv")
		}, []string{"--base", "mid"}, 0},
		{"deleted-file", func(r *repo) {
			r.write("gone.txt", gen(30, "g"))
			r.commit("add")
			r.git("tag", "mid")
			r.git("rm", "-q", "gone.txt")
			r.commit("rm")
		}, []string{"--base", "mid"}, 0},
		{"hotspot", func(r *repo) { r.write("m.sh", churn(50)); r.write("o.sh", gen(10, "o")); r.commit("c") }, base, 0},
		{"hotspot-edge-80", func(r *repo) { r.write("m.sh", churn(8)+gen(2, "zz")); r.write("o.sh", gen(5, "o")); r.commit("c") }, base, 0},
		{"hotspot-just-below-80", func(r *repo) { r.write("m.sh", churn(7)+gen(3, "zz")); r.write("o.sh", gen(5, "o")); r.commit("c") }, base, 0},
		{"hotspot-under-10", func(r *repo) { r.write("m.sh", churn(9)); r.write("o.sh", gen(5, "o")); r.commit("c") }, base, 0},
		{"hotspot-40pct-edge", func(r *repo) { r.write("m.sh", churn(40)); r.write("o.sh", gen(60, "o")); r.commit("c") }, base, 0},
		{"hotspot-crlf", func(r *repo) {
			r.write("m.sh", strings.ReplaceAll(churn(20), "\n", "\r\n"))
			r.write("o.sh", gen(5, "o"))
			r.commit("c")
		}, base, 0},
		{"hotspot-single-quotes", func(r *repo) {
			r.write("m.sh", strings.ReplaceAll(strings.ReplaceAll(churn(20), `"`, "'"), "RSDD", "ZZ"))
			r.commit("c")
		}, base, 0},
		{"hotspot-json", func(r *repo) { r.write("m.sh", churn(50)); r.commit("c") }, with("--format", "json"), 0},
		{"split-pairs", func(r *repo) {
			r.write(tb+"maint/kit-foo.sh", gen(300, "a"))
			r.write(tb+"tests/kit-foo.test.sh", gen(250, "b"))
			r.write(tb+"lib/other.sh", gen(100, "c"))
			r.write("docs/readme.md", gen(100, "d"))
			r.write("pkg/tests/x.test.sh", gen(50, "e"))
			r.write("pkg/x.go", gen(40, "f"))
			r.commit("c")
		}, base, 3},
		{"split-single-over", func(r *repo) {
			r.write("a/one.txt", gen(500, "a"))
			r.write("b/two.txt", gen(450, "b"))
			r.write("c/tiny.txt", gen(5, "c"))
			r.commit("c")
		}, base, 3},
		{"split-json", func(r *repo) { r.write("a/one.txt", gen(300, "a")); r.write("b/two.txt", gen(300, "b")); r.commit("c") }, with("--format", "json"), 0},
		{"many-files", func(r *repo) {
			for i := 0; i < 30; i++ {
				r.write("src/f"+string(rune('a'+i%26))+string(rune('a'+i/26))+".txt", gen(i+1, "m"))
			}
			r.commit("c")
		}, base, 0},
		{"tie-order", func(r *repo) {
			r.write("b.txt", gen(5, "b"))
			r.write("a.txt", gen(5, "a"))
			r.write("c.txt", gen(5, "c"))
			r.commit("c")
		}, base, 0},
		{"json-ok", one("src/a.txt", 3), with("--format", "json"), 0},
		{"json-escapes", func(r *repo) { r.write(`q"uote\back.txt`, gen(3, "q")); r.commit("c") }, with("--format", "json"), 0},
		{"json-empty", nothing, with("--format", "json"), 0},
		{"unicode-path", func(r *repo) { r.write("é/ü.txt", gen(3, "u")); r.commit("c") }, base, 0},
		{"space-path", func(r *repo) { r.write("a dir/a file.txt", gen(3, "s")); r.commit("c") }, base, 0},
		{"tab-path", func(r *repo) { r.write("a\tb.txt", gen(3, "t")); r.commit("c") }, base, 2},
		{"tab-path-json", func(r *repo) { r.write("a\tb.txt", gen(3, "t")); r.commit("c") }, with("--format", "json"), 2},
		{"bad-base", nothing, []string{"--base", "nope"}, 2},
		{"bad-base-json", nothing, []string{"--base", "nope", "--format", "json"}, 2},
		{"bad-head", nothing, with("--head", "nope"), 2},
		{"no-merge-base", func(r *repo) { r.git("checkout", "-q", "--orphan", "lone"); r.write("x", "x\n"); r.commit("x") }, with("--head", "lone"), 2},
		{"no-args", nothing, nil, 2},
		{"base-missing", nothing, []string{"--budget", "5"}, 2},
		{"empty-base", nothing, []string{"--base", ""}, 2},
		{"base-last", nothing, []string{"--base"}, 2},
		{"head-last", nothing, with("--head"), 2},
		{"budget-last", nothing, with("--budget"), 2},
		{"hard-last", nothing, with("--hard-limit"), 2},
		{"format-last", nothing, with("--format"), 2},
		{"format-json-then-base-last", nothing, []string{"--format", "json", "--base"}, 2},
		{"format-bad", nothing, with("--format", "xml"), 2},
		{"format-bad-then-unknown", nothing, with("--format", "xml", "--bogus"), 2},
		{"unknown", nothing, with("--bogus"), 2},
		{"unknown-json", nothing, []string{"--format", "json", "--bogus"}, 2},
		{"budget-letters", nothing, with("--budget", "x1"), 2},
		{"budget-empty", nothing, with("--budget", ""), 2},
		{"budget-zero", nothing, with("--budget", "000"), 2},
		{"budget-10-digits", nothing, with("--budget", "1234567890"), 2},
		{"budget-9-digits", one("src/a.txt", 2), with("--budget", "999999999"), 0},
		{"hard-letters", nothing, with("--hard-limit", "-5"), 2},
		{"hard-empty", nothing, with("--hard-limit", ""), 2},
		{"hard-zero", nothing, with("--hard-limit", "0"), 2},
		{"hard-below", nothing, with("--budget", "10", "--hard-limit", "9"), 2},
		{"hard-10-digits", nothing, with("--hard-limit", "1234567890"), 2},
		{"help", nothing, []string{"--help"}, 0},
		{"help-short-after-flag", nothing, []string{"--strict", "-h"}, 0},
		{"help-after-bad", nothing, []string{"--bogus", "-h"}, 2},
		{"help-before-bad", nothing, []string{"-h", "--bogus"}, 0},
		{"budget-1", one("src/a.txt", 1), with("--budget", "1"), 0},
		{"hard-9-digits", one("src/a.txt", 2), with("--hard-limit", "999999999"), 0},
		{"excluded-exactly-10", withExcluded(10), base, 0},
		{"excluded-11", withExcluded(11), base, 0},
		{"files-exactly-25", withFiles(25), base, 0},
		{"files-26", withFiles(26), base, 0},
		{"split-exact-fit", func(r *repo) {
			r.write("a/one.txt", gen(200, "a"))
			r.write("b/two.txt", gen(100, "b"))
			r.write("c/three.txt", gen(100, "c"))
			r.write("d/four.txt", gen(1, "d"))
			r.commit("c")
		}, with("--budget", "200"), 3},
		{"split-dotfiles", func(r *repo) {
			r.write(tb+"tests/.hidden", gen(300, "h"))
			r.write(tb+"tests/.other", gen(300, "o"))
			r.write(".cfg", gen(300, "c"))
			r.commit("c")
		}, base, 3},
		{"last-flag-wins", one("src/a.txt", 3), with("--budget", "1", "--budget", "50"), 0},
	}
}
