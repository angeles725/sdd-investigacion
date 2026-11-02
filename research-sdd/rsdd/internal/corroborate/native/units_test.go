package native

import (
	"encoding/json"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The fixed radare2 command line is the safety contract: -NN -S disable user configuration and plugins, -x
// and the fixed `aaa;aflj` script disable every write, debug, profile and script surface. This is the Go form of
// the legacy fast-lane F1 live-import check.
func TestSafeR2KeepsRequiredFlagsAndNoForbiddenOnes(t *testing.T) {
	have := map[string]bool{}
	for _, a := range safeR2 {
		have[a] = true
	}
	for _, f := range []string{"-NN", "-S", "-x", "-q"} {
		if !have[f] {
			t.Errorf("required safe flag %s missing from %v", f, safeR2)
		}
	}
	for _, f := range []string{"-w", "-d", "-i", "-I", "-p", "-r", "-R"} {
		if have[f] {
			t.Errorf("forbidden flag %s present in %v", f, safeR2)
		}
	}
	want := []string{"-NN", "-S", "-x", "-q", "-e", "scr.color=0", "-e", "scr.utf8=false", "-e", "scr.interactive=false", "-c", "aaa;aflj", "input/target.bin"}
	if !reflect.DeepEqual(safeR2, want) {
		t.Fatalf("safeR2 = %v", safeR2)
	}
}

func TestSandboxPrefixIsTheLegacyArgv(t *testing.T) {
	env := []envVar{{"HOME", "/tmp/rsdd/home"}, {"PATH", "/x:/usr/bin:/bin"}}
	got := sandboxPrefix("/usr/bin/bwrap", env)
	want := []string{"/usr/bin/bwrap", "--die-with-parent", "--new-session", "--unshare-net", "--ro-bind", "/", "/",
		"--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/home",
		"--dir", "/tmp/rsdd/cache", "--dir", "/tmp/rsdd/config", "--dir", "/tmp/rsdd/data",
		"--dir", "/tmp/rsdd/work", "--ro-bind", ".", "/tmp/rsdd/work",
		"--setenv", "HOME", "/tmp/rsdd/home", "--setenv", "PATH", "/x:/usr/bin:/bin", "--chdir", "/tmp/rsdd/work", "--"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("prefix:\n got %q\nwant %q", got, want)
	}
}

func TestSandboxEnvironmentIsSyntheticAndOrdered(t *testing.T) {
	env := sandboxEnv("/opt/r2/bin")
	var keys []string
	for _, e := range env {
		keys = append(keys, e.k)
	}
	if !reflect.DeepEqual(keys, []string{"HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "TMPDIR", "PATH", "LANG", "LC_ALL", "TZ"}) {
		t.Fatalf("keys: %v", keys)
	}
	if env[5].v != "/opt/r2/bin:/usr/bin:/bin" || env[8].v != "UTC" {
		t.Fatalf("values: %v", env)
	}
}

func fnames(fs []map[string]any) []string {
	var n []string
	for _, f := range fs {
		s, _ := f["name"].(string)
		n = append(n, s)
	}
	return n
}

func TestParseFunctions(t *testing.T) {
	cases := []struct {
		name, in string
		want     []string
		err      bool
	}{
		{"by offset then name", `[{"name":"b","offset":2},{"name":"z","offset":1},{"name":"a","offset":2}]`, []string{"z", "a", "b"}, false},
		{"missing offset sorts as zero", `[{"name":"a","offset":5},{"name":"nooff"}]`, []string{"nooff", "a"}, false},
		{"missing name sorts as empty", `[{"offset":1,"name":"x"},{"offset":1}]`, []string{"", "x"}, false},
		{"non-dict items are skipped", `[1,"s",null,{"name":"a","offset":1}]`, []string{"a"}, false},
		{"empty list", `[]`, nil, false},
		{"float and large offsets compare numerically", `[{"name":"big","offset":18446744073709551616},{"name":"f","offset":1.5},{"name":"i","offset":2}]`, []string{"f", "i", "big"}, false},
		{"trailing whitespace", "[]\n  \n", nil, false},
		{"object", `{"name":"a"}`, nil, true},
		{"truncated", `[{"name":`, nil, true},
		{"two documents", `[] []`, nil, true},
		{"empty", ``, nil, true},
		{"string offset", `[{"name":"a","offset":"1"}]`, nil, true},
		{"bool offset", `[{"name":"a","offset":true}]`, nil, true},
		{"null name", `[{"name":null,"offset":1}]`, nil, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseFunctions([]byte(c.in))
			if (err != nil) != c.err {
				t.Fatalf("err=%v want error=%v", err, c.err)
			}
			if !reflect.DeepEqual(fnames(got), c.want) {
				t.Fatalf("names %v want %v", fnames(got), c.want)
			}
		})
	}
}

func TestParseFunctionsKeepsOnlyKnownKeysAndRawValues(t *testing.T) {
	got, err := parseFunctions([]byte(`[{"name":"m","offset":4096,"size":10,"nargs":2,"nbbs":3,"type":"fcn","ref":{"a":1},"cc":"x"}]`))
	if err != nil || len(got) != 1 {
		t.Fatalf("%v %v", got, err)
	}
	keys := []string{}
	for k := range got[0] {
		keys = append(keys, k)
	}
	if len(keys) != 6 {
		t.Fatalf("keys %v", keys)
	}
	if n, ok := got[0]["offset"].(json.Number); !ok || n.String() != "4096" {
		t.Fatalf("numbers stay exact: %#v", got[0]["offset"])
	}
}

func TestIsoZ(t *testing.T) {
	cases := map[time.Time]string{
		time.Date(2026, 11, 2, 12, 0, 0, 123456000, time.UTC):                  "2026-11-02T12:00:00.123456Z",
		time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC):                          "2026-11-02T12:00:00Z",
		time.Date(2026, 11, 2, 12, 0, 0, 5000, time.UTC):                       "2026-11-02T12:00:00.000005Z",
		time.Date(2026, 11, 2, 14, 0, 0, 999999999, time.FixedZone("x", 7200)): "2026-11-02T12:00:00.999999Z",
	}
	for in, want := range cases {
		if got := isoZ(in); got != want {
			t.Errorf("isoZ(%v) = %q want %q", in, got, want)
		}
	}
}

