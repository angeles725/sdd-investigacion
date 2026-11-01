package ensureremote

import (
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// Boundary tests for the classifier: every size limit and every DER length form, at the value itself and one
// either side. These pin the arithmetic that the table tests above only exercise in the middle.

// lenHex is a DER length in hex: short form below 128, else 0x81/0x82/0x83 and 1/2/3 bytes.
func lenHex(n int) string {
	switch {
	case n < 128:
		return fmt.Sprintf("%02x", n)
	case n < 256:
		return fmt.Sprintf("81%02x", n)
	case n < 65536:
		return fmt.Sprintf("82%04x", n)
	}
	return fmt.Sprintf("83%06x", n)
}

// certInner is the content of an X.509 Certificate SEQUENCE: tbsCertificate{[0] version ...}, signatureAlgorithm,
// signatureValue. The tbs is padded by p bytes and the signature BIT STRING by m.
func certInner(p, m int) string {
	tbs := "a003020102" + "04" + lenHex(p) + strings.Repeat("00", p)
	bs := "00" + strings.Repeat("00", m)
	return "30" + lenHex(len(tbs)/2) + tbs + "300306012a" + "03" + lenHex(len(bs)/2) + bs
}

// certOfSize is a Certificate DER of exactly n bytes with the shortest outer header: the tbs padding is searched in a
// narrow window around n (each probe is O(n), so the window, not the whole range, is scanned).
func certOfSize(t *testing.T, n int) []byte {
	t.Helper()
	for p := max(0, n-70); p <= n; p++ {
		for m := 0; m < 12; m++ {
			in := certInner(p, m)
			if len(in)/2+1+len(lenHex(len(in)/2))/2 == n {
				return unhex(t, "30"+lenHex(len(in)/2)+in)
			}
		}
	}
	t.Fatalf("no certificate of %d bytes", n)
	return nil
}

func TestSniffLimitOfADERCertificate(t *testing.T) {
	for _, tt := range []struct {
		size int
		want class
	}{{65535, classPublic}, {65536, classPublic}, {65537, classNotPublic}, {65538, classNotPublic}} {
		b := certOfSize(t, tt.size)
		if len(b) != tt.size {
			t.Fatalf("built %d bytes, want %d", len(b), tt.size)
		}
		if got := classify(b); got != tt.want {
			t.Errorf("DER certificate of %d bytes: %s, want %s", tt.size, classNames[got], classNames[tt.want])
		}
	}
}

func text(n int) []byte {
	k := (n - 1) / 10
	r := n - 10*k
	return []byte(strings.Repeat("word word\n", k) + strings.Repeat("a", r-1) + "\n")
}

func TestSizeLimitOfPlainText(t *testing.T) {
	for _, tt := range []struct {
		size int
		want class
	}{{65535, classPublic}, {65536, classPublic}, {65537, classNotPublic}, {70000, classNotPublic}} {
		b := text(tt.size)
		if len(b) != tt.size {
			t.Fatalf("built %d bytes, want %d", len(b), tt.size)
		}
		if got := classify(b); got != tt.want {
			t.Errorf("text of %d bytes: %s, want %s", tt.size, classNames[got], classNames[tt.want])
		}
	}
}

func TestNULAtTheStartIsBinary(t *testing.T) {
	if got := classify([]byte("\x00MIT License\n")); got != classNotPublic {
		t.Errorf("leading NUL: %s", classNames[got])
	}
	if got := classify([]byte("MIT License\n\x00")); got != classNotPublic {
		t.Errorf("trailing NUL: %s", classNames[got])
	}
}

// The hex-dump rule recognises exactly [0-9a-fA-F]; the characters next to each range are not hex.
func TestHexDumpAlphabetBoundaries(t *testing.T) {
	line := func(c string) []byte {
		return []byte("Licence\n" + strings.TrimSpace(strings.Repeat(c+c+" ", 8)) + "\n")
	}
	for _, c := range []string{"0", "9", "a", "f", "A", "F", "5", "c", "C"} {
		if got := classify(line(c)); got != classNotPublic {
			t.Errorf("a dump of %q is hex: %s", c, classNames[got])
		}
	}
	for _, c := range []string{"/", "@", "G", "`", "g", "z", "Z"} {
		if got := classify(line(c)); got != classPublic {
			t.Errorf("a dump of %q is not hex: %s", c, classNames[got])
		}
	}
}

func TestTLVForms(t *testing.T) {
	for _, tt := range []struct {
		name        string
		h           string
		tag         string
		length, hdr int
		ok          bool
	}{
		{"short-zero", "3000", "30", 0, 4, true},
		{"short-127", "307f" + strings.Repeat("00", 127), "30", 127, 4, true},
		{"81-zero", "308100", "30", 0, 6, true},
		{"81-128", "308180" + strings.Repeat("00", 128), "30", 128, 6, true},
		{"81-truncated-header", "3081", "", 0, 0, false},
		{"81-truncated-content", "308105" + "00000000", "", 0, 0, false},
		{"82-zero", "30820000", "30", 0, 8, true},
		{"82-258", "30820102" + strings.Repeat("00", 258), "30", 258, 8, true},
		{"82-truncated-header", "308200", "", 0, 0, false},
		{"83-zero", "3083000000", "30", 0, 10, true},
		{"83-259", "3083000103" + strings.Repeat("00", 259), "30", 259, 10, true},
		{"83-truncated-header", "30830000", "", 0, 0, false},
		{"84-refused", "3084000000" + "00", "", 0, 0, false},
		{"80-indefinite-refused", "3080" + strings.Repeat("00", 128), "", 0, 0, false},
		{"empty", "", "", 0, 0, false},
		{"tag-only", "30", "", 0, 0, false},
		{"offset", "ff" + "3000", "30", 0, 4, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			o := 0
			if tt.name == "offset" {
				o = 2
			}
			tag, l, hdr, ok := tlv(tt.h, o)
			if ok != tt.ok || (ok && (tag != tt.tag || l != tt.length || hdr != tt.hdr)) {
				t.Errorf("tlv = %q %d %d %v, want %q %d %d %v", tag, l, hdr, ok, tt.tag, tt.length, tt.hdr, tt.ok)
			}
		})
	}
}

