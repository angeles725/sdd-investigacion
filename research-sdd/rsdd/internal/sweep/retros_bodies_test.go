package sweep

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// testdata/golden/bodies.txt is the delta-counting and honesty corpus of the pre-port suite: the world (every
// file but the library staging) of each retro-content case (5, 29, 33-46, 55-61, 65, 66, 81-143) and the report
// the script printed for it. Case names are the old kit names (c81-honesty is old case 81). The output is
// regenerated from the frozen script by `go test -run UpdateBodies -update-bodies` (retros_diff_test.go), never
// by hand. Frame format, all counts in bytes:
//
//	@@case <name>
//	@@file <relative path> <n>\n<n bytes>\n          (TARGETS.md holds {kit} for the kit directory)
//	@@out <n>\n<n bytes>\n@@end                       (the report; {kit} for the kit directory)

type bodyCase struct {
	name  string
	files []bodyFile
	out   string
}

type bodyFile struct {
	rel  string
	data []byte
}

func readBodies(t testing.TB, path string) []bodyCase {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cases []bodyCase
	line := func() string {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			t.Fatalf("%s: truncated frame", path)
		}
		l := string(b[:i])
		b = b[i+1:]
		return l
	}
	chunk := func(n int) []byte {
		if len(b) < n+1 || b[n] != '\n' {
			t.Fatalf("%s: frame of %d bytes is not newline-terminated", path, n)
		}
		d := b[:n]
		b = b[n+1:]
		return d
	}
	for len(b) > 0 {
		h := line()
		name, ok := strings.CutPrefix(h, "@@case ")
		if !ok {
			t.Fatalf("%s: expected @@case, got %q", path, h)
		}
		c := bodyCase{name: name}
		for {
			h = line()
			if h == "@@end" {
				break
			}
			if rest, ok := strings.CutPrefix(h, "@@out "); ok {
				n, _ := strconv.Atoi(rest)
				c.out = string(chunk(n))
				continue
			}
			rest, ok := strings.CutPrefix(h, "@@file ")
			i := strings.LastIndexByte(rest, ' ')
			if !ok || i < 0 {
				t.Fatalf("%s: bad frame header %q", path, h)
			}
			n, _ := strconv.Atoi(rest[i+1:])
			c.files = append(c.files, bodyFile{rest[:i], chunk(n)})
		}
		cases = append(cases, c)
	}
	return cases
}

// build lays the case's world out under the world's kit; every file is dated now, so an age never depends on
// the day the golden was recorded.
func (c bodyCase) build(w *world) {
	for _, f := range c.files {
		data := f.data
		if f.rel == "TARGETS.md" {
			data = bytes.ReplaceAll(data, []byte("{kit}"), []byte(w.kit))
		}
		p := filepath.Join(w.kit, f.rel)
		w.must(os.MkdirAll(filepath.Dir(p), 0o755))
		w.must(os.WriteFile(p, data, 0o644))
		w.must(os.Chtimes(p, w.now, w.now))
	}
}

func (c bodyCase) want(w *world) string { return strings.ReplaceAll(c.out, "{kit}", w.kit) }

func TestRetrosBodiesGolden(t *testing.T) {
	cases := readBodies(t, "testdata/golden/bodies.txt")
	if len(cases) < 80 {
		t.Fatalf("the corpus holds %d cases; a truncated golden must fail, not pass", len(cases))
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			r := w.run()
			if r.rc != 0 || r.err != "" || r.out != c.want(w) {
				t.Errorf("rc=%d stderr=%q\ngot:\n%s\nwant:\n%s", r.rc, r.err, r.out, c.want(w))
			}
		})
	}
}

// The corpus is meaningful: it holds each delta form and WARN the sweep can print, so a golden regenerated from a
// broken script cannot silently drop one.
func TestRetrosBodiesCoverage(t *testing.T) {
	var all strings.Builder
	for _, c := range readBodies(t, "testdata/golden/bodies.txt") {
		all.WriteString(c.out)
	}
	for _, want := range []string{"~0 proposed deltas", "~1 proposed deltas", "~3 proposed deltas", "~? proposed deltas",
		"no delta section found (empty-input)", "WARN: delta section present but not in countable form — count by hand",
		"WARN: non-conforming delta declaration — count by hand", "WARN: deprecated delta heading [", "Nothing to review."} {
		if !strings.Contains(all.String(), want) {
			t.Errorf("no golden case prints %q", want)
		}
	}
}
