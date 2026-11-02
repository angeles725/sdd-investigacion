package ensureremote

import (
	"bytes"
	"strings"
	"testing"
)

// Guard-to-test table (the bash suite's mutants, now Go tests; each row is a rule whose removal must turn a row
// below red, proven with gremlins and by hand):
//
//	explicit private markers (PEM/AGE/PuTTY/SSH2)        TestClassifyKinds private rows
//	DER PKCS#8/PKCS#1/SEC1 version-0/1 INTEGER          TestClassifyKinds pkcs8, pkcs8s, sec1, pkcs1 (and TestDERPrivateLengthForms)
//	SPKI OID allow-list                                  TestClassifyKinds badoid
//	PEM exclusivity (foreign armour)                     TestClassifyKinds pemmixed, TestPEMArmourCounts
//	PEM payload must decode to DER of its label          TestClassifyKinds relabel, TestPEMBlockShapes
//	stray data outside PEM blocks                        TestClassifyKinds certplus, certhex
//	NUL byte / control byte => binary                    TestClassifyKinds nulonly, ctrl
//	text markers PRIVATE/SECRET/...                      TestClassifyKinds secrettxt
//	hex run / base64 run / hexdump                       TestClassifyKinds lichex, licrun, licb64, licxxd, lichexsp
//	Git LFS pointer                                      TestClassifyKinds lfs

var classNames = map[class]string{classPublic: "public", classPrivate: "private", classNotPublic: "notpublic", classLFS: "lfs"}

func TestClassifyKinds(t *testing.T) {
	want := map[string]class{
		// positively public (case 37)
		"pemcert": classPublic, "pempub": classPublic, "cert": classPublic, "certv1": classPublic, "spki": classPublic,
		"ed25519": classPublic, "licence": classPublic, "pemrsapub": classPublic, "pemcrl": classPublic, "licnormal": classPublic,
		// explicit private material (case 32 and the private rows of 38)
		"pempriv": classPrivate, "pemenc": classPrivate, "pkcs8": classPrivate, "pkcs8s": classPrivate, "sec1": classPrivate,
		"pkcs1": classPrivate, "ppk": classPrivate, "age": classPrivate, "ssh2": classPrivate,
		// everything else is not positively public (case 38)
		"encpk8": classNotPublic, "p12": classNotPublic, "jks": classNotPublic, "gpgsec": classNotPublic, "rawb64": classNotPublic,
		"pemmixed": classNotPublic, "badoid": classNotPublic, "nulonly": classNotPublic, "ctrl": classNotPublic,
		"secrettxt": classNotPublic, "relabel": classNotPublic, "certplus": classNotPublic, "certhex": classNotPublic,
		"lichex": classNotPublic, "licxxd": classNotPublic, "licb64": classNotPublic, "lichexsp": classNotPublic,
		"licrun": classNotPublic,
		"lfs":    classLFS,
	}
	for kind, w := range want {
		t.Run(kind, func(t *testing.T) {
			if got := classify(fixture(t, kind)); got != w {
				t.Errorf("classify(%s) = %s, want %s", kind, classNames[got], classNames[w])
			}
		})
	}
}

