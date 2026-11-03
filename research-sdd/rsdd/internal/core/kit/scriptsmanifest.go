package kit

import (
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// The row reader of lib/scripts-manifest.sh (THE one definition, kit #2600): every consumer of a
// SCRIPTS-MANIFEST.md (verify block today, clean-check when it is ported) calls it.

// ScriptsManifestRows is scripts_manifest_rows <target> <manifest>: per valid row (a 64-hex sha cell) two
// `<target-relative path><TAB><sha256 lowercase>` lines - the resolved cell and <manifest dir>/<basename>. ok is
// false where the script returned 2 (unreadable manifest, or one outside the target).
func ScriptsManifestRows(fs fsview.View, target, mf string) ([]string, bool) {
	if target == "" || mf == "" || !fs.IsFile(mf) || !fs.Readable(mf) {
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
	md = strings.TrimSuffix(md, "/"+shellx.BaseName(md)) // ${md%/*}; no index guard left to mutate (#2598)
	src, err := fs.Read(mf)
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
