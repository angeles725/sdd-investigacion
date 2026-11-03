//go:build linux

package adapter

import (
	"bytes"
	"encoding/json"
	"math/big"
	"reflect"
	"strings"
	"testing"
)

type vCase struct {
	V any `json:"v"`
}

// goValue turns a JSON-able test value into the value model of the port.
func goValue(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var g any
	if err := dec.Decode(&g); err != nil {
		t.Fatal(err)
	}
	return g
}

func wantErr(t *testing.T, label string, py pyOut, err error) bool {
	t.Helper()
	if py.OK {
		if err != nil {
			t.Errorf("%s: python ok, go %v", label, err)
		}
		return err == nil
	}
	pe, ok := err.(*PyError)
	if !ok || pe.Class != py.Class || pe.Msg != py.Msg {
		t.Errorf("%s: python %s(%q), go %v", label, py.Class, py.Msg, err)
	}
	return false
}

func pathStrings() []string {
	s := []string{"a", "a/b", "a/./b", "a//b", "a/", "/a", "../a", "a/../b", "..", ".", "", " ", "\t", "a b", "%2e%2e/x", "%252e%252e%252Fx", "..%2Fx", "%2Fabs", "C:/d", "file:payload",
		"a:b", "a\\b", "a%5Cb", "a%5cb", "ａ／ｂ", "．．／ｘ", "ａ＼ｂ", "%EF%BC%8E%EF%BC%8E/x", "％２ｅ％２ｅ/x", "é", "e\u0301", "\ufb01le", "a\u0000b", "~", "~/x", "a%00b", "%", "%zz", "%e2%82", "%e2%82%ac",
		"ab\n", "a\nb", " a", "a ", "․․/x", "\u2025/x", "a\u2044b", "\u00a0", "a/\u200b", strings.Repeat("x", 5000), "http://x", "1abc:", "a+b.c-d:", "A:", "//x", "///x", "./a", "a/.", "a/..", "a%2fb", "a%2Fb/..", "%2e", "%2E%2e",
		"a%", "a%2", "%%2e%2e", "%252525252525252e", "%25252525252525252e", "%2525252525252525252e", "%25252525252525252525252e", "a\U0001f600b", "%F0%9F%98%80", "%ff", "%c0%af", "ａ", "x\u0301\u0323", "x\u0323\u0301", "\uff05\uff12\uff45",
		"\u1e9b\u0323", "a\u0338", "ℌ", "²", "%C2%B2", "%C2%AA", "①", "…", "\u2024", "..\u2024", "a/\u2024/b", "\uff0f", "a\uff0fb", "\ufe52", "\ufe68", "\u2215", "\u29f8", "% 2e", "%2 e", "x%20y", "%20", "%09", "%0a", "a%0ab", "a\rb", "a\x7fb", "a\x1fb", "nul\x00"}
	for d := 5; d <= 10; d++ { // around the 8-pass normalisation limit: ".." escaped d levels deep
		nested := "%" + strings.Repeat("25", d-1) + "2e"
		s = append(s, nested+nested, "a/"+nested+nested+"/b")
	}
	return s
}

func TestParityRelativePath(t *testing.T) {
	var cases []vCase
	for _, s := range pathStrings() {
		cases = append(cases, vCase{s})
	}
	cases = append(cases, vCase{nil}, vCase{5}, vCase{[]any{}}, vCase{true}, vCase{map[string]any{}}, vCase{1.5})
	rs := runDriver[pyOut](t, "relative", cases)
	for i, c := range cases {
		got, err := relativePath(goValue(t, c.V), "ctx")
		label := jsonString(c)
		if len(label) > 80 {
			label = label[:80]
		}
		if wantErr(t, "relative "+label, rs[i], err) {
			var want string
			_ = json.Unmarshal(rs[i].Value, &want)
			if got != want {
				t.Errorf("relative %s: go %q python %q", label, got, want)
			}
		}
	}
}

