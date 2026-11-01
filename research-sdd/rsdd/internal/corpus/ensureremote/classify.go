package ensureremote

import (
	"encoding/base64"
	"encoding/hex"
	"regexp"
	"strings"
)

// The positive-identification classifier of Layer 4c (ensure-remote.sh rsdd_classify and the helpers under it,
// kit issue #1943). A blob is honoured as an allowed path only when it is POSITIVELY identified as public
// material; private markers are a hard refusal, LFS pointers cannot be inspected, and anything else stays refused.
//
// The bash reads a temp copy of each blob and works on its hex dump; this port classifies the blob bytes in memory
// and keeps the hex-string offsets of the DER helpers so every quirk of the original stays visible.

// class is the verdict on one committed blob (the exit codes 0, 1, 3 and 4 of rsdd_classify).
type class int

const (
	classPublic    class = iota // 0: positively public
	classPrivate                // 1: explicit private-key marker
	classNotPublic              // 3: not positively public
	classLFS                    // 4: Git LFS pointer, content not in the repository
)

// sniff is the number of bytes the bash reads (od -N 65537): a blob of more than 65536 bytes is never "small".
const sniff = 65537

var (
	reLFS     = regexp.MustCompile(`(?m)^version https://git-lfs.github.com/spec/v1`)
	rePrivate = regexp.MustCompile(`PRIVATE KEY( BLOCK)?-----|AGE-SECRET-KEY|PuTTY-User-Key-File|---- BEGIN SSH2`)
	reTextBad = regexp.MustCompile(`PRIVATE|SECRET|---- BEGIN|PuTTY-User-Key-File`)
	reHexRun  = regexp.MustCompile(`[0-9a-fA-F]{32,}`)
	reB64Run  = regexp.MustCompile(`[A-Za-z0-9+/=]{40,}`)
	reAlnum   = regexp.MustCompile(`[[:alnum:]]`)
	reCtrl    = regexp.MustCompile("[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]")

	reBegin     = regexp.MustCompile(`(?m)-----BEGIN`)
	reEnd       = regexp.MustCompile(`(?m)-----END`)
	reBeginOK   = regexp.MustCompile(`(?m)^-----BEGIN (CERTIFICATE|PUBLIC KEY|RSA PUBLIC KEY|X509 CRL|TRUSTED CERTIFICATE)-----\r?$`)
	reEndOK     = regexp.MustCompile(`(?m)^-----END (CERTIFICATE|PUBLIC KEY|RSA PUBLIC KEY|X509 CRL|TRUSTED CERTIFICATE)-----\r?$`)
	rePemBegin  = regexp.MustCompile(`^-----BEGIN (.*)-----$`)
	rePemStray  = regexp.MustCompile(`^[A-Za-z0-9+/=]{16,}$`)
	rePemBodyOK = regexp.MustCompile(`^[A-Za-z0-9+/=]*$`)
)

// classify is rsdd_classify over the blob b.
func classify(b []byte) class {
	if reLFS.Match(b) {
		return classLFS
	}
	if rePrivate.Match(b) {
		return classPrivate
	}
	head := b[:min(len(b), sniff)]
	h := hex.EncodeToString(head)
	if strings.HasPrefix(h, "30") {
		var rest string
		switch h[min(2, len(h)):min(4, len(h))] {
		case "81":
			rest = tail(h, 6)
		case "82":
			rest = tail(h, 8)
		case "83":
			rest = tail(h, 10)
		case "84":
			rest = tail(h, 12)
		default:
			rest = tail(h, 4)
		}
		if strings.HasPrefix(rest, "020100") || strings.HasPrefix(rest, "020101") {
			return classPrivate
		}
		if len(h) <= 131072 && derPublic(h) {
			return classPublic
		}
	}
	if textPublic(b) {
		return classPublic
	}
	return classNotPublic
}

// tail is ${h:n}: h from offset n, empty past the end.
func tail(h string, n int) string { return h[min(n, len(h)):] }

// sub is ${h:off:n}: at most n characters from off, empty past the end.
func sub(h string, off, n int) string { return h[min(off, len(h)):min(len(h), off+n)] }

