package stageissues

import (
	"cmp"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// The `covers_through: B<n>` counter-reset proposal (kit issue #1640). The retro's machine-readable column-0
// line, optionally ` focus=<slug>` (the un-suffixed root state is focus=root), becomes a PRINTED proposal to reset
// blocks_since_retro in a NAMED RESEARCH-STATE file. PROPOSE-NEVER-APPLY (CLAUDE.md section 8): nothing edits a
// RESEARCH-STATE file or the retro; the human applies the line. FAIL-CLOSED: a line is proposed only when it
// unambiguously names one state file. Not-proposed states are named: no field -> a typed `absent` note, a
// malformed value -> a typed WARN. Fenced (``` and ~~~) lines are not read, and prose such as "coverage through
// B140" is deliberately not parsed. The grammar below is the one in research-sdd-status.sh (_rd_covers_derive).

var reCovers = regexp.MustCompile(`^covers_through:[ \t]+B[0-9]+([ \t]+focus=[A-Za-z0-9._-]+)?[ \t]*$`)

type coverLine struct {
	malformed bool
	n, slug   string
}

// coverLines is _CV_AWK over the raw retro lines.
func coverLines(lines []string) []coverLine {
	var out []coverLine
	fence := ""
	for _, l := range lines {
		if strings.HasPrefix(l, "```") || strings.HasPrefix(l, "~~~") {
			m := l[:1]
			switch fence {
			case "":
				fence = m
			case m:
				fence = ""
			}
			continue
		}
		if fence != "" || !strings.HasPrefix(l, "covers_through:") {
			continue
		}
		l = strings.TrimSuffix(l, "\r")
		if !reCovers.MatchString(l) {
			out = append(out, coverLine{malformed: true})
			continue
		}
		v := strings.TrimLeft(strings.TrimPrefix(l, "covers_through:"), " \t")[1:] // after the B
		n := v[:digitsLen(v)]
		slug := "-"
		if i := strings.LastIndex(v, "focus="); i != -1 {
			slug = strings.TrimRight(v[i+len("focus="):], " \t")
		}
		if len(n) > 9 {
			out = append(out, coverLine{malformed: true})
			continue
		}
		out = append(out, coverLine{n: n, slug: slug})
	}
	return out
}

func digitsLen(s string) int {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	return i
}

// stateFiles is `find <root> -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path
// '*/.git/*' | LC_ALL=C sort`, symlinks listed but not followed, unreadable directories skipped.
func stateFiles(root string) []string {
	var out []string
	rootDepth := strings.Count(filepath.Clean(root), string(filepath.Separator))
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		depth := strings.Count(filepath.Clean(p), string(filepath.Separator)) - rootDepth
		if p == root {
			depth = 0
		}
		name := d.Name()
		if strings.Contains(filepath.ToSlash(p)+"/", "/.git/") && p != root {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if p != root && strings.HasPrefix(name, "RESEARCH-STATE") && strings.HasSuffix(name, ".md") && !strings.HasSuffix(name, ".template.md") {
			out = append(out, p)
		}
		if d.IsDir() && depth >= 3 {
			return filepath.SkipDir
		}
		return nil
	})
	sort.Strings(out)
	return out
}

// counterRoot is the TARGET ROOT whose state files are counted: the retro's nearest registered ancestor (what
// research-sdd-status.sh is given as its target), not the retro's parent dir, so a split layout sees both state
// files. An unregistered target falls back to the retro's parent-of-retros dir.
func (a *app) counterRoot() string {
	root := a.targetDir
	retroDir, err := filepath.EvalSymlinks(filepath.Dir(a.retro))
	if err != nil {
		return root
	}
	if abs, e := filepath.Abs(retroDir); e == nil {
		retroDir = abs
	}
	src, err := kit.ReadTargets(a.targetsMD)
	if err != nil {
		return root
	}
	var hits []string // the registered roots that contain the retro
	for _, p := range kit.PairsAll(src, a.env) {
		if p.Expanded == "" {
			continue
		}
		x, ok := a.physDir(p.Expanded)
		if ok && strings.HasPrefix(retroDir+"/", x+"/") {
			hits = append(hits, x)
		}
	}
	if len(hits) == 0 {
		return root
	}
	// the nearest ancestor is the longest root; equal lengths are the same path, so the pick among them is moot
	return slices.MaxFunc(hits, func(x, y string) int { return cmp.Compare(len(x), len(y)) })
}

// physDir is `cd -P p && pwd -P` from the caller's cwd.
func (a *app) physDir(p string) (string, bool) {
	if !filepath.IsAbs(p) {
		p = filepath.Join(a.s.Cwd, p)
	}
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", false
	}
	st, err := os.Stat(r)
	if err != nil || !st.IsDir() {
		return "", false
	}
	return r, true
}

// printCounterReset is _print_counter_reset.
func (a *app) printCounterReset() {
	rb := filepath.Base(a.retro)
	cvroot := a.counterRoot()
	sfiles := stateFiles(cvroot)
	nsf := len(sfiles)
	anyValid, nm := false, 0
	for _, cl := range coverLines(a.doc.Raw) {
		if cl.malformed {
			nm++
			continue
		}
		anyValid = true
		val, slug := cl.n, cl.slug
		var hit string
		if slug == "-" {
			// an unscoped line is accepted only for a lone ROOT state file (a lone slugged one still needs focus=<slug>)
			switch {
			case nsf == 1 && filepath.Base(sfiles[0]) == "RESEARCH-STATE.md":
				hit = sfiles[0]
			case nsf == 0:
				a.warnf("WARN: covers_through B%s in %s: no RESEARCH-STATE file found under %s — no reset proposed\n", val, rb, cvroot)
				continue
			case nsf == 1:
				a.warnf("WARN: covers_through B%s in %s is unscoped but the only state file is %s — no reset proposed; write `covers_through: B%s focus=<slug>`\n", val, rb, filepath.Base(sfiles[0]), val)
				continue
			default:
				a.warnf("WARN: covers_through B%s in %s is unscoped but the corpus has %d state files — no reset proposed; write `covers_through: B%s focus=<slug>` (root focus: focus=root)\n", val, rb, nsf, val)
				continue
			}
		} else {
			nhit := 0
			for _, sf := range sfiles {
				sfs := strings.TrimPrefix(filepath.Base(sf), "RESEARCH-STATE")
				sfs = strings.TrimPrefix(sfs, "-")
				sfs = strings.TrimSuffix(sfs, ".md")
				if sfs == "" {
					sfs = "root"
				}
				if sfs == slug {
					hit = sf
					nhit++
				}
			}
			if nhit != 1 {
				a.warnf("WARN: covers_through B%s focus=%s in %s: %s matching state file(s) under %s — no reset proposed\n", val, slug, rb, strconv.Itoa(nhit), cvroot)
				continue
			}
		}
		rel := strings.TrimPrefix(hit, cvroot+"/")
		if slug == "-" {
			a.outf("proposed-reset: blocks_since_retro: 0 in %s (retro covers_through B%s; set it by hand only if no newer block exists — propose-never-apply)\n", rel, val)
		} else {
			a.outf("proposed-reset: blocks_since_retro: 0 in %s (retro covers_through B%s focus=%s; set it by hand only if no newer block of that focus exists — propose-never-apply)\n", rel, val, slug)
		}
	}
	if nm > 0 {
		a.warnf("WARN: covers_through: malformed — %d line(s) in %s (want `covers_through: B<n>` with a number) — ignored\n", nm, rb)
	}
	if !anyValid && nm == 0 {
		a.warnf("note: covers_through: absent in %s — no blocks_since_retro reset proposed\n", rb)
	}
}
