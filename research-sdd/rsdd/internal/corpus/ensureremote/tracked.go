package ensureremote

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// trackedSecrets is LAYER 4c: refuse any git-TRACKED secret-type file, the binary types scan-secrets.sh can never
// see. A tracked key or certificate would pass the content scan (it is never opened) and get pushed.
//
// FAIL CLOSED: if `ls-files` itself errors, or an allowed path cannot be verified, refuse rather than proceed.
func (c *command) trackedSecrets() int {
	ls := c.gitBound(shortBound, nil, append([]string{"ls-files", "-z", "--"}, trackedPathspecs...)...)
	if ls.RC != 0 {
		return c.refuse(exitTooling, "REFUSED: could not enumerate tracked files (git ls-files failed) — cannot verify no secret is tracked.")
	}
	entries, code := c.readAllowList()
	if code != 0 {
		return code
	}

	// bash converts NUL to newline inside the pipe and reads the result line by line
	raw := strings.TrimRight(strings.ReplaceAll(string(ls.Stdout), "\x00", "\n"), "\n")
	hit := make([]bool, len(entries))
	var unallowed, privBad, notPub, lfsPtr []string
	for _, p := range strings.Split(raw, "\n") {
		if p == "" {
			continue
		}
		first := -1
		for i, e := range entries {
			if globMatch(e.glob, p) {
				hit[i] = true
				if first < 0 {
					first = i
				}
			}
		}
		if first < 0 {
			unallowed = append(unallowed, p)
			continue
		}
		switch base := p[strings.LastIndexByte(p, '/')+1:]; {
		case strings.HasPrefix(base, "id_rsa"), strings.HasSuffix(base, ".p12"), strings.HasSuffix(base, ".pfx"),
			strings.HasSuffix(base, ".jks"), strings.HasSuffix(base, ".keystore"):
			privBad = append(privBad, p)
			continue
		}
		state, nblob, code := c.walkHistory(p)
		if code != 0 {
			return code
		}
		switch state {
		case classPrivate:
			privBad = append(privBad, p)
		case classNotPublic:
			notPub = append(notPub, p)
		case classLFS:
			lfsPtr = append(lfsPtr, p)
		default:
			c.out("ALLOWED: %s (%s:%d allow %s; %d blob(s) positively public)\n", p, allowRel, entries[first].line, entries[first].glob, nblob)
		}
	}
	for i, e := range entries {
		if !hit[i] {
			c.errf("STALE: %s:%d 'allow %s' matches no refused tracked path — remove it.\n", allowRel, e.line, e.glob)
		}
	}
	if len(privBad) > 0 {
		return c.refuse(exitLeak,
			"REFUSED: allowed path(s) contain private key material or are keystore/identity files: "+strings.Join(privBad, " "),
			"         a private key can never be allowed — untrack it (git rm --cached) and cite it by structure + sha256.")
	}
	if len(lfsPtr) > 0 {
		for _, p := range lfsPtr {
			c.errf("REFUSED (LFS pointer: content not inspectable): %s\n", p)
		}
		return c.refuse(exitLeak, "         the real content lives outside this repository's objects, so it cannot be shown to be public.")
	}
	if len(notPub) > 0 {
		for _, p := range notPub {
			c.errf("REFUSED (not positively public): %s\n", p)
		}
		return c.refuse(exitLeak,
			"         an allowed path must be positively identified as public (PEM cert/public key, DER cert/SPKI, licence text)",
			"         in EVERY committed revision; anything else stays refused. Untrack it and cite it by structure + sha256.")
	}
	if len(unallowed) > 0 {
		return c.refuse(exitLeak,
			"REFUSED: secret-bearing file(s) are git-TRACKED and would be pushed: "+strings.Join(unallowed, " "),
			"         scan-secrets.sh cannot see these binary types. Untrack them first:",
			fmt.Sprintf("         git -C \"%s\" rm --cached <file> ; ensure they are in .gitignore ; commit ; re-run.", c.target))
	}
	return 0
}

// readAllowList reads <target>/.research-sdd/secret-files.conf. A malformed line is a typed config error (exit 2):
// nothing is created or pushed.
func (c *command) readAllowList() ([]allowEntry, int) {
	conf := filepath.Join(c.target, allowRel)
	if _, err := os.Lstat(conf); err != nil {
		return nil, 0
	}
	fi, err := os.Stat(conf)
	var data []byte
	if err == nil && fi.Mode().IsRegular() {
		data, err = os.ReadFile(conf)
	}
	if err != nil || !fi.Mode().IsRegular() {
		return nil, c.refuse(exitTooling, "REFUSED: "+allowRel+" exists but is not a readable regular file — cannot read the allow list.")
	}
	entries, bad, why := parseAllow(data)
	if why != "" {
		return nil, c.refuse(exitUsage, fmt.Sprintf("REFUSED: %s:%d: %s — expected 'allow <path-glob>'.", allowRel, bad, why))
	}
	return entries, 0
}

// walkHistory classifies EVERY committed blob of p (all refs, merges included, side branches merged away too): both
// the pre-image and the post-image id of every raw diff line. It stops at the first blob that is not positively
// public and returns that verdict, with the number of distinct blobs seen.
func (c *command) walkHistory(p string) (class, int, int) {
	log := c.gitBound(shortBound, []string{"--literal-pathspecs"},
		"log", "--all", "-m", "--full-history", "--no-renames", "--format=", "--raw", "--no-abbrev", "--", p)
	if log.RC != 0 {
		return 0, 0, c.refuse(exitTooling, "REFUSED: could not read the git history of '"+p+"' (git log failed) — cannot verify it is public.")
	}
	seen := map[string]bool{}
	nblob, state := 0, classPublic
walk:
	for _, line := range strings.Split(trimNL(log.Stdout), "\n") {
		f := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })
		if len(f) == 0 || !strings.HasPrefix(f[0], ":") {
			continue
		}
		for i := 2; i <= 3; i++ {
			id := ""
			if i < len(f) {
				id = f[i]
			}
			if !isLowerHex(id) {
				return 0, 0, c.refuse(exitTooling, "REFUSED: unparseable git history for '"+p+"' — cannot verify it is public.")
			}
			if strings.Trim(id, "0") == "" || seen[id] { // all-zero id = no blob on that side
				continue
			}
			seen[id] = true
			nblob++
			blob := c.gitBound(shortBound, nil, "cat-file", "blob", id)
			if blob.RC != 0 {
				return 0, 0, c.refuse(exitTooling, "REFUSED: could not read blob "+id+" of '"+p+"' (git cat-file failed) — cannot verify it is public.")
			}
			if state = classify(blob.Stdout); state != classPublic {
				break walk
			}
		}
	}
	if nblob == 0 {
		return 0, 0, c.refuse(exitTooling, "REFUSED: no committed blob found for '"+p+"' — cannot verify it is public.")
	}
	return state, nblob, 0
}

func isLowerHex(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; !('0' <= c && c <= '9' || 'a' <= c && c <= 'f') {
			return false
		}
	}
	return true
}