func TestFirstLine(t *testing.T) {
	for in, want := range map[string]string{
		"radare2 5.9\nmore": "radare2 5.9", "a\r\nb": "a", "a\rb": "a", "a\vb": "a", "a\u2028b": "a", "": "", "\nx": "", "only": "only",
	} {
		if got := firstLine(in); got != want {
			t.Errorf("firstLine(%q) = %q want %q", in, got, want)
		}
	}
}

func TestOSErrorText(t *testing.T) {
	cases := []struct {
		err  error
		file string
		want string
	}{
		{syscall.ENOENT, "/a/b", "[Errno 2] No such file or directory: '/a/b'"},
		{syscall.EEXIST, "/x", "[Errno 17] File exists: '/x'"},
		{syscall.EACCES, "", "[Errno 13] Permission denied"},
		{syscall.ENOENT, "it's", `[Errno 2] No such file or directory: "it's"`},
		{syscall.ENOTDIR, "/f/x", "[Errno 20] Not a directory: '/f/x'"},
	}
	for _, c := range cases {
		if got := osError(c.err, c.file).Error(); got != c.want {
			t.Errorf("osError(%v,%q) = %q want %q", c.err, c.file, got, c.want)
		}
	}
	if got := osError(strings.NewReader("").UnreadByte(), "x"); got == nil {
		t.Fatal("a non-errno error is kept")
	}
}

func TestTrimToBudget(t *testing.T) {
	out, errb := trimToBudget([]byte("abcdef"), []byte("ghij"), 8)
	if string(out) != "abcdef" || string(errb) != "gh" {
		t.Fatalf("stdout keeps its bytes first, stderr gets the rest: %q %q", out, errb)
	}
	out, errb = trimToBudget([]byte("abcdef"), []byte("ghij"), 3)
	if string(out) != "abc" || len(errb) != 0 {
		t.Fatalf("%q %q", out, errb)
	}
}