func TestClassifyEdges(t *testing.T) {
	big := append([]byte("MIT License\n"), bytes.Repeat([]byte("a b\n"), 17000)...) // > 65536 bytes of plain text
	for _, tt := range []struct {
		name string
		in   []byte
		want class
	}{
		{"empty", nil, classNotPublic},
		{"only-blanks", []byte(" \n\t\n"), classNotPublic}, // no alphanumeric character
		{"one-byte-30-is-text-0", []byte{0x30}, classPublic},
		{"text-at-limit-ok", append([]byte("Licence\n"), bytes.Repeat([]byte("x"), 30)...), classPublic},
		{"text-over-65536", big, classNotPublic},
		{"crlf-licence", []byte("MIT License\r\nCopyright\r\n"), classPublic},
		{"tab-and-cr-allowed", []byte("MIT\tLicense\r\n"), classPublic},
		{"del-byte", []byte("MIT License\x7f\n"), classNotPublic},
		{"vt-byte", []byte("MIT License\x0b\n"), classNotPublic},
		{"ff-byte", []byte("MIT License\x0c\n"), classNotPublic},
		{"so-byte", []byte("MIT\x0e\n"), classNotPublic},
		{"us-byte", []byte("MIT\x1f\n"), classNotPublic},
		{"x1f-boundary-space-ok", []byte("MIT \n"), classPublic},
		{"hex-31-run-ok", []byte("id " + strings.Repeat("a", 31) + "\n"), classPublic},
		{"hex-32-run-refused", []byte("id " + strings.Repeat("a", 32) + "\n"), classNotPublic},
		{"b64-39-run-ok", []byte("id " + strings.Repeat("g", 39) + "\n"), classPublic},
		{"b64-40-run-refused", []byte("id " + strings.Repeat("g", 40) + "\n"), classNotPublic},
		{"hexdump-15-ok", []byte("Licence\n" + strings.Repeat("ab ", 7) + "a\n"), classPublic},
		{"hexdump-16-refused", []byte("Licence\n" + strings.Repeat("ab ", 8) + "\n"), classNotPublic},
		{"hexdump-colons-16-refused", []byte("Licence\n" + strings.Repeat("ab:", 8) + "\n"), classNotPublic},
		{"hexdump-16-with-nonhex-ok", []byte("Licence\n" + strings.Repeat("ab ", 7) + "az\n"), classPublic},
		{"lfs-not-line-start", []byte("x version https://git-lfs.github.com/spec/v1\n"), classPublic},
		{"lfs-second-line", []byte("hello\nversion https://git-lfs.github.com/spec/v1\n"), classLFS},
		{"age-marker", []byte("AGE-SECRET-KEY-1abc"), classPrivate},
		{"private-key-block-marker", []byte("-----BEGIN PGP PRIVATE KEY BLOCK-----\n"), classPrivate},
		{"private-key-no-dashes", []byte("PRIVATE KEY\n"), classNotPublic}, // marker needs the trailing dashes; the text rule still refuses
		{"words-private", []byte("a PRIVATE note\n"), classNotPublic},
		{"words-secret", []byte("a SECRET note\n"), classNotPublic},
		{"dash-begin", []byte("---- BEGIN x\n"), classNotPublic},
		{"lowercase-private-ok", []byte("a private note\n"), classPublic},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := classify(tt.in); got != tt.want {
				t.Errorf("classify = %s, want %s", classNames[got], classNames[tt.want])
			}
		})
	}
}

// Both header forms of a DER private key: the version INTEGER is read after a short or 1/2/3/4-byte long length.
func TestDERPrivateLengthForms(t *testing.T) {
	for _, tt := range []struct {
		name string
		hex  string
		want class
	}{
		{"short", "3003020100", classPrivate},
		{"short-v1", "3003020101", classPrivate},
		{"long81", "308103020100", classPrivate},
		{"long82", "30820003020100", classPrivate},
		{"long83", "3083000003020100", classPrivate},
		{"long84", "308400000003020100", classPrivate},
		{"v2-not-private", "3003020102", classNotPublic},
		{"long81-v2", "308103020102", classNotPublic},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := classify(unhex(t, tt.hex)); got != tt.want {
				t.Errorf("classify = %s, want %s", classNames[got], classNames[tt.want])
			}
		})
	}
}

// The DER parser: certificate shapes, SPKI OIDs, length forms and every truncation.
func TestDERPublicShapes(t *testing.T) {
	for _, tt := range []struct {
		name string
		hex  string
		want bool
	}{
		{"cert-v3", certHex, true},
		{"spki-rsa", spkiHex, true},
		{"empty", "", false},
		{"not-sequence", "31" + certHex[2:], false},
		{"trailing-garbage", certHex + "00", false},
		{"short-by-one", certHex[:len(certHex)-2], false},
		{"tbs-not-sequence", "3013" + "31" + certHex[6:], false},
		{"version-3-bad", strings.Replace(certHex, "a003020102", "a003020103", 1), false},
		{"version-1-ok", strings.Replace(certHex, "a003020102", "a003020100", 1), true},
		{"sig-not-sequence", strings.Replace(certHex, "300306012a", "310306012a", 1), false},
		{"sigvalue-not-bitstring", strings.Replace(certHex, "030200ab", "040200ab", 1), false},
		{"ed25519", "302a300506032b6570032100" + strings.Repeat("aa", 32), true},
		{"ed448", "302a300506032b6571032100" + strings.Repeat("aa", 32), true},
		{"x25519", "302a300506032b656e032100" + strings.Repeat("aa", 32), true},
		{"x448", "302a300506032b656f032100" + strings.Repeat("aa", 32), true},
		{"ec-pubkey-oid", "3013300b06072a8648ce3d0201" + "0500" + "030400deadbe", true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got := derPublic(tt.hex)
			if got != tt.want {
				t.Errorf("derPublic(%s) = %v, want %v", tt.hex, got, tt.want)
			}
		})
	}
}

