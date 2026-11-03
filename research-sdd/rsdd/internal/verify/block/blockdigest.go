package block

import "strings"

// Section 9 of verify-block: EMPTY-INPUT DIGEST (#1487, METHODOLOGY section 11a). A cited hash equal to the digest of
// EMPTY input (sha256 e3b0c442..., sha1 da39a3ee..., md5 d41d8cd9...) proves nothing: it is what a hasher prints
// when the file was missing or empty. FAIL, one typed `EMPTYHASH!` line per occurrence. The match unit is a maximal
// hex run not glued to a preceding word character; an elided prefix (`e3b0c442…` / `e3b0c442...`) of >= 8 hex
// characters counts. A line ending in `<!-- empty-digest: quoted -->` waives its hits as an INFO.

var vbEmptyDigests = []struct{ kind, digest string }{ // VB-EMPTY-DIGEST-TABLE
	{"sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
	{"sha1", "da39a3ee5e6b4b0d3255bfef95601890afd80709"},
	{"md5", "d41d8cd98f00b204e9800998ecf8427e"},
}

var vbHexRun = vbRe(`[0-9a-f]+`)

func (b *blockRun) sectionEmptyDigest() {
	n, w := 0, 0
	for i, line := range b.lines {
		rest := awkLower(line)
		for {
			loc := vbHexRun.FindStringIndex(rest)
			if loc == nil {
				break
			}
			tok := rest[loc[0]:loc[1]]
			before := ""
			if loc[0] > 0 {
				before = lastRuneOf(rest[:loc[0]])
			}
			after := rest[loc[1]:]
			elided := strings.HasPrefix(after, "…") || strings.HasPrefix(after, "...")
			if !(len(before) == 1 && isLowerAlnumUnderscore(before[0])) {
				for _, d := range vbEmptyDigests {
					if tok == d.digest || (elided && len(tok) >= 8 && strings.HasPrefix(d.digest, tok)) { // VB-EMPTY-DIGEST-MATCH
						if strings.Contains(line, "<!-- empty-digest: quoted -->") { // VB-EH-WAIVER
							b.echo("   INFO    empty-digest waived on line %d (%s digest quoted on purpose, marker present)", i+1, d.kind)
							w++
						} else {
							ell := ""
							if len(tok) > 16 {
								ell = "…"
							}
							b.echo("   EMPTYHASH! line %d: %s digest of EMPTY input (%s%s) — proves nothing (file missing/empty when hashed); re-hash the real file", i+1, d.kind, tok[:min(16, len(tok))], ell)
							n++
							b.rc = 1
						}
					}
				}
			}
			rest = after
		}
	}
	if b.unreadable { // VB-UNREADABLE: the script's awk exited 2 on the unreadable block; never a clean "(none)"
		b.echo("   ERROR: empty-digest scan DEGRADED (awk exit 2, no scan trailer) — block NOT checked for empty-input digests")
		b.rc = 1
	} else if n == 0 {
		b.echo("   (none — no unwaived cited hash equals the digest of empty input; waived: %d)", w)
	} else {
		b.echo("-- empty-input digests cited: %d (FAIL)", n)
	}
}

func lastRuneOf(s string) string {
	r := []rune(s)
	return string(r[len(r)-1])
}

func isLowerAlnumUnderscore(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
}
