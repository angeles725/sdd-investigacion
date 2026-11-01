package verify

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"slices"
	"sort"
	"strings"
)

// Section 11 of verify-block.sh: a preserved script cited under sources/probes/ must be traceable to a row of a
// SCRIPTS-MANIFEST.md of the target, and the row's sha256 must equal the file's. The row parser is
// lib/scripts-manifest.sh (kit #1659), compiled in.

var reMFCite = newVB(`sources/probes/[A-Za-z0-9_./-]*\.(sh|ps1|py|java|js|rb|pl|bat|cmd|groovy|kts)\.?([^A-Za-z0-9_./-]|$)`)

func isNotASCIIAlnum(r rune) bool {
	return !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9')
}

func (v *vb) manifestCites() []string {
	var cites []string
	for _, l := range v.ls {
		for _, m := range reMFCite.FindAllString(l) {
			cites = append(cites, strings.TrimRightFunc(m, isNotASCIIAlnum))
		}
	}
	return sortedUnique(cites)
}

// mfRow is one valid manifest row: a target-relative path and its lowercase sha256.
type mfRow struct{ path, sha string }

// squeezeSlashes collapses `//` runs.
func squeezeSlashes(s string) string {
	for strings.Contains(s, "//") {
		s = strings.ReplaceAll(s, "//", "/")
	}
	return s
}

// manifestRows is scripts_manifest_rows <target> <manifest>: the valid rows of one manifest, or an error that
// carries the library's stderr line.
func (v *vb) manifestRows(target, mf string) ([]mfRow, error) {
	body, err := os.ReadFile(v.abs(mf))
	if err != nil || !v.isFile(mf) {
		return nil, fmt.Errorf("scripts-manifest: cannot read manifest %s", mf)
	}
	target, mf = squeezeSlashes(target), squeezeSlashes(mf)
	for strings.HasSuffix(target, "/") && strings.TrimSuffix(target, "/") != "" {
		target = strings.TrimSuffix(target, "/")
	}
	if !strings.HasPrefix(mf, target+"/") {
		return nil, fmt.Errorf("scripts-manifest: manifest %s is not under target %s", mf, target)
	}
	md := strings.TrimPrefix(mf, target+"/")
	if i := strings.LastIndex(md, "/"); i >= 0 {
		md = md[:i]
	}
	var rows []mfRow
	for _, l := range fileLines(string(body)) {
		if !reTableLine.MatchString(l) {
			continue
		}
		f := strings.Split(l, "|")
		if len(f) < 3 {
			f = append(f, "", "")
		}
		a := strings.Map(dropSpaceTick, f[1])
		b := strings.Map(dropSpaceTick, f[2])
		a = strings.TrimPrefix(a, "./")
		if a == "" || len(b) != 64 || strings.Trim(b, "0123456789abcdefABCDEF") != "" {
			continue
		}
		parts := strings.Split(a, "/")
		full := md + "/" + a
		if strings.HasPrefix(a, "sources/") {
			full = a
		}
		sha := strings.ToLower(b)
		rows = append(rows, mfRow{full, sha}, mfRow{md + "/" + parts[len(parts)-1], sha})
	}
	return rows, nil
}

// dropSpaceTick deletes backticks and [[:space:]] characters (awk's gsub(/[`[:space:]]/, "")).
func dropSpaceTick(r rune) rune {
	if r == '`' || isSpace(r) {
		return -1
	}
	return r
}

func (v *vb) manifest() {
	cites := v.manifestCites()
	var files []string
	frc := 0
	if v.isDir(v.target + "/sources/probes") {
		var ok bool
		files, ok = v.findFiles(v.target+"/sources/probes", 0, func(n string) bool { return n == "SCRIPTS-MANIFEST.md" })
		if !ok {
			frc = 1
		}
		sort.Strings(files)
	}
	v.say("-- preserved-script manifest (kit #1207: SCRIPTS-MANIFEST.md rows with sha256) --")
	switch {
	case frc != 0:
		v.say("   ERROR: DEGRADED manifest scan failed (find exit %d under %s/sources/probes) — cited scripts NOT manifest-checked", frc, v.target)
		v.rc = 1
	case len(files) == 0:
		v.say("   INFO    no SCRIPTS-MANIFEST under %s/sources/probes — preserved-script cites are not manifest-checked (%d cited)", v.target, len(cites))
	case len(cites) == 0:
		v.say("   (none — no preserved script cited under sources/probes/; manifests present: %d)", len(files))
	default:
		v.manifestCheck(cites, files)
	}
}

func (v *vb) manifestCheck(cites, files []string) {
	var rows []mfRow
	parseFailed := false
	for _, f := range files {
		one, err := v.manifestRows(v.target, f)
		if err != nil {
			fmt.Fprintln(v.errw, err)
			parseFailed = true
			break
		}
		rows = append(rows, one...)
	}
	if parseFailed {
		v.say("   ERROR: DEGRADED manifest parse failed (shared parser, under %s/sources/probes) — cited scripts NOT manifest-checked", v.target)
		v.rc = 1
		return
	}
	n := 0
	for _, c := range cites {
		var want []string
		for _, r := range rows {
			if r.path == c {
				want = append(want, r.sha)
			}
		}
		if len(want) == 0 {
			v.say("   MANIFEST!  %s  (no valid SCRIPTS-MANIFEST row for this script — add script|sha256|run/step|block|executed-on|remote-sha256|role)", c)
			v.rc = 1
			n++
			continue
		}
		have := "ABSENT"
		if v.isFile(v.target + "/" + c) {
			if body, err := os.ReadFile(v.abs(v.target + "/" + c)); err == nil {
				sum := sha256.Sum256(body)
				have = hex.EncodeToString(sum[:])
			} else {
				have = "UNREADABLE"
			}
		}
		switch {
		case have == "UNREADABLE":
			v.say("   MANIFEST!  %s  (preserved file exists but is unreadable — sha256 not computed)", c)
			v.rc = 1
			n++
		case slices.Contains(want, have):
			v.say("   manifest-ok  %s  (sha256 matches a row)", c)
		default:
			v.say("   MANIFEST!  %s  (manifest sha256 differs from the file's: %s)", c, have[:min(16, len(have))])
			v.rc = 1
			n++
		}
	}
	if n > 0 {
		v.say("-- preserved-script manifest findings: %d (FAIL)", n)
	}
}
