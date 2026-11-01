package formats

import (
	"strings"
	"testing"
	"time"
)

func TestZipNFCKnownForms(t *testing.T) {
	for name, c := range map[string]struct{ in, want string }{
		"compose":          {"e\u0301", "\u00e9"},
		"already composed": {"\u00e9", "\u00e9"},
		"ascii":            {"plain/name.txt", "plain/name.txt"},
		"reorder":          {"a\u0323\u0302", "\u1ead"}, // dot below (220) sorts before circumflex (230), then composes
		"reorder only":     {"a\u0302\u0323", "\u1ead"},
		"hangul LV":        {"\u1100\u1161", "\uac00"},
		"hangul LVT":       {"\u1100\u1161\u11a8", "\uac01"},
		"hangul decomp":    {"\uac01", "\uac01"},
		"singleton":        {"\u212b", "\u00c5"}, // ANGSTROM SIGN
		"excluded":         {"\u0958", "\u0915\u093c"},
		"blocked":          {"a\u0323\u0323\u0302", "\u1ead\u0323"},
		"empty":            {"", ""},
		"supplementary":    {"\U0001d15e", "\U0001d157\U0001d165"},
	} {
		if got := zipNFC(c.in); got != c.want {
			t.Errorf("%s: NFC(%+q) = %+q, want %+q", name, c.in, got, c.want)
		}
	}
	if !strings.HasPrefix(zipUnicodeVersion, "1") {
		t.Errorf("unexpected table version %q", zipUnicodeVersion)
	}
}

func TestZipDecodeKnownForms(t *testing.T) {
	for name, c := range map[string]struct {
		in   string
		want string
	}{
		"valid":                 {"caf\xc3\xa9", "caf\u00e9"},
		"truncated two":         {"a\xe2\x82", "a\ufffd"},
		"truncated three":       {"\xf0\x9f\x98", "\ufffd"},
		"stray continuation":    {"\x80\x80", "\ufffd\ufffd"},
		"invalid lead":          {"\xff\xfe", "\ufffd\ufffd"},
		"overlong":              {"\xc0\xaf", "\ufffd\ufffd"},
		"surrogate":             {"\xed\xa0\x80", "\ufffd\ufffd\ufffd"},
		"too large":             {"\xf4\x90\x80\x80", "\ufffd\ufffd\ufffd\ufffd"},
		"truncated then ascii":  {"\xe2a", "\ufffda"},
		"three byte then break": {"\xe0\xa0a", "\ufffda"},
	} {
		if got := zipDecodeUTF8Replace([]byte(c.in)); got != c.want {
			t.Errorf("%s: %+q -> %+q, want %+q", name, c.in, got, c.want)
		}
	}
	if got := zipDecodeCP437([]byte{'A', 0x80, 0xe9, 0xff}); got != "A\u00c7\u0398\u00a0" {
		t.Errorf("cp437 = %+q", got)
	}
}

func TestZipISONow(t *testing.T) {
	base := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, c := range []struct {
		t    time.Time
		want string
	}{
		{base, "2026-01-02T03:04:05Z"},
		{base.Add(678901 * time.Microsecond), "2026-01-02T03:04:05.678901Z"},
		{base.Add(5 * time.Microsecond), "2026-01-02T03:04:05.000005Z"},
		{base.Add(900 * time.Nanosecond), "2026-01-02T03:04:05Z"},
		{base.In(time.FixedZone("x", 3600)), "2026-01-02T03:04:05Z"},
	} {
		if got := zipISONow(c.t); got != c.want {
			t.Errorf("zipISONow(%v) = %q, want %q", c.t, got, c.want)
		}
	}
}

func TestZipPrivateFSCheck(t *testing.T) {
	const mi = `22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
23 22 0:20 / /mnt rw - nfs server:/x rw
24 23 0:21 / /mnt/fast rw - tmpfs tmpfs rw
25 22 0:22 / /home/u rw - overlay overlay rw
garbage without separator
26 22 0:23 / /short - ext4
`
	for path, want := range map[string]bool{
		"/":             true,  // ext4
		"/var/tmp":      true,  // ext4 via /
		"/mnt":          false, // nfs
		"/mnt/data/x":   false, // nfs: deepest mount that contains it
		"/mnt/fast":     true,  // tmpfs is deeper than nfs
		"/mnt/fast/a/b": true,
		"/mnt/fastest":  false, // a sibling name is not under /mnt/fast
		"/home/u/dir":   true,
		"/home/user":    true, // /home/u does not contain it; / does
		"/short/place":  true,
	} {
		err := zipPrivateFSCheck(path, mi)
		if (err == nil) != want {
			t.Errorf("%s: err = %v, want private=%v", path, err, want)
		}
	}
	if err := zipPrivateFSCheck("/x", ""); err == nil || !strings.Contains(err.Error(), "Linux-private filesystem") {
		t.Errorf("no mount at all must be refused: %v", err)
	}
	if err := zipPrivateFSCheck("/x", "1 2 3 4 / x - ext4\n"); err != nil {
		// five left fields are required: "1 2 3 4 / x" has six, mount point is the fifth ("/"), so ext4 applies.
		t.Errorf("minimal line: %v", err)
	}
}

func TestZipPathParts(t *testing.T) {
	abs, parts := pathParts("/a//b/./c/..")
	if !abs || strings.Join(parts, ",") != "a,b,c,.." {
		t.Errorf("pathParts = %v %v", abs, parts)
	}
	if got := joinParts(false, nil); got != "." {
		t.Errorf("empty relative = %q", got)
	}
	if got := joinParts(true, nil); got != "/" {
		t.Errorf("empty absolute = %q", got)
	}
	if got := pyParent("//a/b"); got != "//a" {
		t.Errorf("two leading slashes are kept: %q", got)
	}
	if got := pyParent("///a/b"); got != "/a" {
		t.Errorf("three leading slashes collapse: %q", got)
	}
}

func TestPyIntForms(t *testing.T) {
	for in, want := range map[string]int64{"5": 5, " 5 ": 5, "+5": 5, "-5": -5, "1_000": 1000, "007": 7, "\u0663": 3, "\u0661\u0662": 12, "9223372036854775807": 1<<63 - 1} {
		if got, err := pyInt(in); err != nil || got != want {
			t.Errorf("pyInt(%q) = %d, %v; want %d", in, got, err, want)
		}
	}
	for _, in := range []string{"", " ", "+", "-", "--1", "1__0", "_1", "1_", "1.0", "0x10", "1e3", "abc", "9223372036854775808", "99999999999999999999"} {
		if got, err := pyInt(in); err == nil {
			t.Errorf("pyInt(%q) = %d, want an error", in, got)
		}
	}
	var n int64
	f := intFlag{v: &n}
	if err := f.Set("12"); err != nil || n != 12 || f.String() != "12" {
		t.Errorf("flag set: %d %v %q", n, err, f.String())
	}
	if err := f.Set("x"); err == nil || n != 12 {
		t.Errorf("a bad value must leave the flag untouched: %d %v", n, err)
	}
	if (intFlag{}).String() != "" {
		t.Error("an unbound flag prints empty")
	}
}
