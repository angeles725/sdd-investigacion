package writercheck

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The two frozen contract files of kit issue #2208. They are read-only here: the PreToolUse hook and
// parse-red-evidence.cjs read the same lines.

const fixturesDir = "toolbelt/tests/fixtures/kit-writer-check/"

// tsvLines reads a contract file: the (verdict, text) pair of every non-comment line. An unreadable file panics,
// which fails the calling test with the path in the message (never an empty list that would pass vacuously).
func tsvLines(name string) [][2]string {
	p := filepath.Join(kitroot.Must(), fixturesDir+name)
	f, err := os.Open(p)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	var out [][2]string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if v, t, ok := strings.Cut(sc.Text(), "\t"); ok && !strings.HasPrefix(v, "#") {
			out = append(out, [2]string{v, t})
		}
	}
	if err := sc.Err(); err != nil {
		panic(err)
	}
	return out
}

// corpusLines is the name-kill corpus: (deny|allow, one shell command line).
func corpusLines() [][2]string { return tsvLines("name-kill-corpus.txt") }

// corpusText is every corpus command, one per line, as a script body.
func corpusText() string {
	var b strings.Builder
	for _, l := range corpusLines() {
		b.WriteString(l[1] + "\n")
	}
	return b.String()
}

// productionLines is the production-path list: (production|other, path).
func productionLines() [][2]string { return tsvLines("production-paths.txt") }

// classifyPaths is the argument list that classifies every path of the production list.
func classifyPaths() []string {
	args := []string{"--classify"}
	for _, l := range productionLines() {
		args = append(args, l[1])
	}
	return args
}
