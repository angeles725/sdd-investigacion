package secretscan

import (
	"fmt"
	"strings"
)

// advCase is a corpus of one notes.md whose single line is the advisory probe.
func advCase(name, line string) scase { return one("adv-"+name, "notes.md", line+"\n") }

const advFold = "a keyword spelt with U+017F or U+212A is matched like PCRE caseless UTF mode does; the local grep -P did not, so the advisory warning was missed"

// withDivergence declares a stdout divergence on a case.
func withDivergence(c scase, reason string) scase {
	c.intended = append(c.intended, intended{"stdout", reason})
	return c
}

func advCases() []scase {
	cs := []scase{
		advCase("password-literal", `password = "S3cr3tHunter2Value"`),
		advCase("password-colon", `password: S3cr3tHunter2Value`),
		advCase("passwd", `passwd=Abc12345xyz`),
		advCase("secret", `secret = Zq81wertyuiop`),
		advCase("token", `token: "Tk99abcdefgh"`),
		advCase("api-key-dash", `api-key = Ak12345678901`),
		advCase("api-key-underscore", `API_KEY=Ak12345678901`),
		advCase("apikey", `apikey: Ak12345678901`),
		advCase("apikey-after-sep-no-key", `api_ = Ak12345678901`),
		advCase("uppercase", `PASSWORD=S3cr3tHunter2Value`),
		advCase("snake-aws-secret", `aws_secret_access_key = wJalrXUtnFEMI9K7value`),
		advCase("snake-embedded-upper", `aws_SECRET_access_key = wJalrXUtnFEMI9K7value`),
		advCase("snake-trailing-ident", `DB_PASSWORD_value = Hunter2Hunter2`),
		advCase("single-quote", `password = 'S3cr3tHunter2Value'`),
		advCase("no-spaces-around", `password="S3cr3tHunter2Value"`),
		advCase("tab-before-op", "password\t=\tS3cr3tHunter2Value"),
		advCase("multi-assignment", `password=Hunter2Hunter2;timeout=30`),
		advCase("first-keyword-no-value-second-has", `password = ; token = Tk99abcdefgh`),
		advCase("camel-substring-no", `saltedPassword = PBKDF2WithHmacSHA256(pw, salt, 100000)`),
		advCase("camel-prefix-no", `public static final Property certAliasAndPassword = newProperty(4);`),
		advCase("superstring-tokenizer-no", `tokenizer = Tk99abcdefgh`),
		advCase("superstring-secretariat-no", `secretariat: Sk99abcdefgh`),
		advCase("superstring-passwordless-no", `passwordless = Pk99abcdefgh`),
		advCase("digit-after-keyword", `token2 = Tk99abcdefgh`),
		advCase("placeholder-angle-no", `password = "<REDACTED>"`),
		advCase("placeholder-xxx-no", `api_key: xxxxxx12`),
		advCase("placeholder-xx-two-yes", `api_key: xx123456789`),
		advCase("placeholder-var-no", `token = $ENV_TOKEN12`),
		advCase("placeholder-brace-no", `token = {{ token12345 }}`),
		advCase("placeholder-star-no", `token = *Tk99abcdefgh`),
		advCase("placeholder-pct-no", `token = %Tk99abcdefgh`),
		advCase("word-redacted-no", `password = redacted1234`),
		advCase("word-changeme-no", `password = changeme1234`),
		advCase("word-example-no", `password = example1234`),
		advCase("word-placeholder-no", `password = placeholder1`),
		advCase("word-none-no", `password = none12345`),
		advCase("word-null-no", `password = null12345`),
		advCase("word-test-no", `password = test12345`),
		advCase("word-todo-no", `password = todo12345`),
		advCase("word-your-no", `password = your12345`),
		advCase("word-your-dash-no", `password = your-pw-1234`),
		advCase("word-example-capital-no", `password = EXAMPLE1234`),
		advCase("ellipsis-three-dots-no", `token: 'abc123...'`),
		advCase("ellipsis-char-no", "token: abc12345…"),
		advCase("bracket-no", `password = abc12345[0]`),
		advCase("paren-no", `password = abc12345(x)`),
		advCase("hash-char-no", `password = abc12345#x`),
		advCase("markdown-link-no", `- [30.8 password: ClearProgPwdPanel](#308-password-clearprogpwdpanel)`),
		advCase("seven-chars-no", `password = Abc1234`),
		advCase("eight-chars-yes", `password = Abc12345`),
		advCase("all-alpha-no", `password = AbcdefghijKLMN`),
		advCase("all-digit-no", `password = 123456789012`),
		advCase("hex-bare-token-warns", `token = e3b0c44298fc1c149afbf4c8996fb92427ae41e4`),
		advCase("hex-with-sha256-cited-no", `sha256 token = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`),
		advCase("hex-with-hash-word-no", `token = e3b0c44298fc1c149afbf4c8996fb924 (md5)`),
		advCase("hex-31-not-hash-warns", `token = e3b0c44298fc1c149afbf4c8996fb92 hash`+"x"),
		advCase("hex-65-not-hash-warns", `token = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b8550 hash`),
		advCase("value-stops-at-semicolon", `password = abc12345;rest`),
		advCase("value-stops-at-comma", `password = abc12345,rest`),
		advCase("empty-value-quote-no", `password = ""`),
		advCase("operator-missing-no", `password Abc12345xyz`),
		advCase("keyword-only-no", `password`),
		withDivergence(advCase("kelvin-sign-token", "toKen = Tk99abcdefgh"), advFold),
		withDivergence(advCase("long-s-secret", "ſecret = Zq81wertyuiop"), advFold),
		advCase("two-warn-lines-order", "password = Abc12345xyz\ntoken = Tk99abcdefgh"),
		advCase("keyword-in-code-fence", "```\ntoken: Tk99abcdefgh\n```"),
		advCase("keyword-in-path-colon-content", `token:Tk99abcdefgh`),
		advCase("underscore-before-keyword", `_password = Abc12345xyz`),
		advCase("digit-before-keyword-no", `1password = Abc12345xyz`),
		advCase("crlf-line", "password = Abc12345xyz\r"),
		{name: "adv-and-hc-together", build: func(w *world) {
			w.write("notes.md", fakeAWS+"\npassword = Abc12345xyz\n")
		}},
		{name: "adv-warn-cap-200", build: func(w *world) {
			var b strings.Builder
			for i := 0; i < 205; i++ {
				fmt.Fprintf(&b, "token = Tk99abcdef%03d\n", i)
			}
			w.write("notes.md", b.String())
		}, intended: []intended{{"stdout", "the legacy script judged only the first 200 keyword lines (cap before filters) and cut silently; the cap now counts printed warnings and announces the cut"}}},
		{name: "hc-leak-cap-50", build: func(w *world) {
			var b strings.Builder
			for i := 0; i < 55; i++ {
				b.WriteString(fakeAWS + "\n")
			}
			w.write("notes.md", b.String())
		}, intended: []intended{{"stdout", "the cut of a rule past 50 hits is announced instead of silent"}}},
	}
	return cs
}
