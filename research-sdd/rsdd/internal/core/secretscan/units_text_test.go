package secretscan

import (
	"strings"
	"testing"
)

func TestAdvisoryValueBoundaries(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		line string
		want string // "" = no value
	}{
		{`password = abc`, "abc"},
		{`password=abc`, "abc"},
		{`password:abc`, "abc"},
		{`  password  :  "abc"`, "abc"},
		{`password = 'abc'`, "abc"},
		{`password = abc;def`, "abc"},
		{`password = abc,def`, "abc"},
		{`password = abc def`, "abc"},
		{"password =\tabc", "abc"},
		{`password = ""`, ""},
		{`password = ;x`, ""},
		{`password`, ""},
		{`password `, ""},
		{`password =`, ""},
		{`password = `, ""},
		{`password abc`, ""},
		{`tokenizer = abc`, ""},
		{`token1 = abc`, "abc"},
		{`token_x = abc`, "abc"},
		{`token-x = abc`, ""},
		{`saltedPassword = abc`, ""},
		{`1token = abc`, ""},
		{`_token = abc`, "abc"},
		{`api_key = abc`, "abc"},
		{`api-key = abc`, "abc"},
		{`apikey = abc`, "abc"},
		{`api key = abc`, ""},
		{`api__key = abc`, ""},
		{`apikeys = abc`, ""},
		{`passwd = abc`, "abc"},
		{`secret = abc`, "abc"},
		{`PassWord = abc`, "abc"},
		{`password = ; token = def`, "def"},
		{`x password = abc`, "abc"},
		{"toKen = abc", "abc"},
		{"ſecret = abc", "abc"},
		{"tokenſ = abc", ""},
		{"token1ſ = abc", "abc"},
		{"password = aéb", "aéb"},
		{"épassword = abc", "abc"},
	} {
		got, ok := advisoryValue([]byte(tc.line))
		if tc.want == "" && ok || tc.want != "" && (!ok || string(got) != tc.want) {
			t.Errorf("advisoryValue(%q) = %q, %v; want %q", tc.line, got, ok, tc.want)
		}
	}
}

func TestAcceptValueRules(t *testing.T) {
	t.Parallel()
	hash := strings.Repeat("a1", 16) // 32 hex digits
	for _, tc := range []struct {
		name, val, content string
		want               bool
	}{
		{"real", "Abc12345", "", true},
		{"seven chars", "Abc1234", "", false},
		{"eight chars", "Abc12345", "", true},
		{"no digit", "Abcdefgh", "", false},
		{"no letter", "12345678", "", false},
		{"angle", "<Abc12345", "", false},
		{"dollar", "$Abc12345", "", false},
		{"brace", "{Abc12345", "", false},
		{"star", "*Abc12345", "", false},
		{"percent", "%Abc12345", "", false},
		{"three dots", "Abc1.2...", "", false},
		{"two dots", "Abc12..45", "", true},
		{"ellipsis", "Abc12345…", "", false},
		{"bracket open", "Abc[12345", "", false},
		{"bracket close", "Abc]12345", "", false},
		{"paren open", "Abc(12345", "", false},
		{"paren close", "Abc)12345", "", false},
		{"hash char", "Abc#12345", "", false},
		{"xxx", "xxx12345", "", false},
		{"xx", "xx123456", "", true},
		{"XXX caps", "XXX12345", "", false},
		{"redacted", "redacted1", "", false},
		{"changeme", "changeme1", "", false},
		{"example", "example1", "", false},
		{"placeholder", "placeholder1", "", false},
		{"none", "none1234", "", false},
		{"null", "null1234", "", false},
		{"test", "test1234", "", false},
		{"todo", "todo1234", "", false},
		{"your", "your1234", "", false},
		{"your sep", "your-pw12", "", false},
		{"prefix only at start", "myexample1", "", true},
		{"hex 31 cited as hash", hash[:31], "sha256", true},
		{"hex 32 cited as hash", hash, "sha256", false},
		{"hex 32 cited md5", hash, "md5", false},
		{"hex 32 cited hash word", hash, "the hash", false},
		{"hex 32 cited checksum", hash, "checksum", false},
		{"hex 32 cited digest", hash, "digest", false},
		{"hex 32 cited fingerprint", hash, "fingerprint", false},
		{"hex 32 uncited", hash, "token", true},
		{"hex 64 cited", strings.Repeat(hash, 2), "sha1", false},
		{"hex 65 cited", strings.Repeat(hash, 2) + "a", "sha1", true},
		{"hex 33 cited", hash + "a", "sha1", false},
	} {
		if got := acceptValue([]byte(tc.val), []byte(tc.content)); got != tc.want {
			t.Errorf("%s: acceptValue(%q, %q) = %v, want %v", tc.name, tc.val, tc.content, got, tc.want)
		}
	}
}

func TestScanHCLineNumbersAndNULStrip(t *testing.T) {
	t.Parallel()
	data := []byte("a\n\n" + fakeAWS + "\nb\n" + fakeAWS + "\n")
	hits := scanHC(data, true)
	if len(hits) != 2 || hits[0].Line != 3 || hits[1].Line != 5 || hits[0].Content != fakeAWS {
		t.Fatalf("hits = %+v", hits)
	}
	a := analyze([]byte("x\x00y "+fakeGH+"\n"), analyzeOpts{})
	if !a.NUL || len(a.HC) != 1 || a.HC[0].Line != 1 {
		t.Fatalf("a NUL-bearing buffer is scanned stripped: %+v", a)
	}
	b := analyze([]byte("p\x00a\x00s\x00s\x00w\x00o\x00r\x00d\x00 = Abc12345\n"), analyzeOpts{})
	if len(b.Adv) != 0 {
		t.Errorf("the advisory scan skips a NUL file unless asked: %+v", b.Adv)
	}
	c := analyze([]byte("x\x00y\npassword = Abc12345\n"), analyzeOpts{advisoryOnNUL: true})
	if len(c.Adv) != 1 || c.Adv[0].Line != 2 {
		t.Errorf("advisoryOnNUL scans it: %+v", c.Adv)
	}
	// stripped and raw hits at the same line and text are one hit
	d := analyze([]byte("x\x00 "+fakeAWS+"\n"), analyzeOpts{})
	if len(d.HC) != 1 {
		t.Errorf("a hit seen raw and stripped is reported once: %+v", d.HC)
	}
}

func TestScanAdvisoryLineNumbersAndDedup(t *testing.T) {
	t.Parallel()
	data := "x\ntoken = Abc12345 password = Def67890\n\nsecret: Ghi24680\n"
	hits := scanAdvisory([]byte(data), true)
	if len(hits) != 2 || hits[0].Line != 2 || hits[1].Line != 4 {
		t.Fatalf("one hit per line, with its number: %+v", hits)
	}
	if hits[0].Content != "token = Abc12345 password = Def67890" {
		t.Errorf("content = %q", hits[0].Content)
	}
	if got := scanAdvisory([]byte(data), false); got[0].Content != "" {
		t.Errorf("content kept without keepContent: %+v", got)
	}
}