// PEM: each label's DER shape, and the armour counting rules.
func TestPEMBlockShapes(t *testing.T) {
	cert, spki := certHex, spkiHex
	for _, tt := range []struct {
		name  string
		label string
		hex   string
		want  class
	}{
		{"cert", "CERTIFICATE", cert, classPublic},
		{"public-key", "PUBLIC KEY", spki, classPublic},
		{"rsa-public", "RSA PUBLIC KEY", "3009020301000102020100", classPublic},
		{"rsa-public-extra", "RSA PUBLIC KEY", "300b02030100010202010000", classNotPublic},
		{"rsa-public-bad-tag", "RSA PUBLIC KEY", "3009020301000104020100", classNotPublic},
		{"rsa-public-one-int", "RSA PUBLIC KEY", "3005020301000" + "1", classNotPublic},
		{"crl", "X509 CRL", "300730003000030100", classPublic},
		{"crl-bad-order", "X509 CRL", "300730003000040100", classNotPublic},
		{"crl-not-seq", "X509 CRL", "310730003000030100", classNotPublic},
		{"trusted-bare-cert", "TRUSTED CERTIFICATE", cert, classPublic},
		{"trusted-with-trust", "TRUSTED CERTIFICATE", cert + "3003020100", classPublic},
		{"trusted-bad-trust", "TRUSTED CERTIFICATE", cert + "3103020100", classNotPublic},
		{"trusted-trailing", "TRUSTED CERTIFICATE", cert + "30030201000000", classNotPublic},
		{"trusted-empty", "TRUSTED CERTIFICATE", "", classNotPublic},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if tt.hex == "" {
				// an empty payload decodes to nothing: refused before the label is consulted
				if got := classify([]byte("-----BEGIN " + tt.label + "-----\n-----END " + tt.label + "-----\n")); got != classNotPublic {
					t.Errorf("empty payload = %s", classNames[got])
				}
				return
			}
			if got := classify([]byte(pemOf(t, tt.label, tt.hex))); got != tt.want {
				t.Errorf("classify = %s, want %s", classNames[got], classNames[tt.want])
			}
		})
	}
}

func TestPEMArmourCounts(t *testing.T) {
	good := pemOf(t, "CERTIFICATE", certHex)
	for _, tt := range []struct {
		name string
		in   string
		want class
	}{
		{"one-block", good, classPublic},
		{"two-blocks", good + good, classPublic},
		{"crlf-lines", strings.ReplaceAll(good, "\n", "\r\n"), classPublic},
		{"unterminated", strings.TrimSuffix(good, "-----END CERTIFICATE-----\n"), classNotPublic},
		{"no-begin-line-ending", strings.Replace(good, "-----BEGIN CERTIFICATE-----", "-----BEGIN CERTIFICATE----- ", 1), classNotPublic},
		{"two-markers-one-line", "-----BEGIN CERTIFICATE----- -----BEGIN CERTIFICATE-----\n" + good, classNotPublic},
		{"end-marker-extra", good + "-----END CERTIFICATE-----\n", classNotPublic},
		{"text-before-block", "Subject: x\n" + good, classPublic},
		{"b64-run-before-block", strings.Repeat("A", 16) + "\n" + good, classNotPublic},
		{"b64-run-15-before-block", strings.Repeat("A", 15) + "\n" + good, classPublic},
		{"non-b64-inside", strings.Replace(good, "\n", "\n!", 1), classNotPublic},
		{"nested-begin", "-----BEGIN CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n", classNotPublic},
		{"mismatched-end", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END PUBLIC KEY-----\n", classNotPublic},
		{"bad-padding", strings.Replace(pemOf(t, "PUBLIC KEY", spkiHex), "=\n", "\n", 1), classNotPublic},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := classify([]byte(tt.in)); got != tt.want {
				t.Errorf("classify = %s, want %s", classNames[got], classNames[tt.want])
			}
		})
	}
}
