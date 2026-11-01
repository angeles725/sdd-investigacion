package verify

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Sections 1 and 2 of verify-block.sh: roots, marker tally, the Type: line and the INFER/CERT ratio.

// physDir is `cd -P -- dir && pwd -P`: the physical directory, or false when dir cannot be entered. Relative
// paths resolve against the working directory.
func (v *vb) physDir(dir string) (string, bool) {
	a := dir
	if !filepath.IsAbs(a) {
		a = v.cwd + "/" + a
	}
	st, err := os.Stat(a)
	if err != nil || !st.IsDir() {
		return "", false
	}
	r, err := filepath.EvalSymlinks(a)
	if err != nil {
		return "", false
	}
	return r, true
}

// resolveRoots computes git_root (one `git rev-parse`, none when it fails) and the bounded TARGET-ROOT fallback
// of METHODOLOGY section 15: the parent of the nearest `corpus` ancestor, refused when it is `/`, $HOME or an
// ancestor of $HOME, accepted only when it holds a project marker.
func (v *vb) resolveRoots() {
	if out, err := gitRunner(v.s).Run(v.abs(v.target), "rev-parse", "--show-toplevel"); err == nil {
		v.gitRoot = sh(out)
	}
	trc := ""
	d, _ := v.physDirLogical(v.target)
	for d != "" && d != "/" {
		if basenameSh(d) == "corpus" {
			trc = dirnameSh(d)
			break
		}
		d = dirnameSh(d)
	}
	if trc != "" && trc != "/" {
		home := v.s.Env("HOME")
		if home == "" {
			home = "/"
		}
		if hp, ok := v.physDir(home); ok && strings.HasPrefix(hp+"/", trc+"/") {
			trc = ""
		}
	}
	if trc != "" && trc != "/" {
		for _, m := range []string{"package.json", "pyproject.toml", "pom.xml", "build.gradle", "go.mod", "Cargo.toml", "Makefile", ".git"} {
			if _, err := os.Lstat(trc + "/" + m); err == nil {
				v.targetRoot = trc
				break
			}
		}
	}
}

// physDirLogical is `cd "$target" && pwd -P`: like physDir, but the path is first resolved the way a plain
// `cd` does (`..` applied to the logical path), which filepath.Join's lexical cleaning reproduces.
func (v *vb) physDirLogical(dir string) (string, bool) {
	return v.physDir(v.abs(dir))
}

var tallyMarkers = []string{"CERT-hw", "CERT-live", "CERT", "CERT-doc", "CERT-web", "CERT-a", "INFER"}

// typeInfo is the parsed `> Type:` line, shared by the ratio line, P6 and P9.
type typeInfo struct {
	raw, token, stripped, class, warnName string
}

const (
	typesNocite = "synthesis capture document absence-centred decision design-applied"
	typesCite   = "standard evidence mixed collaborative audit"
)

var typesPipe = strings.ReplaceAll(typesCite, " ", " | ") + " | " + strings.ReplaceAll(typesNocite, " ", " | ")

var (
	reTypeLine   = newVB(`(?i)^[` + spc + `]*>[` + spc + `]*(\*\*)?[` + spc + `]*type:`)
	reBQ         = newVB(`^[` + spc + `]*>[` + spc + `]*`)
	reTypeBefore = newVB(`^.*[Tt][Yy][Pp][Ee]:`)
	reTypeToken  = newVB(`^[a-z][a-z0-9-]*`)
	reWarnStar   = newVB(`[` + spc + `]*\*.*`)
	reWarnDot    = newVB(`[` + spc + `]*\.[` + spc + `]*$`)
)

// replaceFirst is sed's `s/re//`.
func replaceFirst(re *vbRE, s string) string {
	if loc := re.FindStringIndex(s); loc != nil {
		return s[:loc[0]] + s[loc[1]:]
	}
	return s
}

func isStarTick(r rune) bool { return r == '*' || r == '`' || isSpace(r) }