func TestParityAnalysisArtifactPath(t *testing.T) {
	extra := []string{"/abs/x", "//x", "/a/../b", "/a/./b", "/a//b", "/a/", "/", "/a\\b", "x/y", "/.", "/..", "/a/..", "/a b", "/é", "/a%2e%2e/b", "/a/%2e%2e", "///x", "/a/\u0000", "/tmp/x:1"}
	var cases []vCase
	for _, s := range append(extra, pathStrings()...) {
		cases = append(cases, vCase{s})
	}
	cases = append(cases, vCase{nil}, vCase{7})
	rs := runDriver[pyOut](t, "artifact_path", cases)
	for i, c := range cases {
		got, err := analysisArtifactPath(goValue(t, c.V), "ctx")
		label := jsonString(c)
		if len(label) > 80 {
			label = label[:80]
		}
		if wantErr(t, "artifact_path "+label, rs[i], err) {
			var want string
			_ = json.Unmarshal(rs[i].Value, &want)
			if got != want {
				t.Errorf("artifact_path %s: go %q python %q", label, got, want)
			}
		}
	}
}

func TestParitySafeArgv(t *testing.T) {
	items := []string{"tool", "--inspect", "sample.bin", "--token", "--tokenize", "--client-secret", "--access-token", "--refresh-token", "--password-file", "--password", "--passwd", "--passwor", "--api-key", "--apikey", "--api_key",
		"--private-key", "--privatekey", "--private_key", "--authorization", "--cookie", "--cookies", "--auth", "--secret", "--secrets", "-token", "-x-token-y", "--my_secret_thing", "--cookie-jar", "--no-password", "--password=hunter2", "--token=abc", "--tokenize=abc", "--out=token", "--credential", "--credentials",
		"token", "password", "--token\n", "--token\n\n", "--secret\r", "--x\n--token", "--Token", "--PASSWORD", "--ＴＯＫＥＮ", "--tokén", "--ſecret", "--toKen", "--paſsword", "--KEY", "--key", "-k", "-", "--", "",
		"Bearer abc", "bearer\tabc", "Bearer\u00a0abc", "bearer\u2003abc", "bearer\x0babc", "bearer\x1cabc", "Bearer", "bearer ", "xbearer abc", "ghp_abcdefghijklmnopqrstuvwxyz", "ghp_abc", "GHP_ABCDEFGHIJKLMNOPQRSTUVWXYZ", "xoxb-1234567890", "xoxb-123", "eyJabcdefghij.", "eyJabc.", "AKIAABCDEFGHIJKLMNOP", "AKIAabcdefghijklmnop", "AKIAABCDEFGHIJKLMNO",
		"-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----", "-----BEGIN  X PRIVATE KEY-----", "-----BEGIN-----PRIVATE KEY-----", "-----BEGIN\nX\nPRIVATE KEY-----",
		"secret:", "secret=1", "token = x", "Password:x", "api_key=1", "api-key: x", "apikey=", "authorization: x", "cookie=1", "passwrd=1", "passwd=1", "password", "mytoken:", "tokens", "x=token", "authorization", "cookie", "secrets=1"}
	var cases []vCase
	for _, it := range items {
		cases = append(cases, vCase{[]any{"tool", it}})
		cases = append(cases, vCase{[]any{it}})
	}
	cases = append(cases, vCase{[]any{}}, vCase{"tool"}, vCase{nil}, vCase{[]any{"a", 1}}, vCase{[]any{"a", nil}}, vCase{[]any{[]any{}}}, vCase{map[string]any{}},
		vCase{[]any{"tool", "ok", "--token", "x", "bad bearer y"}}, vCase{[]any{"tool", "--a", "ghp_abcdefghijklmnopqrstuvwxyz1234567890"}})
	rs := runDriver[pyOut](t, "safe_argv", cases)
	for i, c := range cases {
		got, err := safeArgv(goValue(t, c.V))
		label := jsonString(c)
		if wantErr(t, "safe_argv "+label, rs[i], err) {
			var want []string
			_ = json.Unmarshal(rs[i].Value, &want)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("safe_argv %s: go %q python %q", label, got, want)
			}
		}
	}
}

