//go:build unix

package verify

import (
	"fmt"
	"math/rand"
	"strings"
)

// Generated cases: blocks assembled from a pool of line shapes the script reacts to, plus random character edits
// (insert, delete, swap), under a fixed seed so the record is stable. Each block lives in the back-pointer corpus
// c/ (kit-block9.md among kit-block1..11) next to a source tree and a probe directory, and runs with the default
// arguments and with a flag mix.

var genPool = []string{
	"# Block 9 — generated", "# Block R9", "## 9.1 claim [CERT]", "### sub", "", "", "", "---", "---   ", "```", "~~~", "> Type: evidence", "> **Type: synthesis**",
	"> Type: standard. Method: [CERT] = x; [INFER] = y.", "> Method: [CERT] = def; [CERT-a] = sub-agent; [INFER] = deduction.", "> legend [CERT-doc]",
	"The class extends BComponent [CERT]. It caches [INFER].", "A claim [CERT-hw] and a live read [CERT-live] and a doc [CERT-doc] and web [CERT-web] and [CERT-a].",
	"See ~src/Foo.java:3~ and ~src/Foo.java:12-15~ and ~src/Foo.java:99~ [CERT]", "Also ~src/Gone.java:4~ ~src/Foo.java:0-3~ ~src/Foo.java:9-2~ ~Foo.bar:12~",
	"Net ~127.0.0.1:8080~ ~api.example.org:443~ ~javax.baja.Foo:238~ ~data.clean.R:3~ ~notes.v1.org:3~",
	"Artifacts (B12-triage.txt:5) (B12-x.txt:2–8) ~bloque7-notes:3~ (B99-gone.txt:5) (verbB12-record.txt:44) (B12-3:44)",
	"| col | :29 |", "| a | b |", "|---|---|", "// :157", "# :3, :4", "text :30",
	"Probe (~sources/probes/d1/out.txt~) and ~sources/probes/d1/run.sh~ and sources/probes/d1/gone.sh.", "control-rt.jar!META-INF/module.xml", "back-ref [B7] [B12]",
	"It is not possible to recover the key.", "No es posible leerlo.", "There is no way to do it, it is impossible.", "a physically impossible value", "Not with route A, measured.",
	"- route A: cheap", "- route B: medium", "- route C: dear", "- cheapest next step: A", "1. route one", "| route | cost |",
	"sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "md5 d41d8cd98f00b204e9800998ecf8427e", "e3b0c442…", "da39a3ee... <!-- empty-digest: quoted -->",
	"sha256 " + strings.Repeat("ab", 32) + " /tmp/x.log", "see /tmp/x.log and /var/tmp/y", "see $TMPDIR/x ${TMPDIR}/y scratchpad/z", "/tmp/e <!-- ephemeral-ok: why -->", "/tmp/f <!-- ephemeral-ok: -->",
	"This block corrects Block 1.", "Corrige el Bloque 3 y refuta B4.", "supersedes [Block 2] entirely.", "Block 5 was corrected by Block 3.", "Nothing here refutes Block 1.",
	"Corrects Block 1 and Block 2 and Block 3.", "It corrects the claim in B6 somewhat.", "corrected by B3", "self-correction of B1", "A corrigendum corrects Block 1.", "Corrects R5 and Block R6.",
	"Reliability of the Tufte Book result.", "tufte-vdqi-2001 again", "ran sources/probes/d1/run.sh.", "sources/probes/d1/other.py, here",
	"é ü ñ — · … ‑ – ’ “ ”", "tab\there", "trailing spaces   ", "\ttab lead", "[CERT][CERT][INFER]", "`[CERT]` and `[INFER]`", "(see (nested) B12-x.txt:5)", "`a.b:1` `a_b-c.d.e:1`",
	"https://example.org/x:80", "C:\\path\\x.txt:3", "id: 123", "## 2 corrects Block 1", "- item corrects B3", "1. numbered corrects Block 4",
}

var genEdit = []string{".", ",", ";", "`", "(", ")", "[", "]", ":", "-", "‑", "–", " ", "/", "#", ">", "|", "*", "é", "!", "?", "·", "…", "\t"}

func genBlock(r *rand.Rand) string {
	n := 3 + r.Intn(22)
	var ls []string
	for i := 0; i < n; i++ {
		l := genPool[r.Intn(len(genPool))]
		if r.Intn(5) == 0 && len(l) > 2 { // an edit: delete, insert or swap a character position (on runes)
			rs := []rune(l)
			p := r.Intn(len(rs))
			switch r.Intn(3) {
			case 0:
				rs = append(rs[:p], rs[p+1:]...)
			case 1:
				rs = append(rs[:p], append([]rune(genEdit[r.Intn(len(genEdit))]), rs[p:]...)...)
			default:
				q := r.Intn(len(rs))
				rs[p], rs[q] = rs[q], rs[p]
			}
			l = string(rs)
		}
		ls = append(ls, l)
	}
	return strings.Join(ls, "\n") + "\n"
}

func genCases() []blockCase { return genCasesSeed(20261101, 260, "gen") }

// genCasesSeed is genCases for any seed and count (the fuzz test uses other seeds).
func genCasesSeed(seed int64, n int, prefix string) []blockCase {
	r := rand.New(rand.NewSource(seed))
	flagSets := [][]string{nil, {"--ephemeral=warn"}, {"--backptr=all"}, {"--extern-check", "--backptr=all"}, {"--strict-ephemeral"}}
	var cs []blockCase
	for i := 0; i < n; i++ {
		files := bpCorpus(map[string]string{
			"c/src/Foo.java": nLines(20), "c/sources/probes/d1/out.txt": "x\n", "c/sources/probes/d1/run.sh": "echo run\n",
			"c/B12-triage.txt": nLines(10), "c/B12-x.txt": nLines(10), "c/bloque7-notes": nLines(4),
			"c/sources/extracted/tufte-vdqi-2001.md": "reliability: ocr-lossy\nsource_pdf: /x/Tufte Book.pdf\n",
		})
		files["c/kit-block9.md"] = genBlock(r)
		if r.Intn(4) == 0 {
			files["c/sources/probes/d1/SCRIPTS-MANIFEST.md"] = "| script | sha256 |\n|---|---|\n| run.sh | " + sha("echo run\n") + " |\n"
		}
		args := append(append([]string(nil), flagSets[r.Intn(len(flagSets))]...), "c/kit-block9.md")
		cs = append(cs, blockCase{name: fmt.Sprintf("%s-%03d", prefix, i), files: files, args: args})
	}
	return cs
}
