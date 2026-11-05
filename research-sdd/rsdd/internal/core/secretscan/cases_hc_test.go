package secretscan

import "strings"

// Fake secrets: obviously not real, but shaped to match each rule at its boundary.
var (
	fakePEM   = "-----BEGIN RSA PRIVATE KEY-----"
	fakeAWS   = "AKIAIOSFODNN7EXAMPLE"
	fakeGH    = "ghp_" + strings.Repeat("a1", 18) // 36 characters after the prefix
	fakeSlack = "xoxb-0123456789-abcdefghij"
	fakeGoog  = "AIza" + strings.Repeat("Ab0_-", 7) // 35 characters after the prefix
	fakeSK    = "sk-" + strings.Repeat("Zz9", 7)    // 21 characters after the prefix
	fakeJWT   = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123DEF456"
)

// one is a corpus of a single file.
func one(name, file, content string) scase {
	return scase{name: name, build: func(w *world) { w.write(file, content) }}
}

func hcCases() []scase {
	cs := []scase{
		one("hc-pem-rsa", "notes.md", "Leaked key:\n"+fakePEM+"\nMIIEowIBAAKCAQEA\n"),
		one("hc-pem-bare", "notes.md", "-----BEGIN PRIVATE KEY-----\n"),
		one("hc-pem-ec-spaces", "notes.md", "x -----BEGIN EC PRIVATE KEY----- y\n"),
		one("hc-pem-openssh", "notes.md", "-----BEGIN OPENSSH PRIVATE KEY-----\n"),
		one("hc-pem-lowercase-no", "notes.md", "-----begin rsa private key-----\n"),
		one("hc-pem-public-no", "notes.md", "-----BEGIN PUBLIC KEY-----\n"),
		one("hc-pem-four-dashes-no", "notes.md", "----BEGIN PRIVATE KEY-----\n"),
		one("hc-aws-akia", "notes.md", "aws_access_key_id = "+fakeAWS+"\n"),
		one("hc-aws-asia", "notes.md", "session ASIAIOSFODNN7EXAMPLE end\n"),
		one("hc-aws-15-no", "notes.md", "AKIAIOSFODNN7EXAMP\n"),
		one("hc-aws-lowercase-no", "notes.md", "akiaiosfodnn7example\n"),
		one("hc-aws-longer-still-matches", "notes.md", "AKIAIOSFODNN7EXAMPLEXTRA\n"),
		one("hc-gh-ghp", "notes.md", "token: "+fakeGH+"\n"),
		one("hc-gh-gho", "notes.md", strings.Replace(fakeGH, "ghp_", "gho_", 1)+"\n"),
		one("hc-gh-ghu", "notes.md", strings.Replace(fakeGH, "ghp_", "ghu_", 1)+"\n"),
		one("hc-gh-ghs", "notes.md", strings.Replace(fakeGH, "ghp_", "ghs_", 1)+"\n"),
		one("hc-gh-ghr", "notes.md", strings.Replace(fakeGH, "ghp_", "ghr_", 1)+"\n"),
		one("hc-gh-ghx-no", "notes.md", strings.Replace(fakeGH, "ghp_", "ghx_", 1)+"\n"),
		one("hc-gh-35-no", "notes.md", fakeGH[:len(fakeGH)-1]+"\n"),
		one("hc-slack-xoxb", "notes.md", fakeSlack+"\n"),
		one("hc-slack-xoxs", "notes.md", "xoxs-1234567890-abc\n"),
		one("hc-slack-9-no", "notes.md", "xoxb-123456789\n"),
		one("hc-slack-xoxz-no", "notes.md", "xoxz-0123456789-abcdefghij\n"),
		one("hc-google", "notes.md", "key="+fakeGoog+"\n"),
		one("hc-google-34-no", "notes.md", fakeGoog[:len(fakeGoog)-1]+"\n"),
		one("hc-sk", "notes.md", "OPENAI="+fakeSK+"\n"),
		one("hc-sk-19-no", "notes.md", "sk-"+strings.Repeat("a", 19)+"\n"),
		one("hc-sk-dash-no", "notes.md", "sk-"+strings.Repeat("a-", 15)+"\n"),
		one("hc-jwt", "notes.md", "auth: "+fakeJWT+"\n"),
		one("hc-jwt-short-part-no", "notes.md", "eyJhbGciOiJ.eyJzdWIiOiI.abc12\n"),
		one("hc-jwt-two-parts-no", "notes.md", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0\n"),
		one("hc-two-tokens-one-line", "notes.md", fakeAWS+" and "+fakeAWS+"\n"),
		one("hc-two-rules-one-line", "notes.md", fakeAWS+" "+fakeGH+"\n"),
		one("hc-three-lines-line-numbers", "notes.md", "a\n\n"+fakeAWS+"\nb\n"+fakeAWS+"\n"),
		one("hc-crlf", "notes.md", "x\r\n"+fakeAWS+"\r\n"),
		one("hc-no-trailing-newline", "notes.md", "x\n"+fakeAWS),
		one("hc-sha256-citation-no", "notes.md", "cited by hash: sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 (4096 bytes)\n"),
		one("hc-hex-dump-no", "notes.md", "register 0x87B961A9; dump: DE AD BE EF 01 02 03 04.\n"),
		one("hc-clean", "notes.md", "Extends BComponent. The password is stored in the keyring (structure only).\n"),
		one("hc-empty-file", "notes.md", ""),
		one("hc-latin1-byte-same-line", "notes.md", fakeGH+" \xf1\n"),
		one("hc-long-line", "notes.md", strings.Repeat("x", 200000)+" "+fakeAWS+"\n"),
		{name: "hc-all-seven-rules", build: func(w *world) {
			w.write("notes.md", strings.Join([]string{fakePEM, fakeAWS, fakeGH, fakeSlack, fakeGoog, fakeSK, fakeJWT}, "\n")+"\n")
		}},
	}
	return cs
}
