package block

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// Section 11 of verify-block: SCRIPTS-MANIFEST (kit #1207, #1659, #2190). A preserved script cited under
// sources/probes/ must be traceable to a row of a `sources/probes/**/SCRIPTS-MANIFEST.md` of the target, and the
// row's sha256 must equal the file's. With no manifest at all the line is an INFO; with >= 1 manifest a cited script
// without a valid row, or whose every row's sha256 differs from the file's, is a FAIL (MANIFEST!, exit 1). The row
// parser is the port of lib/scripts-manifest.sh (scriptsManifestRows).

var vbMfCite = vbRe(`sources/probes/[A-Za-z0-9_./-]*\.(sh|ps1|py|java|js|rb|pl|bat|cmd|groovy|kts)\.?([^A-Za-z0-9_./-]|$)`)
var vbMfTrail = vbRe(`[^A-Za-z0-9]+$`)

func (b *blockRun) sectionManifest() {
	var cites []string
	for _, c := range grepOLines(vbMfCite, b.lines) {
		cites = append(cites, vbMfTrail.ReplaceAllString(c, ""))
	}
	cites = sortU(cites)
	var files []string
	frc := 0
	probes := b.target + "/sources/probes"
	if b.fs.IsDir(probes) {
		files, frc = b.findManifests(probes)
		sort.Strings(files)
	}
	b.echo("-- preserved-script manifest (kit #1207: SCRIPTS-MANIFEST.md rows with sha256) --")
	switch {
	case frc != 0:
		b.echo("   ERROR: DEGRADED manifest scan failed (find exit %d under %s/sources/probes) — cited scripts NOT manifest-checked", frc, b.target)
		b.rc = 1
	case len(files) == 0:
		b.echo("   INFO    no SCRIPTS-MANIFEST under %s/sources/probes — preserved-script cites are not manifest-checked (%d cited)", b.target, len(cites))
	case len(cites) == 0:
		b.echo("   (none — no preserved script cited under sources/probes/; manifests present: %d)", len(files))
	case !b.haveSHATool():
		b.echo("   ERROR: manifest check DEGRADED (neither sha256sum nor shasum on PATH) — cited scripts NOT checked")
		b.rc = 1
	default:
		b.checkManifestCites(cites, files)
	}
}

func (b *blockRun) checkManifestCites(cites, files []string) {
	var rows []string
	for _, f := range files {
		one, ok := b.scriptsManifestRows(b.target, f)
		if !ok {
			b.echo("   ERROR: DEGRADED manifest parse failed (shared parser, under %s/sources/probes) — cited scripts NOT manifest-checked", b.target)
			b.rc = 1
			return
		}
		rows = append(rows, one...)
	}
	n := 0
	for _, c := range cites {
		var want []string
		for _, r := range rows {
			if p, sha, ok := strings.Cut(r, "\t"); ok && p == c { // VB-MF-LOOKUP
				want = append(want, sha)
			}
		}
		if len(want) == 0 {
			b.echo("   MANIFEST!  %s  (no valid SCRIPTS-MANIFEST row for this script — add script|sha256|run/step|block|executed-on|remote-sha256|role)", c)
			b.rc = 1
			n++
			continue
		}
		have := "ABSENT"
		if b.fs.IsFile(b.target + "/" + c) {
			data, err := b.fs.Read(b.target + "/" + c)
			if err != nil {
				have = "UNREADABLE"
			} else {
				sum := sha256.Sum256(data)
				have = hex.EncodeToString(sum[:])
			}
		}
		switch {
		case have == "UNREADABLE":
			b.echo("   MANIFEST!  %s  (preserved file exists but is unreadable — sha256 not computed)", c)
			b.rc = 1
			n++
		case containsString(want, have): // VB-MF-SHA
			b.echo("   manifest-ok  %s  (sha256 matches a row)", c)
		default:
			b.echo("   MANIFEST!  %s  (manifest sha256 differs from the file's: %s)", c, have[:min(16, len(have))])
			b.rc = 1
			n++
		}
	}
	if n > 0 {
		b.echo("-- preserved-script manifest findings: %d (FAIL)", n)
	}
}

