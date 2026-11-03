package corrections

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// longLines builds one block text of long prose lines: the shape that made the regexps cost per byte. Most lines
// carry no correction verb; a few do, so the scan loop runs too. It is generated, never asserted on.
func longLines() string {
	filler := strings.Repeat("The quick brown fox jumps over the lazy dog while B12 and B7-G3 stay quiet; ", 60)
	var b strings.Builder
	for i := 0; i < 40; i++ {
		b.WriteString(filler)
		b.WriteString("\n\n")
		b.WriteString(filler)
		b.WriteString(" This block corrects [Block 12] and [Block 13] here. ")
		b.WriteString(filler)
		b.WriteString("\n\n")
	}
	return b.String()
}

// BenchmarkExtractLongLines times the extractor over long lines. Timings are read by humans, never asserted.
func BenchmarkExtractLongLines(b *testing.B) {
	text := longLines()
	b.SetBytes(int64(len(text)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		extract(text)
	}
}

// BenchmarkRunRealCorpus profiles a whole run over $RSDD_BENCH_CORPUS (or ~/niagara5-research); it skips when the
// corpus is absent.
func BenchmarkRunRealCorpus(b *testing.B) {
	dir := os.Getenv("RSDD_BENCH_CORPUS")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			b.Skip("no home directory")
		}
		dir = filepath.Join(home, "niagara5-research")
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		b.Skip("corpus absent: " + dir)
	}
	for i := 0; i < b.N; i++ {
		var out, errb bytes.Buffer
		Run([]string{dir}, stdio(&out, &errb))
	}
}
