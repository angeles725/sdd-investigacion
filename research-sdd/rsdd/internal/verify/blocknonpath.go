package verify

import "strings"

// Tokens that look like a backticked `name.ext:NNN` cite but are not file cites (kit #973, #1721, #1742, #1766):
// `ip:port`, `host:port`, a fully-qualified class and (in the resolution loop) `Class.method:NNN`. They are listed as
// `nonpath` and never counted in the P9 "resolved N of M" summary.

var (
	vbNonpathRe = vbRe(`^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:|^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\.(com|io|net|org|dev|edu|gov|mx|local|lan|internal|cloud|app):|^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\.[A-Z][A-Za-z0-9_]*:`)
	vbVersioned = vbRe(`(^|\.)v[0-9]+(\.|$)`)

	vbExtSet = wordSet(vbFileExts)
	// vbTLDs holds ONLY the overlap of real TLDs with vbFileExts (P1721-TLD-GUARD).
	vbTLDSet = wordSet("org pl md rs sh sc ml tf cc")
)

func wordSet(s string) map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(s) {
		m[w] = true
	}
	return m
}

// versioned is _vb_np_versioned: a whole dot-separated label is `vN` (P1766-VERSION-LABEL).
func versioned(labels string) bool { return vbVersioned.MatchString(labels) }

// splitNonpath separates the nonpath tokens from the cites. A shape match is only a candidate: a token whose file
// exists under a source root, or whose last label is a known file extension (with the TLD and R guards), stays a cite.
func (b *blockRun) splitNonpath(bt []string) (nonpath, keep []string) {
	var cand []string
	for _, c := range bt {
		if vbNonpathRe.MatchString(c) {
			cand = append(cand, c)
		}
	}
	if len(cand) == 0 {
		return nil, bt
	}
	for _, c := range cand {
		hit := false
		for _, r := range []string{b.target, b.gitRoot, b.targetRoot, b.sourceRoot} { // P973-NONPATH-EXISTS
			if r != "" && b.fs.IsFile(r+"/"+citeFile(c)) {
				hit = true
				break
			}
		}
		stem := citeFile(c)
		last := stem[strings.LastIndex(stem, ".")+1:]
		labels := stem
		if i := strings.LastIndex(stem, "."); i >= 0 {
			labels = stem[:i]
		}
		first := stem
		if i := strings.Index(stem, "."); i >= 0 {
			first = stem[:i]
		}
		if !hit {
			if vbExtSet[last] { // P1721-NONPATH-EXT
				hit = true
				if vbTLDSet[last] && !versioned(labels) {
					hit = false
				}
			} else if last == "R" {
				pkg := false
				switch first {
				case "com", "org", "net", "io", "java", "javax", "jakarta", "android", "androidx", "edu", "gov", "kotlin", "scala", "sun", "jdk":
					pkg = true
				default:
					pkg = len(first) == 2 && first[0] >= 'a' && first[0] <= 'z' && first[1] >= 'a' && first[1] <= 'z'
				}
				if versioned(labels) {
					pkg = false
				}
				if !pkg {
					hit = true
				}
			}
		}
		if !hit {
			nonpath = append(nonpath, c)
		}
	}
	if len(nonpath) == 0 {
		return nil, bt
	}
	drop := map[string]bool{}
	for _, c := range nonpath {
		drop[c] = true
	}
	for _, c := range bt {
		if !drop[c] {
			keep = append(keep, c)
		}
	}
	return nonpath, keep
}

// citeFile is `${c%:*}`: the cite without its `:line` tail.
func citeFile(c string) string {
	if i := strings.LastIndex(c, ":"); i >= 0 {
		return c[:i]
	}
	return c
}