func containsString(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// haveSHATool is `command -v sha256sum || command -v shasum` against the caller's PATH.
func (b *blockRun) haveSHATool() bool {
	for _, dir := range strings.Split(b.s.Env("PATH"), ":") {
		if dir == "" {
			dir = "."
		}
		for _, tool := range []string{"sha256sum", "shasum"} {
			if st, err := os.Stat(b.fs.At(dir + "/" + tool)); err == nil && st.Mode().IsRegular() && st.Mode()&0o111 != 0 {
				return true
			}
		}
	}
	return false
}

// findManifests is `find ROOT -type f -name SCRIPTS-MANIFEST.md`: the paths as find prints them and find's exit
// status (1 where a directory could not be read). A start point that is a symbolic link is not entered.
func (b *blockRun) findManifests(root string) (files []string, rc int) {
	if st, err := os.Lstat(b.fs.At(root)); err != nil || !st.IsDir() {
		return nil, 0
	}
	var walk func(p string)
	walk = func(p string) {
		f, err := os.Open(b.fs.At(p))
		if err != nil {
			rc = 1
			return
		}
		ents, err := f.ReadDir(-1)
		f.Close()
		if err != nil {
			rc = 1
		}
		for _, e := range ents {
			q := joinFind(p, e.Name())
			switch {
			case e.IsDir():
				walk(q)
			case e.Type().IsRegular() && e.Name() == "SCRIPTS-MANIFEST.md":
				files = append(files, q)
			}
		}
	}
	walk(root)
	return files, rc
}

// scriptsManifestRows is scripts_manifest_rows <target> <manifest>: per valid row (a 64-hex sha cell) two
// `<target-relative path><TAB><sha256 lowercase>` lines - the resolved cell and <manifest dir>/<basename>. ok is
// false where the script returned 2 (unreadable manifest, or one outside the target).
func (b *blockRun) scriptsManifestRows(target, mf string) ([]string, bool) {
	if target == "" || mf == "" || !b.fs.IsFile(mf) || !b.fs.Readable(mf) {
		return nil, false
	}
	for strings.Contains(target, "//") { // SM-SLASH
		target = strings.ReplaceAll(target, "//", "/")
	}
	for strings.Contains(mf, "//") {
		mf = strings.ReplaceAll(mf, "//", "/")
	}
	for strings.HasSuffix(target, "/") && strings.TrimSuffix(target, "/") != "" {
		target = strings.TrimSuffix(target, "/")
	}
	if !strings.HasPrefix(mf, target+"/") {
		return nil, false
	}
	md := strings.TrimPrefix(mf, target+"/")
	if i := strings.LastIndex(md, "/"); i >= 0 {
		md = md[:i]
	}
	src, err := b.fs.Read(mf)
	if err != nil {
		return nil, false
	}
	var rows []string
	for _, line := range shellx.RecordLines(string(src)) {
		if !strings.HasPrefix(strings.TrimLeft(line, shellx.WsClass), "|") {
			continue
		}
		f := strings.Split(line, "|")
		cellOf := func(i int) string {
			if i >= len(f) {
				return ""
			}
			return strings.Map(func(r rune) rune {
				if r == '`' || strings.ContainsRune(shellx.WsClass, r) {
					return -1
				}
				return r
			}, f[i])
		}
		a, sha := cellOf(1), cellOf(2)
		a = strings.TrimPrefix(a, "./")
		if a != "" && len(sha) == 64 && isHex(sha) { // SM-ROW
			full := md + "/" + a
			if strings.HasPrefix(a, "sources/") {
				full = a
			}
			parts := strings.Split(a, "/")
			rows = append(rows, full+"\t"+strings.ToLower(sha), md+"/"+parts[len(parts)-1]+"\t"+strings.ToLower(sha))
		}
	}
	return rows, true
}

func isHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