// textPublic is rsdd_text_public: positively public PEM armour or licence text.
func textPublic(b []byte) bool {
	if len(b) == 0 || len(b) > 65536 { // [ -n "$h" ] && [ ${#h} -le 131072 ]
		return false
	}
	if strings.IndexByte(string(b), 0) >= 0 { // NUL byte -> binary
		return false
	}
	if reCtrl.Match(b) { // control bytes -> binary
		return false
	}
	if reBegin.Match(b) {
		nAll, nOK := countLines(reBegin, b), countLines(reBeginOK, b)
		eAll, eOK := countLines(reEnd, b), countLines(reEndOK, b)
		// The bash also demands nAll > 0 and refuses a line with two markers; both are unreachable here: reBegin matched,
		// so nAll >= 1, and a line with two markers can be counted by neither reBeginOK nor reEndOK, so the counts differ.
		if !(nAll == nOK && eAll == eOK && nOK == eOK) {
			return false
		}
		return pemPublic(b)
	}
	if reTextBad.Match(b) {
		return false
	}
	// key material hides as encoded runs anywhere in a line, not only as whole lines.
	if reHexRun.Match(b) || reB64Run.Match(b) {
		return false
	}
	// ... and as hex-byte dumps ("00 11 22 ..." / "00:11:22:..."): a line of 16+ hex digits once blanks and colons go.
	for _, l := range splitLines(b) {
		t := strings.Map(func(r rune) rune {
			switch r {
			case ' ', '\t', '\n', '\v', '\f', '\r', ':':
				return -1
			}
			return r
		}, string(l))
		if len(t) >= 16 && isHex(t) {
			return false
		}
	}
	return reAlnum.Match(b)
}

// countLines is grep -c: the lines of b on which re matches.
func countLines(re *regexp.Regexp, b []byte) int {
	n := 0
	for _, l := range splitLines(b) {
		if re.Match(l) {
			n++
		}
	}
	return n
}

// splitLines is the lines `read -r` sees: split on \n, a final unterminated line included, no empty tail line. Callers
// pass a non-empty blob.
func splitLines(b []byte) [][]byte {
	s := strings.TrimSuffix(string(b), "\n")
	var out [][]byte
	for _, l := range strings.Split(s, "\n") {
		out = append(out, []byte(l))
	}
	return out
}

func isHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !('0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F') {
			return false
		}
	}
	return true
}

// pemPublic is rsdd_pem_public: every armour block decodes (base64) to DER matching its label, every line inside a
// block is base64, and no line outside a block looks like encoded data.
func pemPublic(b []byte) bool {
	var lab, b64 string
	inBlock := false
	for _, raw := range splitLines(b) {
		l := strings.TrimSuffix(string(raw), "\r")
		switch {
		case !inBlock:
			if m := rePemBegin.FindStringSubmatch(l); m != nil {
				lab, b64, inBlock = m[1], "", true
				continue
			}
			if rePemStray.MatchString(l) {
				return false
			}
		case l == "-----END "+lab+"-----":
			der, err := base64.StdEncoding.DecodeString(b64)
			if err != nil {
				return false
			}
			h := hex.EncodeToString(der)
			if h == "" || !pemBlockOK(lab, h) {
				return false
			}
			inBlock = false
		default:
			if !rePemBodyOK.MatchString(l) {
				return false
			}
			b64 += l
		}
	}
	// The bash also wants one block (nblk > 0): unreachable, the caller saw a valid BEGIN line, which always opens one.
	return !inBlock
}

// tlv is rsdd_tlv: one DER tag-length header at hex-character offset o. It returns the tag (two hex characters),
// the content length in bytes and the header length in hex characters; ok is false when malformed or overrunning.
func tlv(h string, o int) (tag string, length, hdr int, ok bool) {
	tag = sub(h, o, 2)
	lb := sub(h, o+2, 2)
	if len(tag) != 2 || len(lb) != 2 {
		return "", 0, 0, false
	}
	first := hexVal(lb)
	if first < 128 {
		length, hdr = first, 4
	} else {
		nb := first - 128
		if nb < 1 || nb > 3 {
			return "", 0, 0, false
		}
		if len(h) < o+4+2*nb {
			return "", 0, 0, false
		}
		length, hdr = hexVal(h[o+4:o+4+2*nb]), 4+2*nb
	}
	return tag, length, hdr, o+hdr+2*length <= len(h)
}

