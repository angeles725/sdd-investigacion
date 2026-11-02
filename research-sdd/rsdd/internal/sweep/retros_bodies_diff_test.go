//go:build unix && !nodiff

package sweep

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"strings"
	"testing"
)

var updateBodies = flag.Bool("update-bodies", false, "rewrite the @@out frames of testdata/golden/bodies.txt from the frozen script")

// TestRetrosBodiesDifferential runs every case of the delta-counting corpus through the frozen script and the Go
// command; the golden is what the script printed, so this is also what keeps the golden honest.
func TestRetrosBodiesDifferential(t *testing.T) {
	for _, c := range readBodies(t, "testdata/golden/bodies.txt") {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			w.same("report", w.run(), w.bash("sweep-retros.sh"))
		})
	}
}

// TestUpdateBodies rewrites the expected reports of the corpus from the frozen script (run with -update-bodies).
func TestUpdateBodies(t *testing.T) {
	if !*updateBodies {
		t.Skip("run with -update-bodies to regenerate the golden from the frozen script")
	}
	var out bytes.Buffer
	for _, c := range readBodies(t, "testdata/golden/bodies.txt") {
		w := newWorld(t)
		c.build(w)
		r := w.bash("sweep-retros.sh")
		rep := strings.ReplaceAll(r.out+r.err, w.kit, "{kit}")
		fmt.Fprintf(&out, "@@case %s\n", c.name)
		for _, f := range c.files {
			fmt.Fprintf(&out, "@@file %s %d\n%s\n", f.rel, len(f.data), f.data)
		}
		fmt.Fprintf(&out, "@@out %d\n%s\n@@end\n", len(rep), rep)
	}
	if err := os.WriteFile("testdata/golden/bodies.txt", out.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}
