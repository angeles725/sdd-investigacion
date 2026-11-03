//go:build unix && !nodiff

package verify

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The bash oracle half of the `rsdd verify block` differential. Everything that needs the frozen legacy script
// lives here, behind !nodiff, so the mutation run (TEETHTAGS=nodiff) does not re-execute bash per mutant; the
// Go-only half is replayed from testdata/block-goldens.json by TestBlockGoldens (blockcases_test.go).

// bkLegacy runs the frozen script in cwd.
func bkLegacy(t *testing.T, cwd string, args, env []string) observed {
	t.Helper()
	cmd := exec.Command("bash", append([]string{filepath.Join(bkLegacyDir(t), "verify-block.sh")}, args...)...)
	cmd.Dir = cwd
	cmd.Env = env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("bash: %v", err)
		}
		rc = ee.ExitCode()
	}
	return bkNormalize(t, observed{out.String(), errb.String(), rc})
}

// bkNormalize applies the intended differences to the legacy observation: bash prints "[: N: integer expression
// expected" for a cited number beyond int64 (the comparison is false in both implementations; the message names
// the script and a line and is not reproduced).
func bkNormalize(t *testing.T, o observed) observed {
	t.Helper()
	var keep []string
	for _, l := range strings.SplitAfter(o.stderr, "\n") {
		if strings.Contains(l, ": line ") && strings.HasSuffix(l, ": integer expression expected\n") {
			continue
		}
		keep = append(keep, l)
	}
	o.stderr = strings.Join(keep, "")
	return o
}