// A Certificate under every header form of its outer SEQUENCE.
func TestDERCertificateHeaderForms(t *testing.T) {
	for _, tt := range []struct {
		name string
		h    string
		want bool
	}{
		{"short", "30" + lenHex(len(certInner(0, 0))/2) + certInner(0, 0), true},
		{"81", "30" + lenHex(len(certInner(150, 0))/2) + certInner(150, 0), true},
		{"82", "30" + lenHex(len(certInner(300, 0))/2) + certInner(300, 0), true},
		{"83", "30" + lenHex(len(certInner(70000, 0))/2) + certInner(70000, 0), true},
		{"84-refused", "3084" + fmt.Sprintf("%08x", len(certInner(0, 0))/2) + certInner(0, 0), false},
		{"80-refused", "3080" + certInner(0, 0), false},
	} {
		if got := derPublic(tt.h); got != tt.want {
			t.Errorf("%s: derPublic = %v, want %v", tt.name, got, tt.want)
		}
	}
	// 0x80 must not read as a short length of 128 even when the body happens to be 128 bytes of valid content
	var in string
	for p := 0; p < 200; p++ {
		if x := certInner(p, 0); len(x)/2 == 128 {
			in = x
		}
	}
	if in == "" {
		t.Fatal("no 128-byte certificate body")
	}
	if derPublic("3080" + in) {
		t.Error("an indefinite length (0x80) was read as a short length of 128")
	}
	if !derPublic("30" + "8180" + in) {
		t.Error("the same body under the definite 0x81 0x80 form is a certificate")
	}
}

