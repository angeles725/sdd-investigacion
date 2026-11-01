package ensureremote

import (
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"
)

// The byte-literal fixtures of the retired bash suite (put_pub), kept as the same bytes so a classification
// verdict is comparable across the port. Every one is a tiny hand-built DER/PEM/text blob.

const (
	spkiHex = "3015300d06092a864886f70d0101010500030400deadbe"
	certHex = "30133008a003020102020101300306012a030200ab"
	pk8Hex  = "30820a0102010030820a0d06092a864886f70d0101010400"
)

func unhex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad fixture hex %q: %v", s, err)
	}
	return b
}

// pemOf is a PEM block whose payload is the DER spelled by hexDER, base64 wrapped at 64 columns as base64(1) does.
func pemOf(t testing.TB, label, hexDER string) string {
	t.Helper()
	enc := base64.StdEncoding.EncodeToString(unhex(t, hexDER))
	var sb strings.Builder
	sb.WriteString("-----BEGIN " + label + "-----\n")
	for len(enc) > 64 {
		sb.WriteString(enc[:64] + "\n")
		enc = enc[64:]
	}
	if enc != "" {
		sb.WriteString(enc + "\n")
	}
	sb.WriteString("-----END " + label + "-----\n")
	return sb.String()
}

// fixture returns the bytes of one named kind (the kinds of put_pub in the retired suite).
func fixture(t testing.TB, kind string) []byte {
	t.Helper()
	switch kind {
	case "spki":
		return unhex(t, spkiHex)
	case "pkcs8":
		return []byte("\x30\x82\x04\xbd\x02\x01\x00\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01")
	case "pkcs8s":
		return []byte("\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20")
	case "sec1":
		return []byte("\x30\x77\x02\x01\x01\x04\x20\x11\x22\x33")
	case "pkcs1":
		return []byte("\x30\x82\x04\xa4\x02\x01\x00\x02\x82\x01\x01\x00")
	case "pempub":
		return []byte(pemOf(t, "PUBLIC KEY", spkiHex))
	case "pemrsapub":
		return []byte(pemOf(t, "RSA PUBLIC KEY", "3009020301000102020100"))
	case "pemcrl":
		return []byte(pemOf(t, "X509 CRL", "300730003000030100"))
	case "relabel":
		return []byte(pemOf(t, "CERTIFICATE", pk8Hex))
	case "certplus":
		return []byte(pemOf(t, "CERTIFICATE", certHex) + base64.StdEncoding.EncodeToString(unhex(t, pk8Hex)) + "\n")
	case "certhex":
		return []byte(pemOf(t, "CERTIFICATE", certHex) + pk8Hex + "\n")
	case "lfs":
		return []byte("version https://git-lfs.github.com/spec/v1\noid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393\nsize 12345\n")
	case "lichex":
		return []byte("MIT License\nkey = 00112233445566778899aabbccddeeff\n")
	case "licxxd":
		return []byte("MIT License\n" + pk8Hex + "\n" + pk8Hex + "\n")
	case "licb64":
		enc := base64.StdEncoding.EncodeToString(unhex(t, pk8Hex+pk8Hex+pk8Hex))
		var sb strings.Builder
		sb.WriteString("MIT License\n")
		for len(enc) > 60 {
			sb.WriteString(enc[:60] + "\n")
			enc = enc[60:]
		}
		sb.WriteString(enc + "\n")
		return []byte(sb.String())
	case "lichexsp":
		return []byte("MIT License\n00 11 22 33 44 55 66 77 88 99 aa bb\n")
	case "licrun":
		return []byte("MIT License\ntoken abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV end\n")
	case "licnormal":
		return []byte("Apache License\nVersion 2.0, January 2004\nhttp://www.apache.org/licenses/LICENSE-2.0\n\nCopyright (c) 2026 Example Corp. Licensed under the Apache License; you may not use this file except in compliance with the License. Unless required by applicable law or agreed to in writing, software is distributed on an \"AS IS\" BASIS.\nContact: legal@example.com or +1 555 0100 (2024-2026).\n")
	case "pempriv":
		return []byte("-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----\n")
	case "ed25519":
		return unhex(t, "302a300506032b6570032100aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	case "cert":
		return unhex(t, certHex)
	case "certv1":
		return unhex(t, "30133008a003020100020101300306012a030200ab")
	case "encpk8":
		return unhex(t, "301b300f06092a864886f70d01050d300205000408aabbccddeeff0011")
	case "p12":
		return unhex(t, "3082010a020103308201023082006d06092a864886f70d010701a0")
	case "jks":
		return unhex(t, "feedfeed000000020000000100000001")
	case "gpgsec":
		return unhex(t, "95010d0400a1b2c3d4e5f60001020304")
	case "badoid":
		return unhex(t, "3015300d06092a864886f70d0101050500030400deadbe")
	case "nulonly":
		return unhex(t, "4d4954204c6963656e736500746578740a")
	case "ctrl":
		return []byte("MIT License\x01 text\n")
	case "secrettxt":
		return []byte("MIT License\nthis file carries a SECRET value\n")
	case "ppk":
		return []byte("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: x\nPublic-Lines: 1\nAAAAC3Nza\nPrivate-Lines: 1\nAAAAIB\nPrivate-MAC: ab\n")
	case "age":
		return []byte("# created: 2026\nAGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ\n")
	case "ssh2":
		return []byte("---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nProc-Type: 4,ENCRYPTED\nAAAA\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n")
	case "rawb64":
		return []byte("MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgabcdefghijklmnop\nqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrs\n")
	case "licence":
		return []byte("MIT License\n\nCopyright (c) 2026 Example\n\nPermission is hereby granted, free of charge, to any person obtaining a copy.\n")
	case "pemcert":
		return []byte(pemOf(t, "CERTIFICATE", certHex))
	case "pemmixed":
		return []byte(pemOf(t, "CERTIFICATE", certHex) + "-----BEGIN EC PARAMETERS-----\nBggq\n-----END EC PARAMETERS-----\n")
	case "pemenc":
		return []byte("-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIFH\n-----END ENCRYPTED PRIVATE KEY-----\n")
	}
	t.Fatalf("unknown fixture kind %q", kind)
	return nil
}