// hexVal is $((16#x)) for a string of lower-case hex digits (hex.EncodeToString's alphabet).
func hexVal(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c <= '9' {
			c -= '0'
		} else {
			c = c - 'a' + 10
		}
		n = n*16 + int(c)
	}
	return n
}

// next reads a TLV at o, requires its tag, and returns the offset just past it.
func next(h string, o int, want string) (int, bool) {
	tag, l, hdr, ok := tlv(h, o)
	if !ok || tag != want {
		return 0, false
	}
	return o + hdr + 2*l, true
}

// derPublic is rsdd_der_public: an X.509 Certificate or an SPKI with a public-key OID, spanning the whole input.
func derPublic(h string) bool {
	tag, l, hdr, ok := tlv(h, 0)
	if !ok || tag != "30" {
		return false
	}
	top := hdr
	if hdr+2*l != len(h) {
		return false
	}
	tag, fLen, fHdr, ok := tlv(h, top)
	if !ok || tag != "30" {
		return false
	}
	fo := top
	nxt := fo + fHdr + 2*fLen
	head := sub(h, fo+fHdr, 10)
	switch {
	case head == "a003020100" || head == "a003020101" || head == "a003020102":
		// X.509: tbsCertificate{[0] version}, signatureAlgorithm, signatureValue
		n, ok := next(h, nxt, "30")
		if !ok {
			return false
		}
		tag, l, hdr, ok := tlv(h, n)
		if !ok || tag != "03" {
			return false
		}
		return n+hdr+2*l == len(h)
	case strings.HasPrefix(head, "06"):
		// SPKI: AlgorithmIdentifier{OID, params}, subjectPublicKey BIT STRING
		tag, oLen, oHdr, ok := tlv(h, fo+fHdr)
		if !ok || tag != "06" {
			return false
		}
		// The OID is read from the AlgorithmIdentifier's own content, so one that overruns it is truncated and matches
		// no known OID (none is a prefix of another). The bash refuses an overrun explicitly; the result is the same.
		alg := sub(h, fo+fHdr, 2*fLen)
		switch sub(alg, oHdr, 2*oLen) {
		case "2a864886f70d010101", "2a8648ce3d0201", "2b6570", "2b6571", "2b656e", "2b656f":
		default:
			return false
		}
		tag, l, hdr, ok = tlv(h, nxt)
		if !ok || tag != "03" {
			return false
		}
		return nxt+hdr+2*l == len(h)
	}
	return false
}

// pemBlockOK is rsdd_pem_block_ok: the DER payload of one PEM block must really be what its label claims.
func pemBlockOK(label, h string) bool {
	switch label {
	case "CERTIFICATE", "PUBLIC KEY":
		return derPublic(h)
	case "RSA PUBLIC KEY": // PKCS#1 RSAPublicKey: SEQUENCE{INTEGER n, INTEGER e}
		return seqOf(h, "02", "02")
	case "X509 CRL": // CertificateList: SEQUENCE{tbsCertList, signatureAlgorithm, signatureValue}
		return seqOf(h, "30", "30", "03")
	case "TRUSTED CERTIFICATE": // a Certificate followed by one SEQUENCE of trust settings
		_, l, hdr, ok := tlv(h, 0)
		if !ok {
			return false
		}
		end := hdr + 2*l
		if !derPublic(h[:end]) {
			return false
		}
		if end == len(h) {
			return true
		}
		tag, l, hdr, ok := tlv(h, end)
		return ok && tag == "30" && end+hdr+2*l == len(h)
	}
	return false
}

// seqOf checks h is one SEQUENCE that spans it whole and holds exactly the given element tags.
func seqOf(h string, tags ...string) bool {
	tag, l, hdr, ok := tlv(h, 0)
	if !ok || tag != "30" || hdr+2*l != len(h) {
		return false
	}
	o := hdr
	for _, t := range tags {
		var ok bool
		if o, ok = next(h, o, t); !ok {
			return false
		}
	}
	return o == len(h)
}