func TestDifferentialBlock(t *testing.T) {
	update := os.Getenv("RSDD_UPDATE_GOLDENS") != ""
	frozen := map[string]bkGolden{}
	if !update {
		frozen = bkLoadGoldens(t)
	}
	goldens := map[string]bkGolden{}
	for _, c := range bkAllCases(t) {
		t.Run(c.name, func(t *testing.T) {
			dir, cwd, args, env := bkMaterialize(t, c)
			want := bkLegacy(t, cwd, args, env)
			got := bkGo(cwd, args, env)
			same(t, c.name+" "+strings.Join(c.args, " "), want, got)
			g := bkScrub(want, dir)
			if update {
				goldens[c.name] = g
			} else if f, ok := frozen[c.name]; !ok || f != g {
				t.Errorf("%s: the oracle outcome differs from %s (regenerate with RSDD_UPDATE_GOLDENS=1):\nfrozen %+v\noracle %+v", c.name, bkGoldenFile, f, g)
			}
		})
	}
	if update {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", " ")
		if err := enc.Encode(goldens); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(bkGoldenFile, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// bkFragments are the building blocks of the generated blocks: every citation form, marker, Type: line, digest,
// ephemeral path, manifest cite, OCR citation and correction sentence the script reads, in the shapes the fleet
// uses and the shapes the bash suites aimed at its edges.
var bkFragments = []string{
	"The class extends BComponent [CERT]. It probably caches [INFER].",
	"Cites `src/A.java:3` and `src/A.java:2-4` [CERT]",
	"Cites `src/A.java:0` and `src/A.java:5-2` and `src/A.java:99` [CERT-hw]",
	"`Foo.java:12` `Foo.Bar:44` `127.0.0.1:8080` `api.example.org:443` `notes.v1.org:7` `analysis.v2.R:3` `com.example.app.R:9`",
	"(B1-dump.txt:2-3) and (cf. B2-missing.txt:4) and `B1-dump.txt:1`",
	"(B1‑dump.txt:1–2) en‑dash range",
	"| a | :29 |\n| b | , :31 |",
	"// :157, :160",
	"probe `sources/probes/b1/run.sh` and sources/probes/b1/out.txt and sources/probes/b9/none.txt",
	"control-rt.jar!META-INF/module.xml and [B7] and [B12]",
	"> Type: evidence",
	"> **Type: synthesis**",
	"> type: `Design-Applied`.",
	"> Type: bogus.",
	"> Type:",
	"sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 here",
	"md5 d41d8cd98f00b204e9800998ecf8427e and da39a3ee5e6b4b0d… elided and e3b0c442...",
	"quoted e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 <!-- empty-digest: quoted -->",
	"see /tmp/x/y.log:12 and ${TMPDIR}/z.txt and /var/tmp/q and $TMPDIR/a",
	"/tmp/keep.txt sha256 " + strings.Repeat("ab", 32),
	"/tmp/waived.txt <!-- ephemeral-ok: inspected live -->",
	"/tmp/bad.txt <!-- ephemeral-ok:  -->",
	"~/.claude/scratchpad/s1/out.txt and src/scratchpad/ok and ./tmp/x",
	"preserved `sources/probes/b1/run.sh` `sources/probes/b1/other.py.` and sources/probes/b1/a.sh.bak",
	"It is not possible to recover the key. No se puede leer.",
	"A physically impossible value (-300 C) was flagged.",
	"## Route ladder\nCannot be determined.\n- Route 1: a\n- Route 2: b\n- Route 3: c\ncheapest: 1",
	"This corrige el Bloque 1 and refutes [Block 2].",
	"B5 corrects [Block 3] · [Block 4] · [Block 2].",
	"Block 1 was corrected by Block 9. Nothing here refutes Block 2.",
	"```\n/tmp/in-fence [CERT] `a.go:1`\n```",
	"## Heading\n---\nbody [CERT]",
	"cited from the pdf tufte-vdqi-doc and doc-source mentioned",
	"\ttab\t:3 § unicode éÉ B1-éx.txt:2 `Äö.go:1`",
}

// TestDifferentialBlockFuzz runs generated blocks through both implementations. The seed is fixed: a failure is
// reproducible, and a case worth keeping goes into block-cases.txt or the hand cases.
func TestDifferentialBlockFuzz(t *testing.T) {
	rng := rand.New(rand.NewSource(20240611))
	n := 250
	if testing.Short() {
		n = 40
	}
	for i := 0; i < n; i++ {
		var body []string
		legend := rng.Intn(3) != 0
		if legend {
			body = append(body, "# Block 7 — t", "", "> Type: evidence. Method: [CERT] = x; [INFER] = y.", "", "---", "")
		}
		for k, m := 0, 1+rng.Intn(7); k < m; k++ {
			body = append(body, bkFragments[rng.Intn(len(bkFragments))])
			if rng.Intn(4) == 0 {
				body = append(body, "")
			}
		}
		name := []string{"b.md", "corpus-block7.md", "x-bloque7-slug.md", "block0.md"}[rng.Intn(4)]
		c := bkCase{name: "fuzz", files: []bkFile{
			{rel: name, data: strings.Join(body, "\n") + "\n"},
			{rel: "src/A.java", data: "a\nb\nc\nd\n"},
			{rel: "B1-dump.txt", data: "1\n2\n3"},
			{rel: "sources/probes/b1/run.sh", data: "echo\n"},
			{rel: "sources/probes/b1/SCRIPTS-MANIFEST.md", data: "| script | sha256 |\n| run.sh | " + strings.Repeat("0", 64) + " |\n"},
			{rel: "sources/extracted/tufte-vdqi-doc.md", data: "source_pdf: x/tufte.pdf\nreliability: ocr-lossy\n"},
			{rel: "corpus-block1.md", data: "# Block 1\nnothing\n"},
			{rel: "corpus-block2.md", data: "# Block 2\nsee B7\n"},
		}}
		args := []string{name}
		if rng.Intn(3) == 0 {
			args = append([]string{[]string{"--ephemeral=warn", "--extern-check", "--backptr=all", "--backptr=off", "--strict-ephemeral"}[rng.Intn(5)]}, args...)
		}
		t.Run("", func(t *testing.T) {
			_, cwd, _, env := bkMaterialize(t, c)
			want := bkLegacy(t, cwd, args, env)
			got := bkGo(cwd, args, env)
			same(t, "fuzz "+strings.Join(body, "|"), want, got)
		})
	}
}
