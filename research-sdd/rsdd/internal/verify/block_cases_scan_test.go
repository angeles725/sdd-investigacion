//go:build unix

package verify

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// Scanner cases: empty-input digests, ephemeral paths, possibility-first, OCR provenance, SCRIPTS-MANIFEST.

const (
	dSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	dSHA1   = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
	dMD5    = "d41d8cd98f00b204e9800998ecf8427e"
)

func sha(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func scanCases() []blockCase {
	var cs []blockCase
	add := func(c ...blockCase) { cs = append(cs, c...) }

	// ---- empty-input digests ----
	for i, l := range []string{
		"sha256 " + dSHA256, "sha1 " + dSHA1, "md5 " + dMD5, "SHA256: " + "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
		"hash " + dSHA256 + "0", dSHA256[:63], "x" + dMD5, "x " + dMD5 + "x", "_" + dMD5, "-" + dMD5, "é" + dMD5, "(" + dMD5 + ")", "~" + dMD5 + "~", "| " + dSHA1 + " |",
		"e3b0c442…", "e3b0c442...", "e3b0c44…", "e3b0c442", "e3b0c44298fc1c14…", "e3b0c44298fc1c149afbf4c8996fb924…", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855…",
		"da39a3ee…", "d41d8cd9...", "d41d8cd98f00b204e9800998ecf8427e…", "d41d8cd9 …", "E3B0C442…",
		dMD5 + " <!-- empty-digest: quoted -->", "e3b0c442… <!-- empty-digest: quoted -->", dSHA1 + " " + dMD5 + " <!-- empty-digest: quoted -->", dSHA1 + " " + dMD5,
		"<!-- empty-digest: quoted --> " + dMD5, "<!--empty-digest: quoted--> " + dMD5, dMD5 + dMD5, dMD5 + " " + dMD5, "a" + dMD5[1:], dMD5[:31] + "g",
		"abcd " + dSHA256[:8] + " …", "0e3b0c442…", "…e3b0c442…", "e3b0c442… e3b0c442...",
	} {
		add(one("digest-"+itoa(i), lines("# t", l, "after")))
	}
	add(
		one("digest-two-lines", lines(dMD5, "ok", dSHA1+" and "+dSHA256)),
		one("digest-in-table", lines("| a | b |", "|---|---|", "| `"+dSHA256+"` | x |")),
		one("digest-in-fence", lines("```", dSHA256, "```")),
		one("digest-clean", lines("sha256 "+sha("x"))),
	)

	// ---- ephemeral paths ----
	for i, l := range []string{
		"see /tmp/x.log", "see /var/tmp/x", "see /private/tmp/x", "see /private/var/tmp/x", "see $TMPDIR/x", "see ${TMPDIR}/x", "see $TMPDIR}/x", "see ${TMPDIR/x",
		"see ~/tmp/x~", "see ~/tmp/x:12~", "see ~/tmp/x:12-14~", "(/tmp/x)", "(/tmp/x.)", "see /tmp/x.", "see /tmp/x, and /tmp/y;", "see /tmp/x: here",
		"see src/tmp/x", "see ./tmp/x", "see a/tmp/x", "see -/tmp/x", "see _/tmp/x", "see ~/tmp/x", "see x~/tmp/x", "see $/tmp/x", "see $$TMPDIR/x", "see a$TMPDIR/x",
		"see /tmp/a$TMPDIR/x", "see /tmp/a/tmp/b", "see /tmp/a /tmp/b", "see /tmp/a;/tmp/b", "see /tmp/", "see /tmp", "see /tmpx/y", "see /tmp//x", "see /tmp/é", "see é/tmp/x",
		"see scratchpad/x", "see .claude/scratchpad/x", "see /home/u/.claude/projects/p/scratchpad/s/x", "see xscratchpad/x", "see a/scratchpad/x", "see a-scratchpad/x",
		"see /tmp/scratchpad/x", "see $TMPDIR/scratchpad/x", "see /var/tmp/a/scratchpad/b", "see scratchpad/", "see scratchpad", "see ${X}scratchpad/x", "see $scratchpad/x",
		"see }scratchpad/x", "see (scratchpad/x)", "see @scratchpad/x", "see =scratchpad/x", "see .scratchpad/x", "see ..scratchpad/x", "see /scratchpad/x", "see ~scratchpad/x",
		"see scratchpad/a/scratchpad/b", "see xscratchpad/a/scratchpad/b", "see /tmp/x and scratchpad/y",
		"sha256 " + dSHA256 + " /tmp/x", "sha256 /tmp/x " + dSHA256[:63], "SHA256 " + sha("q") + " /tmp/x scratchpad/y", "sha256 abc /tmp/x",
		"/tmp/x <!-- ephemeral-ok: scratch only -->", "/tmp/x <!-- ephemeral-ok: -->", "/tmp/x <!-- ephemeral-ok:    -->", "/tmp/x <!-- ephemeral-ok: why", "/tmp/x <!--ephemeral-ok: why-->",
		"/tmp/x <!-- ephemeral-ok: a --> <!-- ephemeral-ok: b -->", "<!-- ephemeral-ok: why --> /tmp/x scratchpad/y", "/tmp/x scratchpad/y <!-- ephemeral-ok: -->",
		"/tmp/x <!-- ephemeral-ok:\twhy\t-->", "/tmp/x <!-- ephemeral-ok: é -->", "/tmp/x <!-- ephemeral-ok: a-->b-->",
		"sha256 " + dSHA256 + " /tmp/x <!-- ephemeral-ok: why -->", "/tmp/x <!-- ephemeral-ok: -->  " + dSHA256,
	} {
		add(
			one("eph-"+itoa(i), lines("# t", l, "tail")),
			one("eph-warn-"+itoa(i), lines("# t", l, "tail"), "--ephemeral=warn"),
		)
	}
	add(
		one("eph-many-lines", lines("/tmp/a", "x", "/tmp/b scratchpad/c", "sha256 "+dSHA256+" /tmp/d", "/tmp/e <!-- ephemeral-ok: r -->", "/tmp/f <!-- ephemeral-ok: -->")),
		one("eph-many-lines-warn", lines("/tmp/a", "x", "/tmp/b scratchpad/c", "sha256 "+dSHA256+" /tmp/d", "/tmp/e <!-- ephemeral-ok: r -->", "/tmp/f <!-- ephemeral-ok: -->"), "--ephemeral=warn"),
		one("eph-only-anchored", lines("sha256 "+dSHA256+" /tmp/d")),
		one("eph-only-ok", lines("/tmp/e <!-- ephemeral-ok: r -->")),
		one("eph-fence", lines("```", "/tmp/in-fence", "```")),
	)

	// ---- possibility-first ----
	for i, l := range []string{
		"This is not possible.", "No es posible hacerlo.", "It is impossible to read.", "Es imposible.", "There is no way to do it.", "It is out of reach.",
		"The value is not determinable.", "No se puede leer.", "It cannot be determined.", "It cannot be extracted.", "It CANNOT BE VERIFIED here", "cannot be seen",
		"a physically impossible value", "an impossible value was read", "impossible readings", "impossible states", "impossible results", "impossible combination",
		"physically impossible and also impossible", "impossible value and impossible", "Not with route A, measured.", "not with the route, measured: impossible", "impossible, not with x measured",
		"- route 1: not possible", "| route | x | impossible |", "  * route one impossible", "1. route: impossible", "1) route impossible", "+ impossible",
		"not possible not possible", "É impossible É", "İMPOSSIBLE", "impossible\twith tab", "\timpossible leading tab", "impossible trailing tab\t", "\t\timpossible\t\t",
	} {
		add(one("pf-"+itoa(i), lines("## s", l, "after")))
	}
	ladder := []string{"## s", "it is impossible to do.", "- route A: x", "- route B: y", "- route C: z", "- cheapest next step: A"}
	add(
		one("pf-ladder-ok", lines(ladder...)),
		one("pf-ladder-two-routes", lines("## s", "impossible", "- route A", "- route B", "- cheapest")),
		one("pf-ladder-no-cheapest", lines("## s", "impossible", "- route A", "- route B", "- route C")),
		one("pf-ladder-table", lines("## s", "impossible", "| route | cost |", "| route 2 | x |", "| route 3 | y |", "cheapest: 2")),
		one("pf-ladder-next-section", lines("## s", "impossible", "## t", "- route A", "- route B", "- route C", "cheapest")),
		one("pf-two-sections", lines("## a", "not possible", "- route 1", "- route 2", "- route 3", "cheapest", "## b", "impossible", "imposible")),
		one("pf-fenced", lines("## a", "```", "impossible", "```", "ok", "```x", "no se puede", "```", "impossible after")),
		one("pf-heading-needs-space", lines("#a", "impossible", "#b impossible", "# c impossible")),
		one("pf-no-heading-at-all", lines("impossible", "not possible")),
		one("pf-fence-unclosed", lines("```", "impossible")),
		one("pf-route-words", lines("## a", "impossible", "- router", "- routes", "1. rerouted", "cheapest")),
	)
	sweepDir := map[string]string{
		"c/a.md": q("## a\nimpossible x\nok\n"), "c/sub/b.md": q("not possible\nno es posible\n"), "c/sub/deep/c.md": q("fine\n"), "c/notes.txt": "impossible\n",
		"c/tabs.md": "\timpossible a\tb\t\n", "c/long.md": "impossible " + string(make([]byte, 0)) + repeat("é", 100) + "\n",
		"c/ladder.md": q("## s\nimpossible\n- route a\n- route b\n- route c\ncheapest\n"), "c/UP.MD": "impossible\n", "c/.hidden.md": "impossible hidden\n",
	}
	sw := blockCase{name: "sweep-corpus", files: sweepDir, args: []string{"--possibility-sweep", "c"}}
	swt := blockCase{name: "sweep-trailing-slash", files: sweepDir, args: []string{"--possibility-sweep", "c/"}}
	swd := blockCase{name: "sweep-double-slash", files: sweepDir, args: []string{"--possibility-sweep", "c//sub"}}
	swc := blockCase{name: "sweep-clean", files: map[string]string{"c/a.md": "fine\n"}, args: []string{"--possibility-sweep", "c"}}
	swe := blockCase{name: "sweep-empty-dir", files: map[string]string{"c/x.txt": "x"}, args: []string{"--possibility-sweep", "c"}}
	swn := blockCase{name: "sweep-no-arg", files: map[string]string{}, args: []string{"--possibility-sweep"}}
	swm := blockCase{name: "sweep-missing", files: map[string]string{}, args: []string{"--possibility-sweep", "nope"}}
	swf := blockCase{name: "sweep-with-flags", files: sweepDir, args: []string{"--extern-check", "--possibility-sweep", "c", "--backptr=off"}}
	swl := blockCase{name: "sweep-symlink-dir", files: sweepDir, args: []string{"--possibility-sweep", "lnk"}}
	swl.setup = func(t testing.TB, root string) {
		if err := os.Symlink(filepath.Join(root, "c"), filepath.Join(root, "lnk")); err != nil {
			t.Fatal(err)
		}
	}
	swl2 := blockCase{name: "sweep-symlink-dir-slash", files: sweepDir, args: []string{"--possibility-sweep", "lnk/"}, setup: swl.setup}
	swl3 := blockCase{name: "sweep-symlink-file", files: map[string]string{"c/real.md": "impossible\n"}, args: []string{"--possibility-sweep", "c"}}
	swl3.setup = func(t testing.TB, root string) {
		if err := os.Symlink(filepath.Join(root, "c", "real.md"), filepath.Join(root, "c", "ln.md")); err != nil {
			t.Fatal(err)
		}
	}
	add(sw, swt, swd, swc, swe, swn, swm, swf, swl, swl2, swl3)

	// ---- OCR provenance ----
	ocrFiles := map[string]string{
		"b/sources/extracted/tufte-vdqi-2001.md": q("---\nreliability: ocr-lossy\nsource_pdf: /x/Tufte Book.pdf\n---\ntext\n"),
		"b/sources/extracted/plain.md":           "reliability: ok\nsource_pdf: /x/plain.pdf\n",
		"b/sources/extracted/hand.md":            "mirror text, extracted via OCR from a scan\n",
		"b/sources/extracted/nosrc-thing-x.md":   "Reliability:   OCR-LOSSY\n",
		"b/sources/extracted/weird.md":           "reliability: ocr-lossy\nsource_pdf:/x/nospace.pdf\nsource_pdf: /x/second.pdf\n",
		"b/sources/extracted/skip.txt":           "reliability: ocr-lossy\n",
	}
	ocr := func(name, body string, args ...string) blockCase {
		return withFiles(one(name, body, args...), ocrFiles)
	}
	add(
		ocr("ocr-cites-pdf", lines("# t", "See the Tufte Book result", "and again Tufte Book", "x")),
		ocr("ocr-cites-stem", lines("# t", "uses tufte-vdqi-2001 here", "tufte-vdqi", "tufte", "tufte-vdqi-2001 tufte-vdqi")),
		ocr("ocr-cites-loose", lines("# t", "tufte-vdqi only", "nosrc-thing", "nosrc-thing-x")),
		ocr("ocr-cites-none", lines("# t", "nothing relevant here")),
		ocr("ocr-cites-all", lines("Tufte Book", "plain", "hand", "nosrc-thing-x", "weird", "second", "nospace")),
		ocr("ocr-dedup-lines", lines("tufte-vdqi-2001 Tufte Book tufte-vdqi", "z")),
		ocr("ocr-line-numbers-sort", lines("a", "b", "c", "d", "e", "f", "g", "h", "i", "tufte-vdqi", "k", "Tufte Book")),
		ocr("ocr-explicit-target", lines("Tufte Book"), "b"),
		ocr("ocr-other-target", lines("Tufte Book"), "elsewhere"),
	)
	ocrSym := ocr("ocr-symlinked-dir", lines("Tufte Book"))
	ocrSym.setup = func(t testing.TB, root string) {
		if err := os.Rename(filepath.Join(root, "b", "sources", "extracted"), filepath.Join(root, "real-extracted")); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(root, "real-extracted"), filepath.Join(root, "b", "sources", "extracted")); err != nil {
			t.Fatal(err)
		}
	}
	add(ocrSym)

	// ---- SCRIPTS-MANIFEST ----
	run := "echo run\n"
	man := func(rows ...string) string {
		s := "| script | sha256 | run/step | block | executed-on | remote-sha256 | role |\n|---|---|---|---|---|---|---|\n"
		for _, r := range rows {
			s += r + "\n"
		}
		return s
	}
	mf := func(files map[string]string) map[string]string {
		base := map[string]string{"b/sources/probes/d1/run.sh": run, "b/sources/probes/d1/other.py": "print(1)\n"}
		for k, v := range files {
			base[k] = v
		}
		return base
	}
	runSha := sha(run)
	mcase := func(name, body string, files map[string]string, args ...string) blockCase {
		return withFiles(blockCase{name: name, files: mf(files), args: append([]string{"b/block.md"}, args...)}, map[string]string{"b/block.md": q(body)})
	}
	cite := "[CERT] ran ~sources/probes/d1/run.sh~"
	add(
		mcase("man-none", cite, nil),
		mcase("man-ok", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s1 | B1 | host | - | EXECUTED |")}),
		mcase("man-ok-dot-slash-backticks", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| `./run.sh` | `" + runSha + "` | s1 | B1 | host | - | EXECUTED |")}),
		mcase("man-ok-sources-cell", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| sources/probes/d1/run.sh | " + runSha + " | s |")}),
		mcase("man-ok-upper-sha", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + upper(runSha) + " | s |")}),
		mcase("man-wrong-sha", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + sha("other") + " | s |")}),
		mcase("man-no-row", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| other.py | " + sha("print(1)\n") + " | s |")}),
		mcase("man-short-sha", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha[:60] + " | s |")}),
		mcase("man-placeholder-sha", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | TODO | s |", "| run.sh | - | s |")}),
		mcase("man-two-rows-one-ok", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | "+sha("old")+" | s |", "| run.sh | "+runSha+" | s |")}),
		mcase("man-other-dir-row", cite, map[string]string{"b/sources/probes/d2/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}),
		mcase("man-two-manifests", cite+" and ~sources/probes/d2/z.sh~", map[string]string{
			"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |"),
			"b/sources/probes/d2/SCRIPTS-MANIFEST.md": man("| z.sh | " + sha("z\n") + " | s |"), "b/sources/probes/d2/z.sh": "z\n",
		}),
		mcase("man-absent-file", "ran sources/probes/d1/gone.sh", map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| gone.sh | " + runSha + " | s |")}),
		mcase("man-no-cites", "nothing cited", map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}),
		mcase("man-cite-forms", "a sources/probes/d1/run.sh. b (sources/probes/d1/run.sh) c sources/probes/d1/run.sh.bak d sources/probes/d1/run.shx e sources/probes/d1/other.py, f sources/probes/d1/run.sh…\nsources/probes/d1/run.sh", map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}),
		mcase("man-cite-exts", "sources/probes/d1/a.ps1 sources/probes/d1/a.java sources/probes/d1/a.js sources/probes/d1/a.rb sources/probes/d1/a.pl sources/probes/d1/a.bat sources/probes/d1/a.cmd sources/probes/d1/a.groovy sources/probes/d1/a.kts sources/probes/d1/a.txt sources/probes/d1/a.SH", map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}),
		mcase("man-pipe-rows", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": "|\n| run.sh\n  | run.sh | " + runSha + "\n" + "|run.sh|" + runSha + "|\n"}),
		mcase("man-explicit-target", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}, "b"),
		mcase("man-target-slash", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}, "b/"),
		mcase("man-target-slashes", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}, "./b//"),
		mcase("man-target-dot", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")}, "b/../b"),
		mcase("man-nested", cite, map[string]string{"b/sources/probes/d1/sub/SCRIPTS-MANIFEST.md": man("| ../run.sh | "+runSha+" | s |", "| run.sh | "+runSha+" | s |")}),
	)
	unr := mcase("man-unreadable-manifest", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")})
	unr.setup = func(t testing.TB, root string) {
		if os.Getuid() == 0 {
			return
		}
		if err := deny(t, filepath.Join(root, "b", "sources", "probes", "d1", "SCRIPTS-MANIFEST.md")); err != nil {
			t.Fatal(err)
		}
	}
	unr2 := mcase("man-unreadable-script", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |")})
	unr2.setup = func(t testing.TB, root string) {
		if os.Getuid() == 0 {
			return
		}
		if err := deny(t, filepath.Join(root, "b", "sources", "probes", "d1", "run.sh")); err != nil {
			t.Fatal(err)
		}
	}
	unr3 := mcase("man-unreadable-dir", cite, map[string]string{"b/sources/probes/d1/SCRIPTS-MANIFEST.md": man("| run.sh | " + runSha + " | s |"), "b/sources/probes/d3/x": "1"})
	unr3.setup = func(t testing.TB, root string) {
		if os.Getuid() == 0 {
			return
		}
		if err := deny(t, filepath.Join(root, "b", "sources", "probes", "d3")); err != nil {
			t.Fatal(err)
		}
	}
	add(unr, unr2, unr3)
	return cs
}

func upper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}

func repeat(s string, n int) string {
	out := ""
	for i := 0; i < n; i++ {
		out += s
	}
	return out
}