func parseType(ls []string) typeInfo {
	var t typeInfo
	for _, l := range ls {
		if reTypeLine.MatchString(l) {
			t.raw = l
			break
		}
	}
	if t.raw != "" {
		noBQ := replaceFirst(reBQ, t.raw)
		after := replaceFirst(reTypeBefore, noBQ)
		t.stripped = strings.TrimLeftFunc(after, isStarTick)
		if loc := reTypeToken.FindStringIndex(t.stripped); loc != nil {
			t.token = t.stripped[loc[0]:loc[1]]
		}
	}
	t.class = "unknown"
	if t.token != "" {
		if strings.Contains(" "+typesNocite+" ", " "+t.token+" ") {
			t.class = "nocite"
		}
		if strings.Contains(" "+typesCite+" ", " "+t.token+" ") {
			t.class = "cite"
		}
	}
	t.warnName = t.token
	if t.warnName == "" {
		n := replaceFirst(reWarnStar, t.stripped)
		n = replaceFirst(reWarnDot, n)
		t.warnName = strings.TrimRightFunc(n, isSpace)
	}
	return t
}

// legendFence is the 1-based line of the `---` that closes the header blockquote (0 when none does): the scan
// stops at the first `## ` heading, and only a `---` after a `>` line counts.
func legendFence(ls []string) int {
	q := false
	for i, l := range ls {
		if strings.HasPrefix(l, "##") && len(l) > 2 && isSpace([]rune(l[2:])[0]) {
			return 0
		}
		if q && strings.HasPrefix(l, "---") && trimSpace(l[3:]) == "" {
			return i + 1
		}
		if strings.HasPrefix(trimLeftSpace(l), ">") {
			q = true
		}
	}
	return 0
}

func trimLeftSpace(s string) string { return strings.TrimLeftFunc(s, isSpace) }

func (v *vb) tally() {
	fence := legendFence(v.ls)
	body := v.ls
	if fence > 0 {
		body = v.ls[fence:]
	}
	bodyText := strings.Join(body, "\n")
	raw := map[string]int{}
	adj := map[string]int{}
	for _, m := range tallyMarkers {
		raw[m] = strings.Count(v.text, "["+m+"]")
		adj[m] = strings.Count(bodyText, "["+m+"]")
	}
	v.say("-- marker tally (raw = whole block · adj = claims, header legend stripped) --")
	for _, m := range tallyMarkers {
		if raw[m] != adj[m] {
			v.say("   [%s] %d  (adj %d)", m, raw[m], adj[m])
		} else {
			v.say("   [%s] %d", m, raw[m])
		}
	}
	if fence == 0 {
		v.say("   (no leading-blockquote '---' fence — adjusted = raw; the legend could not be isolated)")
	}
	v.certTotal = adj["CERT-hw"] + adj["CERT-live"] + adj["CERT"] + adj["CERT-doc"] + adj["CERT-web"] + adj["CERT-a"]
	v.codeCert = adj["CERT-hw"] + adj["CERT-live"] + adj["CERT"]
	v.adjInfer = adj["INFER"]
}

func (v *vb) ratio() {
	infer := v.adjInfer
	ratio := "n/a (no CERT markers)"
	if v.certTotal > 0 {
		ratio = fmt.Sprintf("%.2f", float64(infer)/float64(v.certTotal))
	}
	v.say("-- ratio -- [INFER]/[CERT*] = %d/%d = %s", infer, v.certTotal, ratio)
	v.typ = parseType(v.ls)
	var typeLine, tail string
	if v.typ.class != "unknown" {
		typeLine = "   declared Type: " + v.typ.token
		tail = "; read it against the declared Type, §11)"
	} else {
		switch {
		case v.typ.raw == "":
			typeLine = "   no blockquote Type: line found"
		case v.typ.warnName == "":
			typeLine = "   empty Type: line"
		default:
			typeLine = "   unrecognised Type '" + v.typ.warnName + "'"
		}
		tail = " — DECLARE the block TYPE so the ratio is read right, §11)"
	}
	v.say("%s", typeLine)
	v.say("   (>~0.5 in an EVIDENCE block signals investigable evidence nearly exhausted; EXPECTED and healthy in a")
	v.say("    DESIGN/synthesis block%s", tail)
}
