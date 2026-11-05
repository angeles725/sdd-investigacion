package sizecheck

import (
	"fmt"
	"io"
)

// Caps of the human report: the rest is counted, never hidden.
const (
	maxExcludedShown = 10
	maxFilesShown    = 25
)

// result is everything a verdict is printed from.
type result struct {
	o         options
	rng       string
	state     string
	t         tally
	hot       []hotspot
	unchecked []string
	chunks    []chunk
}

// writeReport is the human report, ending with the `size: <state>` line.
func writeReport(w io.Writer, r result) {
	t := r.t
	fmt.Fprintf(w, "kit-size-check: %s (base %s, head %s; budget %d, hard-limit %d)\n", r.rng, r.o.base, r.o.head, r.o.budget, r.o.hard)
	fmt.Fprintf(w, "authored changed lines: %d (+%d -%d) in %d file(s)\n", t.authored, t.adds, t.dels, len(t.files))
	fmt.Fprintf(w, "excluded (generated/fixture/lockfile, not counted): %d line(s) in %d file(s)\n", t.exLines, t.exFiles)
	for i, x := range t.excluded {
		if i >= maxExcludedShown {
			break
		}
		fmt.Fprintf(w, "  excluded  %6d  %s\n", x.lines, x.path)
	}
	if t.exFiles > maxExcludedShown {
		fmt.Fprintf(w, "  ... and %d more excluded file(s) (all counted in the total above)\n", t.exFiles-maxExcludedShown)
	}
	fmt.Fprintf(w, "unmeasured (binary): %d file(s)\n", len(t.unmeasured))
	for _, p := range t.unmeasured {
		fmt.Fprintf(w, "  unmeasured  %s\n", p)
	}
	fmt.Fprintf(w, "pure renames (0 lines): %d file(s)\n", len(t.renames))
	for _, p := range t.renames {
		fmt.Fprintf(w, "  rename  %s\n", p)
	}
	if len(t.files) > 0 {
		fmt.Fprintln(w, "per-file (largest first):")
		for i, f := range t.files {
			if i >= maxFilesShown {
				break
			}
			fmt.Fprintf(w, "  %6d  +%d -%d  %s\n", f.lines, f.add, f.del, f.path)
		}
		if len(t.files) > maxFilesShown {
			fmt.Fprintf(w, "  ... and %d more file(s)\n", len(t.files)-maxFilesShown)
		}
	}
	for _, h := range r.hot {
		fmt.Fprintf(w, "mechanical churn: %s holds %d%% of the lines (%d) and %d%% of its added lines repeat one pattern: %s\n", h.path, h.pct, h.lines, h.share, h.pattern)
		fmt.Fprintln(w, "  consider an env/config switch or a separate mechanical PR (e.g. #2200: the RSDD_INIT_WIRING switch)")
	}
	for _, p := range r.unchecked {
		fmt.Fprintf(w, "hotspot: unchecked %s (the churn diff failed; not read as \"no churn\")\n", p)
	}
	if len(r.chunks) > 0 {
		fmt.Fprintf(w, "split suggestion (test+SUT pairs kept together, <= %d lines per chunk):\n", r.o.budget)
		for _, c := range r.chunks {
			note := ""
			if c.note != "" {
				note = " (" + c.note + ")"
			}
			fmt.Fprintf(w, "  chunk %d: %d lines%s\n", c.idx, c.lines, note)
			for _, f := range c.files {
				fmt.Fprintf(w, "    %6d  %s\n", f.lines, f.path)
			}
		}
	}
	fmt.Fprintf(w, "size: %s\n", r.state)
}
