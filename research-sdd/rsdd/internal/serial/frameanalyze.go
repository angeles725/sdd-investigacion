package serial

import (
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of toolbelt/serial-frame_analyze.py (kit issue #2437, epic #2270): offline analysis of a serial frame
// log (serial-frame.v1). `stats` gives the frame-length histogram and per-byte variability, `diff` the byte
// positions that differ between two captures, `checksum` the common checksum algorithms that validate.
//
// Exit codes (unchanged): 0 complete (an empty log is complete with zero frames), 1 parse error (a
// status:failed document is written), 2 I/O error (absent, unreadable, symlink or non-regular input, or an
// output that already exists; no document).
//
// Differences from the Python script, each in the direction of a typed refusal instead of a hang or crash:
//   - A non-regular input (FIFO, device, socket) is refused with exit 2; Python blocked on a FIFO open and
//     read a device without end. A directory fails as in Python ("Is a directory").
//   - Usage errors print the Go port's argparse-style message, not argparse's; the exit code (2) is the same.
//   - --input paths that are not valid UTF-8 are refused when the document is encoded (exit 2).

const (
	frameSchema      = "serial-frame.v1"
	analyzeTool      = "serial-frame-analyze"
	maxReadBytes     = 10 * 1024 * 1024 // read cap per input file
	maxFrames        = 10_000           // maximum frames loaded per file
	maxVariabilityHx = 6                // sample values listed per byte position
)

// pyWS is Python's \s for str patterns: every character whose isspace() is true.
const pyWS = `[\t-\r\x1c-\x20\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]`

// frameRe is FRAME_RE = r'len=\s*(\d+)\s+([0-9a-fA-F ]+)\s*$' with Python's Unicode-aware \s and \d.
var frameRe = regexp.MustCompile(`len=` + pyWS + `*(\p{Nd}+)` + pyWS + `+([0-9a-fA-F ]+)` + pyWS + `*$`)

// frameLog is what loadFrames found in one log file.
type frameLog struct {
	frames    [][]byte
	truncated bool
	sha256    string
	errors    []string // one per non-blank, non-comment line that is not a valid frame
	nonBlank  int      // non-blank, non-comment lines seen: separates empty input (0) from garbage input
}

// parseFrames reads frames from log text. Lines that are blank or start with '#' are ignored; any other line
// that is not a canonical `t_rel  len=N  HH HH ...` frame is a parse error, never a silent skip.
func parseFrames(text string) frameLog {
	var fl frameLog
	for i, line := range pySplitLines(text) {
		stripped := pyStrip(line)
		if stripped == "" || strings.HasPrefix(stripped, "#") {
			continue
		}
		fl.nonBlank++
		lineNum := i + 1
		m := frameRe.FindStringSubmatch(stripped)
		if m == nil {
			r := []rune(stripped)
			fl.errors = append(fl.errors, fmt.Sprintf("line %d: unrecognized format: %s", lineNum, pyRepr(string(r[:min(len(r), 60)]))))
			continue
		}
		declared := decimalString(m[1])
		tokens := strings.Fields(m[2])
		if actual := fmt.Sprint(len(tokens)); declared != actual {
			fl.errors = append(fl.errors, fmt.Sprintf("line %d: len mismatch: declared %s, got %s bytes", lineNum, declared, actual))
			continue
		}
		frame, ok := hexFrame(tokens)
		if !ok {
			fl.errors = append(fl.errors, fmt.Sprintf("line %d: bad hex: bytes must be in range(0, 256)", lineNum))
			continue
		}
		fl.frames = append(fl.frames, frame)
		if len(fl.frames) >= maxFrames {
			fl.truncated = true
			break
		}
	}
	return fl
}

// hexFrame converts hex tokens to bytes. A token is int(token, 16): leading zeros are free, so only a value
// above 0xff (more than two significant digits) is refused.
func hexFrame(tokens []string) ([]byte, bool) {
	frame := make([]byte, 0, len(tokens))
	for _, tok := range tokens {
		sig := strings.TrimLeft(tok, "0")
		if len(sig) > 2 {
			return nil, false
		}
		var v byte
		for _, c := range []byte(sig) {
			v = v<<4 | hexNibble(c)
		}
		frame = append(frame, v)
	}
	return frame, true
}

func hexNibble(c byte) byte {
	switch {
	case c >= 'a':
		return c - 'a' + 10
	case c >= 'A':
		return c - 'A' + 10
	}
	return c - '0'
}

// loadFrames reads and parses the log at path.
func loadFrames(path string) (frameLog, error) {
	data, size, sha, err := readLogFile(path, maxReadBytes)
	if err != nil {
		return frameLog{}, err
	}
	fl := parseFrames(pyDecodeReplace(data))
	fl.sha256 = sha
	if size > maxReadBytes {
		fl.truncated = true
	}
	return fl, nil
}

// SerialFrameAnalyze is the `rsdd serial frame-analyze` command.
func SerialFrameAnalyze(args []string, s cli.Stdio) int {
	cl := &cmdLine{prog: analyzeTool, about: "Offline analysis of serial frame captures (serial-frame.v1). Read-only; no hardware or network required.", subs: []subSpec{
		{name: "stats", args: []argSpec{{name: "input", required: true, metavar: "LOG"}, {name: "output", required: true, metavar: "JSON"}}},
		{name: "diff", args: []argSpec{{name: "input-a", required: true, metavar: "LOG_A"}, {name: "input-b", required: true, metavar: "LOG_B"}, {name: "output", required: true, metavar: "JSON"}}},
		{name: "checksum", args: []argSpec{{name: "input", required: true, metavar: "LOG"}, {name: "output", required: true, metavar: "JSON"}}},
	}}
	if code, done := cl.parse(args, s); done {
		return code
	}
	a := &analysis{s: s, cl: cl, out: cl.strs["output"]}
	switch cl.sub {
	case "stats":
		return a.stats(cl.strs["input"])
	case "diff":
		return a.diff(cl.strs["input-a"], cl.strs["input-b"])
	}
	return a.checksum(cl.strs["input"])
}

type analysis struct {
	s   cli.Stdio
	cl  *cmdLine
	out string
}

// load reads one input; a failure is reported on stderr and is exit 2.
func (a *analysis) load(path string) (frameLog, bool) {
	fl, err := loadFrames(path)
	if err != nil {
		fmt.Fprintf(a.s.Err, "%s: %s: %s\n", analyzeTool, path, ioReason(err, true))
		return fl, false
	}
	return fl, true
}

// write publishes the evidence document and returns exit (0 for a complete one, 1 for a failed one) or 2.
func (a *analysis) write(doc map[string]any, exit int) int {
	if err := writeJSON(a.out, doc); err != nil {
		fmt.Fprintf(a.s.Err, "%s: %s: %s\n", analyzeTool, a.out, ioReason(err, false))
		return cli.ExitUsage
	}
	return exit
}

func strList(items []string) []any {
	out := make([]any, len(items))
	for i, it := range items {
		out[i] = it
	}
	return out
}

func (a *analysis) stats(input string) int {
	fl, ok := a.load(input)
	if !ok {
		return cli.ExitUsage
	}
	if fl.nonBlank > 0 && len(fl.frames) == 0 {
		return a.write(map[string]any{
			"errors": strList(fl.errors), "line_count": fl.nonBlank, "mode": "stats", "schema": frameSchema,
			"skipped_line_count": len(fl.errors), "status": "failed", "tool": analyzeTool,
		}, cli.ExitOperational)
	}
	var order []int // lengths in first-seen order: the tie-break of the most common length
	counts := map[int]int{}
	for _, fr := range fl.frames {
		if counts[len(fr)] == 0 {
			order = append(order, len(fr))
		}
		counts[len(fr)]++
	}
	histogram := make([]any, 0, len(order))
	for _, l := range slices.SortedStableFunc(slices.Values(order), func(x, y int) int {
		if counts[x] != counts[y] {
			return counts[y] - counts[x]
		}
		return x - y
	}) {
		histogram = append(histogram, map[string]any{"count": counts[l], "length": l})
	}
	var mostCommon any
	variability := []any{}
	if len(order) > 0 {
		best := order[0]
		for _, l := range order[1:] {
			if counts[l] > counts[best] {
				best = l
			}
		}
		mostCommon = best
		variability = byteVariability(fl.frames, best)
	}
	doc := map[string]any{
		"input": map[string]any{
			"frame_count": len(fl.frames), "line_count": fl.nonBlank, "path": input,
			"sha256": fl.sha256, "skipped_line_count": len(fl.errors),
		},
		"mode": "stats",
		"results": map[string]any{
			"length_histogram": histogram, "most_common_length": mostCommon, "variability": variability,
		},
		"schema": frameSchema,
		"status": "complete",
		"summary": map[string]any{
			"distinct_lengths": len(counts), "frame_count": len(fl.frames), "line_count": fl.nonBlank,
			"skipped_line_count": len(fl.errors), "truncated": fl.truncated,
		},
		"tool":      analyzeTool,
		"truncated": fl.truncated,
	}
	if len(fl.errors) > 0 {
		doc["errors"] = strList(fl.errors)
	}
	return a.write(doc, cli.ExitOK)
}

// byteVariability reports, for each byte position of the frames of length l, the distinct values seen there.
func byteVariability(frames [][]byte, l int) []any {
	var group [][]byte
	for _, fr := range frames {
		if len(fr) == l {
			group = append(group, fr)
		}
	}
	out := make([]any, 0, l)
	for i := 0; i < l; i++ {
		var seen [256]bool
		for _, fr := range group {
			seen[fr[i]] = true
		}
		var vals []string
		distinct := 0
		for v := 0; v < 256; v++ {
			if seen[v] {
				distinct++
				if len(vals) < maxVariabilityHx {
					vals = append(vals, fmt.Sprintf("%02x", v))
				}
			}
		}
		out = append(out, map[string]any{
			"distinct_count": distinct, "is_constant": distinct == 1, "position": i, "sample_hex": strList(vals),
		})
	}
	return out
}

// frameKey groups frames by (length, first byte).
type frameKey struct{ length, first int }

// representative is the most frequent frame of a group; the first one seen wins a tie.
func representative(group [][]byte) []byte {
	var order []string
	counts := map[string]int{}
	for _, fr := range group {
		if counts[string(fr)] == 0 {
			order = append(order, string(fr))
		}
		counts[string(fr)]++
	}
	best := order[0]
	for _, k := range order[1:] {
		if counts[k] > counts[best] {
			best = k
		}
	}
	return []byte(best)
}

func (a *analysis) diff(inputA, inputB string) int {
	fa, ok := a.load(inputA)
	if !ok {
		return cli.ExitUsage
	}
	fb, ok := a.load(inputB)
	if !ok {
		return cli.ExitUsage
	}
	combined := append(slices.Clone(fa.errors), fb.errors...)
	if (fa.nonBlank > 0 && len(fa.frames) == 0) || (fb.nonBlank > 0 && len(fb.frames) == 0) {
		return a.write(map[string]any{
			"errors": strList(combined), "line_count_a": fa.nonBlank, "line_count_b": fb.nonBlank, "mode": "diff",
			"schema": frameSchema, "skipped_line_count_a": len(fa.errors), "skipped_line_count_b": len(fb.errors),
			"status": "failed", "tool": analyzeTool,
		}, cli.ExitOperational)
	}
	groupsA, groupsB := groupFrames(fa.frames), groupFrames(fb.frames)
	var shared []frameKey
	for k := range groupsA {
		if _, ok := groupsB[k]; ok {
			shared = append(shared, k)
		}
	}
	sort.Slice(shared, func(i, j int) bool {
		if shared[i].length != shared[j].length {
			return shared[i].length < shared[j].length
		}
		return shared[i].first < shared[j].first
	})
	types := make([]any, 0, len(shared))
	for _, k := range shared {
		repA, repB := representative(groupsA[k]), representative(groupsB[k])
		changed := []any{}
		for i := 0; i < k.length; i++ {
			if repA[i] != repB[i] {
				changed = append(changed, i)
			}
		}
		types = append(types, map[string]any{
			"changed_positions": changed, "first_byte_hex": fmt.Sprintf("%02x", k.first), "length": k.length,
		})
	}
	side := func(path string, fl frameLog) map[string]any {
		return map[string]any{
			"frame_count": len(fl.frames), "line_count": fl.nonBlank, "path": path, "sha256": fl.sha256,
			"skipped_line_count": len(fl.errors), "truncated": fl.truncated,
		}
	}
	doc := map[string]any{
		"input_a": side(inputA, fa),
		"input_b": side(inputB, fb),
		"mode":    "diff",
		"results": map[string]any{"shared_types": types},
		"schema":  frameSchema,
		"status":  "complete",
		"summary": map[string]any{
			"frame_count_a": len(fa.frames), "frame_count_b": len(fb.frames),
			"line_count_a": fa.nonBlank, "line_count_b": fb.nonBlank, "shared_type_count": len(types),
			"skipped_line_count_a": len(fa.errors), "skipped_line_count_b": len(fb.errors),
		},
		"tool": analyzeTool,
	}
	if len(combined) > 0 {
		doc["errors"] = strList(combined)
	}
	return a.write(doc, cli.ExitOK)
}

// groupFrames buckets frames by (length, first byte); a frame always has at least one byte (a frame line needs
// a hex token), so the first byte exists.
func groupFrames(frames [][]byte) map[frameKey][][]byte {
	groups := map[frameKey][][]byte{}
	for _, fr := range frames {
		k := frameKey{len(fr), int(fr[0])}
		groups[k] = append(groups[k], fr)
	}
	return groups
}
