package stageissues

// cksum is POSIX cksum(1): the CRC-32 (polynomial 0x04C11DB7, MSB first, init 0) of the bytes followed by the
// byte length as little-endian bytes (as many as it needs), complemented.
func cksum(data []byte) uint32 {
	crc := uint32(0)
	feed := func(b byte) {
		crc ^= uint32(b) << 24
		for i := 0; i < 8; i++ {
			if crc&0x80000000 != 0 {
				crc = crc<<1 ^ 0x04C11DB7
			} else {
				crc <<= 1
			}
		}
	}
	for _, b := range data {
		feed(b)
	}
	for n := uint64(len(data)); n != 0; n >>= 8 {
		feed(byte(n))
	}
	return ^crc
}

// createIssue is the guarded `gh issue create` + read-back shared by delta rows and the tracking issue. The write
// is never retried: `confirmed` needs an issue URL in the output (creation is never inferred from output text) AND
// a read-back whose body carries the signature line; anything short of that is `unknown`, reported and counted.
//
// recheckSig is the exact line a failed create's re-run dedup search looks for; readbackLine is the line the
// read-back body must carry. tracker selects the tracker's message shapes (they differ from a row's: one
// combined read-back message, and `created:` names the last output line).
func (a *app) createIssue(row, title, labels, body, readbackLine, recheckSig string, tracker bool) {
	args := append([]string{"issue", "create", "--repo", a.repo, "--title", title}, labelFlags(labels)...)
	args = append(args, "--body", body)
	url, rc := a.gh(args...)
	if rc != 0 {
		// A failed create can still have written the issue (a timeout after the write). Re-run the exact-signature
		// lookup before counting a failure: a hit is `unknown-outcome` (the issue exists, nothing to retry); no hit
		// stays `failed`; a lookup that itself fails leaves the outcome unprovable, so it also stays `failed`.
		if a.recheckExists(recheckSig) == 0 {
			a.errf("unknown-outcome: gh issue create failed for row %s but a re-run dedup search found the issue (search matched '%s'): %s\n", row, recheckSig, url)
			a.summaryUnknown++
			a.rowUnknown(row)
			return
		}
		a.errf("ERROR: gh issue create failed for row %s: %s\n", row, url)
		// none = the re-check PROVED nothing was written; anything else could not look, so it is unknown.
		if a.recheckState == "none" {
			a.rowNoWrite(row)
		} else {
			a.rowUnknown(row)
		}
		a.failed++
		return
	}
	last := lastLine(url)
	m := reIssueURL.FindStringSubmatch(last)
	if m == nil {
		a.errf("unknown-outcome: gh issue create exited 0 for row %s but printed no issue URL (output: %s) — creation is not inferred from output text\n", row, url)
		a.summaryUnknown++
		a.rowUnknown(row)
		return
	}
	num := m[1]
	rb, rbrc := a.gh("issue", "view", num, "--repo", a.repo, "--json", "body", "--jq", ".body")
	rb = stripCR(rb)
	if tracker {
		if rbrc != 0 || !hasLine(rb, readbackLine) {
			a.errf("unknown-outcome: gh issue create returned %s for row tracker but the read-back failed or the body lacks the signature line '%s'\n", last, readbackLine)
			a.summaryUnknown++
			a.rowUnknown(row)
			return
		}
		a.outf("created: %s (row tracker)\n", last)
	} else {
		if rbrc != 0 {
			a.errf("unknown-outcome: gh issue create returned %s for row %s but the read-back failed (gh issue view exit %d): %s\n", last, row, rbrc, rb)
			a.summaryUnknown++
			a.rowUnknown(row)
			return
		}
		if !hasLine(rb, readbackLine) {
			a.errf("unknown-outcome: gh issue create returned %s for row %s but the read-back body lacks the signature line '%s'\n", last, row, readbackLine)
			a.summaryUnknown++
			a.rowUnknown(row)
			return
		}
		a.outf("created: %s (row %s)\n", url, row)
	}
	a.occCacheAdd(num, title)
	a.created++
	a.rowConfirmed(row)
}