func TestParitySanitizeEnvironment(t *testing.T) {
	env := func(kv ...string) map[string]any {
		m := map[string]any{}
		for i := 0; i < len(kv); i += 2 {
			m[kv[i]] = kv[i+1]
		}
		return m
	}
	cases := []vCase{
		{env()}, {env("LANG", "C.UTF-8", "TZ", "UTC")}, {env("PASSWORD", "x")}, {env("LANG", "Bearer abc123")}, {env("HOME", "/h", "PATH", "/a:/b", "SHELL", "/bin/sh")},
		{env("FOO", "x")}, {env("lang", "x")}, {env("LANG", "ghp_abcdefghijklmnopqrstuvwxyz1234567890")}, {env("LANG", "xoxb-1234567890-secret")}, {env("LANG", "token=1")}, {env("LANG", "Authorization: x")},
		{env("LANG", "eyJabcdefghij.k")}, {env("LANG", "AKIAABCDEFGHIJKLMNOP")}, {env("LANG", "-----BEGIN RSA PRIVATE KEY-----")}, {env("LANG", "")}, {env("USER", "root\nsecret: x")},
		{env("RSDD_PROBE_TIMEOUT", "30", "RSDD_DECOMPILE_MAX_HEAP", "2g", "RESEARCH_SDD_JAVA_HOME", "/j", "RESEARCH_SDD_TOOL_HOME", "/t", "HOMEBREW_PREFIX", "/b", "RSDD_BREW_PREFIX", "/b", "XDG_CACHE_HOME", "/c", "XDG_CONFIG_HOME", "/c", "XDG_DATA_HOME", "/d", "TMPDIR", "/t", "LC_ALL", "C", "JAVA_HOME", "/j")},
		{map[string]any{"LANG": 5}}, {map[string]any{"LANG": nil}}, {map[string]any{"LANG": []any{}}}, {map[string]any{"LANG": true}}, {[]any{}}, {nil}, {"LANG"}, {5},
		{map[string]any{"LANG": "x", "AUTH": "y"}}, {map[string]any{"AUTH": "y", "LANG": "x"}}, {env("LANGUAGE", "x")}, {env("TOKEN", "x")}, {env("HOME", "Bearer x", "TZ", "y")},
	}
	rs := runDriver[pyOut](t, "sanitize_env", cases)
	for i, c := range cases {
		got, err := sanitizeEnvironment(goValue(t, c.V))
		label := jsonString(c)
		if wantErr(t, "sanitize_env "+label, rs[i], err) {
			var want map[string]string
			_ = json.Unmarshal(rs[i].Value, &want)
			if len(got) == 0 && len(want) == 0 {
				continue
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("sanitize_env %s: go %v python %v", label, got, want)
			}
		}
	}
}

func TestParityEvidenceLocation(t *testing.T) {
	big1 := "99999999999999999999999999999"
	vals := []any{"a:1", "a:1-2", "a:0", "a:01", "a:1-0", "a:1-01", "a:b", ":1", "a:1:2", "a/b:" + big1 + "-" + big1 + "9", "../a:1", "a:1-", "a:-1", "a b:1", "a:1\n", "a:1-2\n", "a/b/c.txt:12", "evidence/stdout.txt:3-2",
		"a:١", "a:1٢", "%2e%2e/x:1", "a\n:1", "x:99999999999999999999999999999999999999999999999999", "é:1", "a:1-1", "a/./b:1", "/abs:1", "a\\b:1", "file:x:1", "", nil, 5, []any{"a:1"}}
	var cases []vCase
	for _, v := range vals {
		cases = append(cases, vCase{v})
	}
	rs := runDriver[pyOut](t, "evidence_location", cases)
	for i, c := range cases {
		path, start, end, err := evidenceLocation(goValue(t, c.V))
		label := jsonString(c)
		if len(label) > 80 {
			label = label[:80]
		}
		if wantErr(t, "evidence_location "+label, rs[i], err) {
			var want []string
			_ = json.Unmarshal(rs[i].Value, &want)
			got := []string{path, start.String(), end.String()}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("evidence_location %s: go %v python %v", label, got, want)
			}
		}
	}
	_ = big.NewInt
}