func TestDERSubjectPublicKeyInfoShapes(t *testing.T) {
	for _, tt := range []struct {
		name string
		h    string
		want bool
	}{
		{"rsa", spkiHex, true},
		{"ec-oid-fills-the-algorithm", "3010" + "3009" + "06072a8648ce3d0201" + "030300dead", true},
		{"oid-overruns-the-algorithm", "3009" + "3002" + "0605" + "2a864886f7", false},
		{"algorithm-header-truncated", "30053003068200", false},
		{"bit-string-wrong-tag", strings.Replace(spkiHex, "030400deadbe", "040400deadbe", 1), false},
		{"bit-string-short", strings.Replace(spkiHex, "030400deadbe", "030300deadbe", 1), false},
		{"unknown-oid", strings.Replace(spkiHex, "2a864886f70d010101", "2a864886f70d010105", 1), false},
		{"algorithm-not-sequence", "3015" + "310d" + spkiHex[8:], false},
		{"first-element-neither-version-nor-oid", "3015" + "300d" + "04092a864886f70d0101010500030400deadbe", false},
	} {
		if got := derPublic(tt.h); got != tt.want {
			t.Errorf("%s: derPublic = %v, want %v", tt.name, got, tt.want)
		}
	}
}

func TestPEMBlockOKRefusesWhatItDoesNotKnow(t *testing.T) {
	for _, tt := range []struct {
		label, h string
	}{
		{"EC PRIVATE KEY", certHex},
		{"", certHex},
		{"TRUSTED CERTIFICATE", "30"},           // a payload that is not even a TLV
		{"TRUSTED CERTIFICATE", "3003020100"},   // a TLV, but not a certificate
		{"TRUSTED CERTIFICATE", certHex + "30"}, // a certificate and a truncated trust SEQUENCE
		{"RSA PUBLIC KEY", "30"},
		{"X509 CRL", "30"},
	} {
		if pemBlockOK(tt.label, tt.h) {
			t.Errorf("pemBlockOK(%q, %s) = true", tt.label, tt.h)
		}
	}
	if !pemBlockOK("TRUSTED CERTIFICATE", certHex) || !pemBlockOK("TRUSTED CERTIFICATE", certHex+"3003020100") {
		t.Error("a bare or trust-annotated certificate is public")
	}
}

func TestUnhexHelperRoundTrips(t *testing.T) {
	if hex.EncodeToString(unhex(t, spkiHex)) != spkiHex {
		t.Error("unhex")
	}
}

func TestCountLines(t *testing.T) {
	re := regexp.MustCompile(`^x`)
	for _, tt := range []struct {
		in   string
		want int
	}{{"x\n", 1}, {"x\nx\ny\nx", 3}, {"y\n", 0}, {"x\n\nx\n", 2}} {
		if got := countLines(re, []byte(tt.in)); got != tt.want {
			t.Errorf("countLines(%q) = %d, want %d", tt.in, got, tt.want)
		}
	}
}

// An OID that overruns its AlgorithmIdentifier: the algorithm declares one content byte, so the next element is read
// from inside the OID. Here the OID's length byte (03) reads as a BIT STRING tag and 0x2b as its length, which lands
// exactly on the end of the input, so only the overrun check refuses it (the bash refuses too).
func TestDEROIDOverrunningItsAlgorithmIsRefused(t *testing.T) {
	h := "3030" + "3001" + "06" + "03" + "2b6570" + strings.Repeat("00", 41)
	if derPublic(h) {
		t.Error("an OID that overruns its AlgorithmIdentifier was accepted")
	}
	// the same bytes with a well-formed algorithm (length 5 covers the whole OID TLV) are not this case
	if !derPublic("300c" + "3005" + "06032b6570" + "030300dead") {
		t.Error("control: an Ed25519 SubjectPublicKeyInfo is public")
	}
}
