//go:build unix

package verify

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

// bkAllCases is the captured cases (block-cases.txt) plus the hand-written ones below.
func bkAllCases(t *testing.T) []bkCase { return append(bkParseCases(t), bkHandCases()...) }

const bkLegend = "# Block 1 — t\n\n> Method: [CERT] = x.\n\n---\n\n"

// bkHandCases cover what the recorder cannot capture: environment-variable and argument edge cases and the
// shapes no bash assertion produced. Each one is named for the branch it pins.
func bkHandCases() []bkCase {
	blk := func(name, body string) bkFile { return bkFile{rel: name, data: bkLegend + body} }
	hc := func(name string, args []string, env map[string]string, files ...bkFile) bkCase {
		if env == nil {
			env = map[string]string{}
		}
		return bkCase{name: "hand/" + name, args: args, env: env, files: files}
	}
	sum := func(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
	mf := func(rows ...string) bkFile {
		return bkFile{rel: "sources/probes/b1/SCRIPTS-MANIFEST.md", data: "| script | sha256 | run | block | on | remote | role |\n|---|---|---|---|---|---|---|\n" + strings.Join(rows, "\n") + "\n"}
	}
	script := bkFile{rel: "sources/probes/b1/run.sh", data: "echo hi\n"}
	cite := "`sources/probes/b1/run.sh` and `sources/probes/b1/gone.py`\n"
	manifest := []bkCase{
		hc("manifest-match-and-missing-file", []string{"b.md"}, nil, blk("b.md", cite), script, mf("| run.sh | "+sum(script.data)+" |", "| gone.py | "+sum("x")+" |")),
		hc("manifest-sha-differs", []string{"b.md"}, nil, blk("b.md", cite), script, mf("| `run.sh` | "+sum("other")+" |")),
		hc("manifest-uppercase-sha-and-dot-slash", []string{"b.md"}, nil, blk("b.md", cite), script, mf("| ./run.sh | "+strings.ToUpper(sum(script.data))+" |")),
		hc("manifest-target-relative-cell", []string{"b.md"}, nil, blk("b.md", cite), script, mf("| sources/probes/b1/run.sh | "+sum(script.data)+" |")),
		hc("manifest-placeholder-sha-lists-nothing", []string{"b.md"}, nil, blk("b.md", cite), script, mf("| run.sh | TODO |", "| run.sh | "+sum(script.data)[:63]+" |")),
		hc("manifest-row-in-other-dir", []string{"b.md"}, nil, blk("b.md", cite), script, bkFile{rel: "sources/probes/b2/SCRIPTS-MANIFEST.md", data: "| run.sh | " + sum(script.data) + " |\n"}),
		hc("manifest-none-cited", []string{"b.md"}, nil, blk("b.md", "nothing\n"), script, mf("| run.sh | "+sum(script.data)+" |")),
		hc("manifest-absent-with-cites", []string{"b.md"}, nil, blk("b.md", cite), script),
		hc("manifest-cite-forms", []string{"b.md"}, nil, blk("b.md", "`sources/probes/b1/run.sh.` (sources/probes/b1/run.sh) sources/probes/b1/run.sh.bak sources/probes/b1/x.kts\n"), script, mf("| run.sh | "+sum(script.data)+" |")),
		hc("manifest-no-sha-tool", []string{"b.md"}, map[string]string{"PATH": "@NOSHA@"}, blk("b.md", cite), script, mf("| run.sh | "+sum(script.data)+" |")),
	}
	extern := []bkCase{
		hc("extern-check-abs-ok-range-eof", []string{"--extern-check", "b.md"}, nil, blk("b.md", "`@D@/ext/f.py:2` `@D@/ext/f.py:1-3` `@D@/ext/f.py:9` `@D@/ext/nope.py:1` `rel/x.py:1` `Foo.bar:3` `/nonabs`\n"), bkFile{rel: "ext/f.py", data: "a\nb\nc"}),
		hc("extern-check-abs-dir", []string{"--extern-check", "b.md"}, nil, blk("b.md", "`@D@/ext.py:1`\n"), bkFile{rel: "ext.py/x", data: "a\n"}),
		hc("art-path-prefix-fallback", []string{"b.md"}, nil, blk("b.md", "see sources/probes/B10-x.txt:2 and (B10-x.txt:3)\n"), bkFile{rel: "sources/probes/B10-x.txt", data: "1\n2\n3\n"}),
		hc("art-reversed-and-zero", []string{"b.md"}, nil, blk("b.md", "(B3-dump.txt:3-2) (B3-dump.txt:0) (b3-DUMP.txt:1‑2)\n"), bkFile{rel: "B3-dump.txt", data: "1\n2\n"}),
		hc("bt-target-root-label", []string{"corpus/sub/b.md", "corpus"}, nil, bkFile{rel: "corpus/sub/b.md", data: bkLegend + "`top.go:1` `top.go:1-9`\n"}, bkFile{rel: "go.mod", data: "m\n"}, bkFile{rel: "top.go", data: "x\n"}),
		hc("bt-first-short-later-fits", []string{"b.md"}, map[string]string{"SOURCE_ROOT": "@D@/src"}, blk("b.md", "`Z.java:3`\n"), bkFile{rel: "Z.java", data: "x\n"}, bkFile{rel: "src/Z.java", data: "x\ny\nz\n"}),
	}
	return append(append(manifest, extern...), []bkCase{
		hc("no-args", nil, nil),
		hc("missing-block", []string{"nope.md"}, nil),
		hc("bad-ephemeral-value", []string{"--ephemeral=maybe", "b.md"}, nil, blk("b.md", "x\n")),
		hc("bare-ephemeral-flag", []string{"--ephemeral", "b.md"}, nil, blk("b.md", "x\n")),
		hc("bad-backptr-value", []string{"--backptr=none", "b.md"}, nil, blk("b.md", "x\n")),
		hc("bare-backptr-flag", []string{"--backptr", "b.md"}, nil, blk("b.md", "x\n")),
		hc("env-malformed-strict", []string{"b.md"}, map[string]string{"RSDD_STRICT_EPHEMERAL": "yes"}, blk("b.md", "/tmp/x/y\n")),
		hc("env-empty-strict", []string{"b.md"}, map[string]string{"RSDD_STRICT_EPHEMERAL": ""}, blk("b.md", "/tmp/x/y\n")),
		hc("sweep-missing-dir", []string{"--possibility-sweep", "nodir"}, nil),
		hc("sweep-no-arg", []string{"--possibility-sweep"}, nil),
		hc("sweep-flags-before", []string{"--ephemeral=warn", "--possibility-sweep", "."}, nil, bkFile{rel: "c/x.md", data: "It is not possible to x.\n"}),
		hc("sweep-cut-counts-bytes", []string{"--possibility-sweep", "."}, nil, bkFile{rel: "z.md", data: "impossible  " + strings.Repeat("é", 100) + " end\n"}),
		hc("target-arg-empty-string", []string{"b.md", ""}, nil, blk("b.md", "`A.java:1`\n"), bkFile{rel: "A.java", data: "x\n"}),
		hc("target-with-dotdot", []string{"sub/b.md", "sub/.."}, nil, bkFile{rel: "sub/b.md", data: bkLegend + "`A.java:1`\n"}, bkFile{rel: "A.java", data: "x\n"}),
		hc("target-trailing-slash-manifest", []string{"b.md", "./"}, nil,
			blk("b.md", "`sources/probes/b1/run.sh`\n"), bkFile{rel: "sources/probes/b1/run.sh", data: "x\n"},
			bkFile{rel: "sources/probes/b1/SCRIPTS-MANIFEST.md", data: "| run.sh | " + "0000000000000000000000000000000000000000000000000000000000000000" + " |\n"}),
		hc("number-beyond-int64", []string{"b.md"}, nil, blk("b.md", "`A.java:99999999999999999999` `A.java:2-99999999999999999999`\n"), bkFile{rel: "A.java", data: "x\ny\n"}),
		hc("leading-zeros-and-equal-range", []string{"b.md"}, nil, blk("b.md", "`A.java:01` `A.java:01-1` `A.java:002-002`\n"), bkFile{rel: "A.java", data: "x\ny\n"}),
		hc("crlf-block", []string{"b.md"}, nil, bkFile{rel: "b.md", data: "# Block 1\r\n\r\n> Method: [CERT]\r\n\r\n---\r\n\r\nx [CERT] `A.java:1`\r\nnot possible\r\n"}, bkFile{rel: "A.java", data: "x\r\ny"}),
		hc("empty-block", []string{"b.md"}, nil, bkFile{rel: "b.md", data: ""}),
		hc("no-trailing-newline", []string{"b.md"}, nil, bkFile{rel: "b.md", data: "[CERT] `A.java:1`"}, bkFile{rel: "A.java", data: "x"}),
		hc("source-root", []string{"b.md"}, map[string]string{"SOURCE_ROOT": "@D@/src"}, blk("b.md", "`Z.java:1`\n"), bkFile{rel: "src/Z.java", data: "x\n"}),
		hc("ocr-two-extracts", []string{"b.md"}, nil, blk("b.md", "see alpha-beta-one and gamma-delta-two here\nalpha-beta again\n"),
			bkFile{rel: "sources/extracted/alpha-beta-one.md", data: "reliability: ocr-lossy\nsource_pdf: a/b.pdf\n"},
			bkFile{rel: "sources/extracted/gamma-delta-two.md", data: "extracted via OCR\n"}),
		hc("ocr-leading-dash-stem", []string{"b.md"}, nil, blk("b.md", "x\n"), bkFile{rel: "sources/extracted/-odd-name.md", data: "reliability: ocr-lossy\n"}),
		hc("backptr-r-series", []string{"x-block3.md"}, nil,
			bkFile{rel: "x-block3.md", data: "# Block R3 — t\n\nThis corrects Block R1 and Block 2.\n"},
			bkFile{rel: "x-block1.md", data: "# Block R1\nno pointer\n"}, bkFile{rel: "x-block2.md", data: "# Block 2\nB3 here\n"}),
		hc("backptr-ambiguous-and-all", []string{"--backptr=all", "x-block3.md"}, nil,
			bkFile{rel: "x-block3.md", data: "# Block 3\n\nWe refute Block 1 and elsewhere supersede B2.\n"},
			bkFile{rel: "x-block1.md", data: "# Block 1\n"}, bkFile{rel: "y-block1.md", data: "# Block 1\n"}, bkFile{rel: "x-block2.md", data: "# Block 2\n"}),
		hc("backptr-every-filter", []string{"x-block9.md"}, nil,
			bkFile{rel: "x-block9.md", data: "# Block 9\n\nThis corrects Block 3.\n\nBlock 4 is the one this corrects.\n\nNo correction of Block 5 here.\n\nA corrigendum for Block 6.\n\nBlock 7 was corrected.\n\nA self-correction of Block 8.\n\nFixed in B1, corrected by B2.\n\nWe refute B1 and B2 and B3.\n\nThis refutes " + strings.Repeat("x", 70) + " Block 4.\n\n- Connects [B1] · [B2] corrected.\n\nCorrects nothing in B3. This supersedes Block 12 and Block 2: corrected.\n\n```\nrefutes Block 1\n```\n"},
			bkFile{rel: "x-block1.md", data: "# Block 1\n"}, bkFile{rel: "x-block2.md", data: "# Block 2\nB9\n"}, bkFile{rel: "x-block3.md", data: "# Block 3\n"},
			bkFile{rel: "x-block4.md", data: "# Block 4\nsee Block 09\n"}),
		hc("backptr-other-dir-target", []string{"d/x-block3.md", "e"}, nil,
			bkFile{rel: "d/x-block3.md", data: "# Block 3\n\nThis corrects Block 1.\n"}, bkFile{rel: "e/x-block1.md", data: "# Block 1\nBlock 3 points\n"}),
		hc("corpus-target-root-marker", []string{"corpus/b.md"}, nil,
			bkFile{rel: "corpus/b.md", data: bkLegend + "`top.go:1`\n"}, bkFile{rel: "go.mod", data: "module x\n"}, bkFile{rel: "top.go", data: "x\n"}),
	}...)
}
