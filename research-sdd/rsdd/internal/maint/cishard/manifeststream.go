package cishard

import (
	"bytes"
	"encoding/json"
	"strings"
)

// streamInfo is what one `go test -json` stream said.
type streamInfo struct {
	final     map[string]string    // package -> its last package-level pass, fail or skip
	seen      map[string]bool      // packages that had any event with a Package
	skips     map[string]int       // package -> test-level skip events (subtests included)
	tops      map[string]topCounts // package -> its top-level test outcomes (a Test with no '/')
	unknown   map[string]int       // an Action the writer does not know -> its events ("(none)" when absent)
	events    int                  // lines read as events
	malformed int                  // non-blank lines that are not a JSON object
	blank     bool                 // the stream holds no byte but whitespace
}

// topCounts are the top-level test results of one package.
type topCounts struct{ pass, fail, skip int }

// event is the part of a test2json event the writer reads. Build events carry ImportPath and no Package.
type event struct {
	Action  string
	Package string
	Test    string
}

// knownAction reports whether test2json documents the action (go doc test2json, plus the build-output and build-fail
// events of `go test -json` since Go 1.24).
func knownAction(a string) bool {
	switch a {
	case "start", "run", "pause", "cont", "pass", "fail", "skip", "output", "bench", "attr", "build-output", "build-fail":
		return true
	}
	return false
}

// readStream reads the stream line by line. A line is split on '\n' only, so an event longer than a scanner's buffer
// (a test that prints a megabyte) is read whole, and the last event of a stream with no final newline is not lost.
func readStream(data []byte) streamInfo {
	st := streamInfo{
		final: map[string]string{}, seen: map[string]bool{}, skips: map[string]int{}, tops: map[string]topCounts{}, unknown: map[string]int{},
		blank: len(bytes.TrimSpace(data)) == 0,
	}
	for _, raw := range bytes.Split(data, []byte("\n")) {
		line := bytes.TrimSpace(raw)
		if len(line) == 0 {
			continue
		}
		var e event
		if json.Unmarshal(line, &e) != nil {
			st.malformed++
			continue
		}
		st.events++
		st.record(e)
	}
	return st
}

// record folds one event into the stream summary.
func (st *streamInfo) record(e event) {
	if !knownAction(e.Action) {
		name := e.Action
		if name == "" {
			name = "(none)"
		}
		st.unknown[name]++
	}
	if e.Package == "" {
		return
	}
	st.seen[e.Package] = true
	if e.Test != "" {
		if e.Action == "skip" {
			st.skips[e.Package]++
		}
		if !strings.Contains(e.Test, "/") { // a top-level test, not a subtest
			c := st.tops[e.Package]
			switch e.Action {
			case "pass":
				c.pass++
			case "fail":
				c.fail++
			case "skip":
				c.skip++
			}
			st.tops[e.Package] = c
		}
		return
	}
	if e.Action == "pass" || e.Action == "fail" || e.Action == "skip" {
		st.final[e.Package] = e.Action
	}
}
