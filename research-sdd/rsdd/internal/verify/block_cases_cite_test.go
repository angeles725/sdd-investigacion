//go:build unix

package verify

import (
	"os"
	"path/filepath"
	"testing"
)

// Citation cases: Type grammar, file:line forms, ranges, nonpath tokens, roots, artifacts, short forms, probe,
// jar and synth references, --extern-check.

func citeCases() []blockCase {
	var cs []blockCase
	add := func(c ...blockCase) { cs = append(cs, c...) }
	src := map[string]string{"b/src/Foo.java": nLines(20), "b/src/short.txt": nLines(2), "b/src/Bar.py": nLines(5)}
	cite := func(name, body string, args ...string) blockCase {
		return withFiles(one(name, body, args...), src)
	}

	// ---- plain file:line, ranges, edges ----
	add(
		cite("cite-ok-single", "[CERT] x ~src/Foo.java:10~"),
		cite("cite-ok-last-line", "[CERT] x ~src/Foo.java:20~"),
		cite("cite-past-eof", "[CERT] x ~src/Foo.java:21~"),
		cite("cite-range-ok", "[CERT] x ~src/Foo.java:10-15~"),
		cite("cite-range-end-eof", "[CERT] x ~src/Foo.java:10-20~"),
		cite("cite-range-past-eof", "[CERT] x ~src/Foo.java:10-21~"),
		cite("cite-range-zero-start", "[CERT] x ~src/Foo.java:0-5~"),
		cite("cite-single-zero", "[CERT] x ~src/Foo.java:0~"),
		cite("cite-range-reversed", "[CERT] x ~src/Foo.java:15-10~"),
		cite("cite-range-equal", "[CERT] x ~src/Foo.java:7-7~"),
		cite("cite-leading-zeros", "[CERT] x ~src/Foo.java:007~ ~src/Foo.java:007-009~"),
		cite("cite-zero-padded-zero", "[CERT] x ~src/Foo.java:00~"),
		cite("cite-missing-file", "[CERT] x ~src/Nope.java:3~"),
		cite("cite-mixed", "[CERT] a ~src/Foo.java:3~ b ~src/Foo.java:99~ c ~src/Nope.java:1~ d ~src/short.txt:2~"),
		cite("cite-dup-and-order", "[CERT] ~src/short.txt:2~ ~src/Foo.java:3~ ~src/Foo.java:3~ ~src/Bar.py:1-2~ ~a.b:1~"),
		cite("cite-not-backticked", "[CERT] x src/Foo.java:10 and (src/Foo.java:10)"),
		cite("cite-two-on-line", "[CERT] ~src/Foo.java:1~~src/Foo.java:2~ ~src/Foo.java:3~"),
		cite("cite-dir-target", "[CERT] ~src/Foo.java:1~", "b/src"),
		cite("cite-explicit-target", "[CERT] ~src/Foo.java:1~", "b"),
		cite("cite-target-missing-dir", "[CERT] ~src/Foo.java:1~", "nodir"),
		cite("cite-target-dotslash", "[CERT] ~src/Foo.java:1~", "./b/"),
		cite("cite-target-trailing-slashes", "[CERT] ~src/Foo.java:1~", "b//"),
		withFiles(cite("cite-unterminated-last-line", "[CERT] x ~u.txt:3~ ~u.txt:4~"), map[string]string{"b/u.txt": "a\nb\nc"}),
		withFiles(cite("cite-crlf-file", "[CERT] x ~c.txt:3~ ~c.txt:4~"), map[string]string{"b/c.txt": "a\r\nb\r\nc\r\n"}),
		withFiles(cite("cite-empty-file", "[CERT] x ~e.txt:1~"), map[string]string{"b/e.txt": ""}),
		cite("cite-subdir-slash-name", "[CERT] x ~src/../src/Foo.java:3~ ~./src/Foo.java:3~ ~/etc/passwd:1~"),
		cite("cite-huge-line-no", "[CERT] x ~src/Foo.java:123456789012~"),
		cite("cite-name-chars", "[CERT] x ~a_b-c.d.e:1~ ~A.B:1~ ~x.y.z.w:4~"),
		cite("cite-ext-digits", "[CERT] ~lib.so1:2~ ~f.c99:1~ ~g.123:4~"),
	)

	// ---- Type grammar over the P6 and P9 warnings ----
	for i, t := range []string{
		"> Type: synthesis", "> Type: evidence", "> Type: standard", "> **Type: mixed**", "> **Type:** `collaborative`", "> Type: audit",
		"> Type: capture", "> Type: document", "> Type: absence-centred", "> Type: decision", "> Type: design-applied",
		"> Type: foo", "> Type: Synthesis", "> **TYPE: EVIDENCE**", "> Type:", "> Type:  ", "> **Type:**", "> type: evidence", "> TYPE: STANDARD.",
		"> Type: evidence-ish", "> Type: 123", "> **Type: foo bar**. extra", "> Type: ` evidence `", "  >   **  Type: mixed", "> note type: evidence",
		"> Type: audit; Type: synthesis", "> **Type: Mixed**", "> Type: -x", ">Type:synthesis",
	} {
		add(
			one("type-nocite-"+itoa(i), lines(t, "---", "[CERT] a [CERT] b")),
			one("type-resolved0-"+itoa(i), lines(t, "---", "[CERT] a ~nope.java:3~")),
		)
	}
	add(
		one("type-two-lines", lines("> Type: foo", "> Type: evidence", "[CERT] a")),
		one("type-after-body", lines("[CERT] a", "> Type: evidence")),
		one("type-doc-grade-only", lines("> Type: standard", "---", "[CERT-doc] a [CERT-web] b [CERT-a] c")),
		one("type-doc-grade-resolved0", lines("> Type: standard", "---", "[CERT-doc] a ~nope.java:3~")),
		one("type-hw-live", lines("> Type: standard", "---", "[CERT-hw] a [CERT-live] b")),
		one("type-no-cert-no-cite", lines("# nothing")),
		one("type-cert-doc-and-code", lines("> Type: evidence", "---", "[CERT] a [CERT-doc] b")),
	)

	// ---- nonpath tokens ----
	nonpath := []string{
		"127.0.0.1:46272", "10.0.0.1:80-90", "api.example.org:443", "api.example.com:443", "svc.example.io:8080", "a.b.net:1", "x.y.dev:2",
		"host.local:22", "javax.baja.Foo:238", "org.foo.Log:5", "x.y.Class:5", "x.y.Bin:5", "a.b.T:5", "notes.v1.org:3", "api.v2.example.org:9",
		"data.clean.R:3", "my_analysis.final.R:4", "com.example.my_app.R:3", "de.example.app.R:3", "uk.co.acme.R:3", "co.report.R:3", "de.v2.report.R:3",
		"analysis.v2.R:3", "Foo.bar:12", "Foo.barBaz:12", "foo.bar:12", "Foo.java:3", "Foo.Bar:3", "Foo.m:3", "Foo.xyzzy:3", "Foo.XYZ:3", "Foo.M:3",
		"x.org:3", "x.md:3", "x.pl:3", "a.b.md:3", "a.v1.md:3", "a.b.sh:3", "a.v1.sh:3", "a.b.cc:3", "a.b.rs:3", "a.b.tf:3", "a.b.ml:3", "a.b.sc:3",
		"a.b.pl:3", "a.v9.pl:3", "r.R:3", "x.y.R:1", "a.b.c.R:3", "ab.c.R:3", "abc.c.R:3", "java.util.R:3", "v1.org:3", "x.v1.y.org:3", "x.v1x.org:3",
		"1.2.3.4:5", "999.1.1.1:5", "1.2.3:4", "a-b.c_d.com:80", "A.B.COM:80", "f.com:1",
	}
	for i, tok := range nonpath {
		add(
			cite("nonpath-"+itoa(i), "[CERT] x ~"+tok+"~"),
			withFiles(cite("nonpath-exists-"+itoa(i), "[CERT] x ~"+tok+"~"), map[string]string{"b/" + tok[:lastColonIdx(tok)]: nLines(5)}),
		)
	}
	add(
		cite("nonpath-only", "[CERT] x ~127.0.0.1:46272~ ~api.example.org:443~"),
		cite("nonpath-and-real", "[CERT] x ~127.0.0.1:46272~ ~src/Foo.java:3~"),
		cite("nonpath-method-and-extern", "[CERT] ~Foo.bar:1~ ~Gone.java:1~ ~Util.helper:7-9~"),
		withFiles(cite("nonpath-sourceroot-exists", "[CERT] ~analysis.v2.R:3~ ~x.app:2~"), map[string]string{"srcs/analysis.v2.R": nLines(9), "srcs/x.app": nLines(1)}),
	)
	cs[len(cs)-1].env = map[string]string{"SOURCE_ROOT": "{ROOT}/srcs"}

	// ---- roots: SOURCE_ROOT, git root, target root ----
	add(
		withEnv(withFiles(cite("root-source", "[CERT] ~lib/A.java:4~ ~lib/A.java:40~ ~lib/B.java:1~"), map[string]string{"srcs/lib/A.java": nLines(10)}), "SOURCE_ROOT", "{ROOT}/srcs"),
		withEnv(cite("root-source-missing", "[CERT] ~lib/A.java:4~"), "SOURCE_ROOT", "{ROOT}/nowhere"),
		withEnv(cite("root-source-empty", "[CERT] ~lib/A.java:4~"), "SOURCE_ROOT", ""),
		withEnv(withFiles(cite("root-first-short-later-fits", "[CERT] ~src/Foo.java:15~"), map[string]string{"srcs/src/Foo.java": nLines(30)}), "SOURCE_ROOT", "{ROOT}/srcs"),
		withEnv(withFiles(cite("root-none-fits-first-reported", "[CERT] ~src/Foo.java:50~"), map[string]string{"srcs/src/Foo.java": nLines(30)}), "SOURCE_ROOT", "{ROOT}/srcs"),
	)
	gitCase := withFiles(argsOnly("root-git", "g/corpus-x/sub/block.md"), map[string]string{"g/corpus-x/sub/block.md": q("[CERT] ~top/A.java:3~ ~top/A.java:30~\n"), "g/top/A.java": nLines(10)})
	gitCase.setup = func(t testing.TB, root string) { gitInit(t, filepath.Join(root, "g")) }
	add(gitCase)
	for _, m := range []string{"Makefile", "package.json", "go.mod", ".git", "pom.xml", "Cargo.toml", "pyproject.toml", "build.gradle", "README"} {
		add(withFiles(one("troot-"+m, "[CERT] ~lib/A.java:3~ ~lib/A.java:30~ ~lib/Z.java:1~", "p/corpus/b/block.md"), map[string]string{
			"p/corpus/b/block.md": q("[CERT] ~lib/A.java:3~ ~lib/A.java:30~ ~lib/Z.java:1~\n"), "p/" + m: "x\n", "p/lib/A.java": nLines(10),
		}))
	}
	add(
		withFiles(argsOnly("troot-nearest-corpus", "p/corpus/q/corpus/b/block.md"), map[string]string{
			"p/corpus/q/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/corpus/q/Makefile": "x\n", "p/lib/A.java": nLines(10),
		}),
		withFiles(argsOnly("troot-inner-no-marker", "p/corpus/q/corpus/b/block.md"), map[string]string{
			"p/corpus/q/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10),
		}),
		withFiles(argsOnly("troot-corpus-in-name-only", "p/mycorpus/b/block.md"), map[string]string{
			"p/mycorpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10),
		}),
		withFiles(argsOnly("troot-target-is-corpus", "p/corpus/block.md"), map[string]string{
			"p/corpus/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10),
		}),
		withFiles(argsOnly("troot-explicit-target", "p/corpus/b/block.md", "p/corpus"), map[string]string{
			"p/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10),
		}),
		// HOME guard: the candidate root is HOME, or an ancestor of HOME
		withEnv(withFiles(argsOnly("troot-home-is-root", "home/corpus/b/block.md"), map[string]string{
			"home/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "home/Makefile": "x\n", "home/lib/A.java": nLines(10),
		}), "HOME", "{ROOT}/home"),
		withEnv(withFiles(argsOnly("troot-home-descendant", "home/p/corpus/b/block.md"), map[string]string{
			"home/p/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "home/p/Makefile": "x\n", "home/p/lib/A.java": nLines(10),
		}), "HOME", "{ROOT}/home"),
		withEnv(withFiles(argsOnly("troot-home-ancestor", "p/corpus/b/block.md"), map[string]string{
			"p/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10), "p/h/x": "1",
		}), "HOME", "{ROOT}/p/h"),
		withEnv(withFiles(argsOnly("troot-home-unset-root", "p/corpus/b/block.md"), map[string]string{
			"p/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10),
		}), "HOME", ""),
		withEnv(withFiles(argsOnly("troot-home-missing", "p/corpus/b/block.md"), map[string]string{
			"p/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10),
		}), "HOME", "{ROOT}/nohome"),
	)
	sym := withFiles(argsOnly("troot-symlinked-target", "link/b/block.md"), map[string]string{
		"p/corpus/b/block.md": q("[CERT] ~lib/A.java:3~\n"), "p/Makefile": "x\n", "p/lib/A.java": nLines(10),
	})
	sym.setup = func(t testing.TB, root string) {
		if err := os.Symlink(filepath.Join(root, "p", "corpus"), filepath.Join(root, "link")); err != nil {
			t.Fatal(err)
		}
	}
	add(sym)

	// ---- artifact cites ----
	art := map[string]string{
		"b/B12-triage.txt": nLines(10), "b/B12-x.txt": nLines(10), "b/bloque7-notes": nLines(4), "b/sources/probes/B10-x.txt": nLines(200),
		"b/Bloque9-Q.txt": nLines(3), "b/b3-a.b-c": nLines(3),
	}
	acase := func(name, body string, args ...string) blockCase { return withFiles(one(name, body, args...), art) }
	add(
		acase("art-paren-ok", "[CERT] x (B12-triage.txt:5)"),
		acase("art-paren-past", "[CERT] x (B12-triage.txt:50)"),
		acase("art-paren-range", "[CERT] x (B12-triage.txt:2-8)"),
		acase("art-paren-range-past", "[CERT] x (B12-triage.txt:2-18)"),
		acase("art-paren-range-reversed", "[CERT] x (B12-triage.txt:8-2)"),
		acase("art-paren-range-zero", "[CERT] x (B12-triage.txt:0-2)"),
		acase("art-nbh-range", "[CERT] x (B12-triage.txt:2‑8)"),
		acase("art-endash-range", "[CERT] x (B12-triage.txt:2–8)"),
		acase("art-nbh-past", "[CERT] x (B12-triage.txt:2‑80)"),
		acase("art-backtick", "[CERT] x ~B12-triage.txt:5~"),
		acase("art-backtick-both-passes", "[CERT] x ~sources/probes/B10-x.txt:146~ ~B12-x.txt:3~"),
		acase("art-extensionless", "[CERT] cited as ~B12-triage:7~ and (bloque7-notes:3)"),
		acase("art-missing", "[CERT] x (B99-gone.txt:5)"),
		acase("art-missing-ext", "[CERT] x ~B99-gone:5~"),
		acase("art-in-text-span", "[CERT] x (cf. the dump; B12-triage.txt:5 shows it)"),
		acase("art-text-before", "[CERT] x (KERNEL32; B12-x.txt:4-6)"),
		acase("art-uppercase", "[CERT] x (BLOQUE7-NOTES:3) (b12-x.txt:3) (Bloque9-Q.txt:2)"),
		acase("art-digit-only-remainder", "[CERT] section (B12-3:44) range (B5-10:20) ~B12-3:44~"),
		acase("art-midword-lookalike", "[CERT] (verbB12-record.txt:44) and verbB12-record.txt:44 and ~verbB12-x.txt:3~"),
		acase("art-midword-unicode", "[CERT] (éB12-x.txt:3) (ÉB12-x.txt:3) (_B12-x.txt:3) (-B12-x.txt:3)"),
		acase("art-outside-span", "[CERT] B12-x.txt:5 bare, no span"),
		acase("art-nested-paren", "[CERT] (outer (inner) B12-x.txt:5) and (a) B12-x.txt:5"),
		acase("art-two-in-span", "[CERT] (B12-x.txt:3 and B12-triage.txt:4 then B12-x.txt:30)"),
		acase("art-path-prefix", "[CERT] ~sources/probes/B10-x.txt:146~"),
		acase("art-path-prefix-past", "[CERT] ~sources/probes/B10-x.txt:246~"),
		acase("art-path-prefix-paren", "[CERT] (see sources/probes/B10-x.txt:146-150)"),
		acase("art-path-prefix-case", "[CERT] (see SOURCES/PROBES/b10-x.txt:146)"),
		acase("art-path-prefix-missing-full", "[CERT] (see nowhere/B10-x.txt:146)"),
		acase("art-dots-name", "[CERT] (b3-a.b-c:2) (b3-a.b-c:20)"),
		acase("art-all-ok-resolved", "[CERT] a (B12-x.txt:1) ~B12-x.txt:2~"),
		acase("art-bt-also-counted", "[CERT] ~B12-x.txt:1~ ~src/Z.java:1~"),
		acase("art-big-numbers", "[CERT] (B12-x.txt:99999999999999999999) (B12-x.txt:1-99999999999999999999)"),
	)

	// ---- short forms, probe files, jar entries, synthesis references ----
	probe := map[string]string{"b/sources/probes/d1/out.txt": "x\n", "b/sources/probes/d1/run.sh": "echo\n"}
	pcase := func(name, body string, args ...string) blockCase { return withFiles(one(name, body, args...), probe) }
	add(
		one("short-table", lines("| a | b |", "|---|---|", "| x | :29 |", "| y | :30 | :31 |", "|:29|", "| z,:40 |")),
		one("short-table-no-pipe-start", lines("a | :29 |", "text :30")),
		one("short-comment", lines("~~~", "// :157", "# :3, :4,:5", "//:9", "//  :10 , :11", "~~~", "x ## :12")),
		one("short-ip-port", lines("[CERT] a at 127.0.0.1:46272 and host:80")),
		one("short-with-cert-warn-suppressed", lines("[CERT] a", "| x | :29 |")),
		one("short-dup-sorted", lines("| :100 | :9 | :29 | :100 |")),
		pcase("probe-present", "[CERT-live] x (~sources/probes/d1/out.txt~)"),
		pcase("probe-missing", "[CERT-live] x (~sources/probes/d1/gone.txt~)"),
		pcase("probe-mixed-coverage", "[CERT-live] a [CERT-hw] b [CERT] c ~sources/probes/d1/out.txt~"),
		pcase("probe-with-bt-cite", "[CERT] a ~sources/probes/d1/out.txt~ ~nope.java:1~"),
		pcase("probe-trailing-punct", "[CERT] a sources/probes/d1/out.txt. and sources/probes/d1/out.txt,"),
		one("jar-only", lines("[CERT] a control-rt.jar!META-INF/module.xml", "b x.jar!a/b.class")),
		one("jar-only-doc", lines("[CERT-doc] a control-rt.jar!META-INF/module.xml")),
		one("synth-only", lines("[CERT] a [B7] and [B12] and [B7]")),
		one("jar-and-synth", lines("[CERT] a [B7] foo.jar!x/y")),
		withFiles(one("jar-with-real-cite", lines("[CERT] a foo.jar!x/y ~src/Foo.java:3~")), map[string]string{"b/src/Foo.java": nLines(5)}),
		one("synth-no-cert", lines("see [B7]")),
		one("synth-brackets-weird", lines("[B7x] [B] [b7] [B7 ] [[B7]]")),
	)

	// ---- --extern-check ----
	ext := map[string]string{"abs/File.py": nLines(30), "abs/dir/Other.java": nLines(3), "abs/empty.txt": ""}
	ecase := func(name, body string, args ...string) blockCase {
		c := withFiles(one(name, body, append([]string{"--extern-check"}, args...)...), ext)
		return c
	}
	ecase2 := func(name, body string, flags ...string) blockCase {
		c := withFiles(one(name, body), ext)
		c.args = append(append([]string{}, flags...), c.args...)
		return c
	}
	add(
		ecase2("extern-ok", "[CERT] x ~{ROOT}/abs/File.py:12-14~ ~{ROOT}/abs/File.py:30~", "--extern-check"),
		ecase2("extern-range-past", "[CERT] x ~{ROOT}/abs/File.py:12-31~ ~{ROOT}/abs/dir/Other.java:4~", "--extern-check"),
		ecase2("extern-missing", "[CERT] x ~{ROOT}/abs/Nope.py:3~", "--extern-check"),
		ecase2("extern-empty", "[CERT] x ~{ROOT}/abs/empty.txt:1~", "--extern-check"),
		ecase2("extern-directory", "[CERT] x ~{ROOT}/abs/dir:3~ ~{ROOT}/abs/dir/x.d:3~", "--extern-check"),
		ecase2("extern-relative-and-abs", "[CERT] x ~lib/Rel.java:3~ ~{ROOT}/abs/File.py:2~ ~Foo.bar:9~", "--extern-check"),
		ecase2("extern-off-same-block", "[CERT] x ~{ROOT}/abs/File.py:12-14~ ~lib/Rel.java:3~"),
		ecase2("extern-none-cited", "[CERT] x ~src/Foo.java:2~", "--extern-check"),
		ecase2("extern-zero-start", "[CERT] x ~{ROOT}/abs/File.py:0-3~ ~{ROOT}/abs/File.py:9-3~", "--extern-check"),
		ecase2("extern-nonpath-guard", "[CERT] x ~/Foo.bar:9~ ~{ROOT}/abs/File.py:3~", "--extern-check"),
		ecase("extern-flag-last", "[CERT] x ~{ROOT}/abs/File.py:3~"),
	)
	cs[len(cs)-1].args = []string{"b/block.md", "--extern-check"}
	unreadable := ecase2("extern-unreadable", "[CERT] x ~{ROOT}/abs/File.py:3~", "--extern-check")
	unreadable.setup = func(t testing.TB, root string) {
		if os.Getuid() == 0 {
			return
		}
		if err := deny(t, filepath.Join(root, "abs", "File.py")); err != nil {
			t.Fatal(err)
		}
	}
	ur2 := withFiles(one("cite-unreadable-target-file", "[CERT] x ~src/Foo.java:3~ ~src/Foo.java:30~"), src)
	ur2.setup = func(t testing.TB, root string) {
		if os.Getuid() == 0 {
			return
		}
		if err := deny(t, filepath.Join(root, "b", "src", "Foo.java")); err != nil {
			t.Fatal(err)
		}
	}
	add(unreadable, ur2)
	return cs
}

func lastColonIdx(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == ':' {
			return i
		}
	}
	return len(s)
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for ; i > 0; i /= 10 {
		b = append([]byte{byte('0' + i%10)}, b...)
	}
	return string(b)
}
