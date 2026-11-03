package firmware

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

func TestBinwalkVersionReadsBothBannersAndIgnoresTheUsageLine(t *testing.T) {
	for text, want := range map[string]string{
		"Binwalk v2.3.3\nCraig": "2.3.3", "binwalk 3.1.0\n": "3.1.0", "Usage: binwalk [OPTIONS] [FILE_NAME]": "",
		"Binwalk vfake": "fake", "": "", "xbinwalk 4.0": "", "Binwalk v": "",
	} {
		if got := binwalkVersion(text); got != want {
			t.Errorf("binwalkVersion(%q) = %q, want %q", text, got, want)
		}
	}
}

func TestOnlyMajorTwoIsSupported(t *testing.T) {
	for version, refused := range map[string]bool{"2.3.3": false, "2": false, "2.0": false, "3.1.0": true, "10.0": true, "20.1": true, "fake": true, "": true} {
		err := checkBinwalkVersion(version)
		if (err != nil) != refused {
			t.Errorf("checkBinwalkVersion(%q) = %v, refused want %v", version, err, refused)
		}
	}
	if err := checkBinwalkVersion("3.1.0"); err == nil || err.Error() != "unsupported Binwalk version 3.1.0: only major 2 output is supported" {
		t.Errorf("message = %v", err)
	}
}

func TestParseFindings(t *testing.T) {
	cases := []struct {
		name, text string
		sigs, ents []string // "offset:hex:description"
	}{
		{"three plain lines", "0 0x0 first\n1 0x1 second\n2 0x2 third\n", []string{"0:0x0:first", "1:0x1:second", "2:0x2:third"}, nil},
		{"sorted by offset then description", "5 0x5 b\n5 0x5 a\n1 0x1 z\n", []string{"1:0x1:z", "5:0x5:a", "5:0x5:b"}, nil},
		{"offset order is numeric, not textual", "10 0xa ten\n9 0x9 nine\n", []string{"9:0x9:nine", "10:0xa:ten"}, nil},
		{"entropy lines are split out, case-insensitively", "0 0x0 Rising ENTROPY edge\n1 0x1 sig\n", []string{"1:0x1:sig"}, []string{"0:0x0:Rising ENTROPY edge"}},
		{"colour codes and blanks collapse", "\x1b[31m4\x1b[0m 0x4 red \t text  \n", []string{"4:0x4:red text"}, nil},
		{"hex is normalised", "255 0x00FF upper\n", []string{"255:0xff:upper"}, nil},
		{"header and junk lines are ignored", "DECIMAL HEXADECIMAL DESCRIPTION\n------\nnot a finding\n0x10 only hex\n7 0x7 kept\n", []string{"7:0x7:kept"}, nil},
		{"a line without a description is ignored", "3 0x3\n", nil, nil},
		{"trailing blanks can be read as the description (and collapse to nothing), as the script's pattern does", "3 0x3   \n", []string{"3:0x3:"}, nil},
		{"offsets beyond 64 bits survive", "123456789012345678901234567890 0xfffffffffffffffffffffffff big\n", []string{"123456789012345678901234567890:0xfffffffffffffffffffffffff:big"}, nil},
		{"leading zeros are dropped like int()", "007 0x07 padded\n", []string{"7:0x7:padded"}, nil},
		{"Unicode decimal digits are digits", "٣ 0x3 arabic\n", []string{"3:0x3:arabic"}, nil},
		{"CR and CRLF end a line", "0 0x0 a\r1 0x1 b\r\n2 0x2 c\n", []string{"0:0x0:a", "1:0x1:b", "2:0x2:c"}, nil},
		{"Unicode line separators end a line", "0 0x0 a 1 0x1 b\u00852 0x2 c", []string{"0:0x0:a", "1:0x1:b", "2:0x2:c"}, nil},
		{"invalid UTF-8 is replaced", "0 0x0 a\xffb\n", []string{"0:0x0:a�b"}, nil},
		{"empty", "", nil, nil},
	}
	render := func(list []finding) []string {
		var out []string
		for _, f := range list {
			out = append(out, f.Offset.String()+":"+f.Hex+":"+f.Description)
		}
		return out
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sigs, ents := parseFindings(tc.text)
			if got, want := strings.Join(render(sigs), "\n"), strings.Join(tc.sigs, "\n"); got != want {
				t.Errorf("signatures:\n%s\nwant:\n%s", got, want)
			}
			if got, want := strings.Join(render(ents), "\n"), strings.Join(tc.ents, "\n"); got != want {
				t.Errorf("entropy:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

func TestPySplitlines(t *testing.T) {
	for in, want := range map[string]string{
		"": "", "a": "a", "a\n": "a", "a\n\nb": "a|b", "a\r\nb\rc": "a|b|c", "a\vb\fc": "a|b|c", "a\x1cb\x1dc\x1ed": "a|b|c|d", "a b": "a|b",
	} {
		got := strings.Join(pySplitlines(in), "|")
		if in == "a\n\nb" {
			want = "a||b"
		}
		if got != want {
			t.Errorf("pySplitlines(%q) = %q, want %q", in, got, want)
		}
	}
	if n := len(pySplitlines("\n")); n != 1 {
		t.Errorf("a lone newline is one empty line, got %d", n)
	}
}

func TestIsoUTCOmitsZeroMicroseconds(t *testing.T) {
	for _, tc := range []struct {
		in   time.Time
		want string
	}{
		{time.Date(2026, 11, 2, 5, 0, 0, 0, time.UTC), "2026-11-02T05:00:00Z"},
		{time.Date(2026, 11, 2, 5, 0, 0, 123456000, time.UTC), "2026-11-02T05:00:00.123456Z"},
		{time.Date(2026, 11, 2, 5, 0, 0, 5000, time.UTC), "2026-11-02T05:00:00.000005Z"},
		{time.Date(2026, 11, 2, 5, 0, 0, 999, time.UTC), "2026-11-02T05:00:00Z"},
		{time.Date(2026, 11, 2, 7, 0, 0, 0, time.FixedZone("x", 7200)), "2026-11-02T05:00:00Z"},
	} {
		if got := isoUTC(tc.in); got != tc.want {
			t.Errorf("isoUTC(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestAbsolutePathDropsRelativeAndEmptyEntries(t *testing.T) {
	for in, want := range map[string]string{
		"/usr/bin:/bin": "/usr/bin:/bin", ".:/bin": "/bin", ":/bin": "/bin", "bin:/x:rel/y": "/x", "": "", "relative": "",
	} {
		if got := absolutePath(in); got != want {
			t.Errorf("absolutePath(%q) = %q, want %q", in, got, want)
		}
	}
}

// trustFixture is a binwalk-like file in a directory the test controls.
func trustFixture(t *testing.T) (dir, file string) {
	t.Helper()
	dir = t.TempDir()
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	file = filepath.Join(dir, "binwalk")
	if err := os.WriteFile(file, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir, file
}

func TestTrustGateIsAppliedToTheOpenedDescriptor(t *testing.T) {
	euid := uint64(os.Geteuid())
	if euid == 0 {
		t.Skip("needs an unprivileged user")
	}
	dir, file := trustFixture(t)
	rootOnly := &gate{uids: map[uint64]bool{0: true}, hint: hintDefault}
	mine := &gate{uids: map[uint64]bool{0: true, euid: true}, hint: hintExplicit}

	if _, _, _, err := trustedIdentity(file, rootOnly, nil); err == nil || !strings.Contains(err.Error(), "root-owned") || !strings.HasSuffix(err.Error(), hintDefault) {
		t.Errorf("a user-owned file under a root-only gate: err = %v", err)
	}
	var uid uint64 = 999999
	resolved, size, digest, err := trustedIdentity(file, mine, &uid)
	if err != nil || uid != euid || size != 10 || !strings.HasPrefix(digest, "sha256:") || resolved != mustEval(t, file) {
		t.Errorf("identity = %q %d %q %v (uid sink %d)", resolved, size, digest, err, uid)
	}
	if _, _, err := stageNew(t, file, &gate{uids: map[uint64]bool{0: true}}, nil); err == nil || !strings.Contains(err.Error(), "root-owned") {
		t.Errorf("staging under a root-only gate: err = %v", err)
	}
	var stagedUID uint64 = 999999
	src, staged, err := stageNew(t, file, &gate{uids: map[uint64]bool{0: true, euid: true}}, &stagedUID)
	if err != nil || stagedUID != euid || src.SHA256 != staged.SHA256 || staged.Path != "engine/binwalk" || src.Path != mustEval(t, file) {
		t.Errorf("staged = %+v / %+v err %v uid %d", src, staged, err, stagedUID)
	}

	if err := os.Chmod(file, 0o775); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := trustedIdentity(file, mine, nil); err == nil || !strings.Contains(err.Error(), "non-writable") {
		t.Errorf("group-writable file: err = %v", err)
	}
	if err := os.Chmod(file, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := trustedIdentity(file, mine, nil); err == nil || !strings.Contains(err.Error(), "directory must be") {
		t.Errorf("world-writable directory: err = %v", err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := trustedIdentity(file, nil, nil); err != nil {
		t.Errorf("no gate must mean no trust check: %v", err)
	}
}

func stageNew(t *testing.T, file string, g *gate, sink *uint64) (fsx.Record, fsx.Record, error) {
	t.Helper()
	return stageTrusted(file, filepath.Join(t.TempDir(), "staged"), "engine/binwalk", 0o500, g, sink)
}

func mustEval(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestIdentityAndStagingRefuseLinksAndSpecialFiles(t *testing.T) {
	dir, file := trustFixture(t)
	link := filepath.Join(dir, "link")
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "fifo")
	if err := mkfifo(fifo); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := trustedIdentity(link, nil, nil); !errors.Is(err, fsx.ErrOpen) {
		t.Errorf("symlink: err = %v, want ErrOpen", err)
	}
	if _, _, _, err := trustedIdentity(fifo, nil, nil); !errors.Is(err, fsx.ErrNotRegular) {
		t.Errorf("fifo: err = %v, want ErrNotRegular", err)
	}
	if _, _, err := stageNew(t, link, nil, nil); !errors.Is(err, fsx.ErrSourceOpen) {
		t.Errorf("symlink: err = %v, want ErrSourceOpen", err)
	}
	if _, _, err := stageNew(t, fifo, nil, nil); !errors.Is(err, fsx.ErrSourceNotRegular) {
		t.Errorf("fifo: err = %v, want ErrSourceNotRegular", err)
	}
	// An existing target is never overwritten and never removed.
	target := filepath.Join(dir, "existing")
	if err := os.WriteFile(target, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := stageTrusted(file, target, "x", 0o500, nil, nil); err == nil {
		t.Error("staging over an existing file must fail")
	}
	if b, _ := os.ReadFile(target); string(b) != "keep" {
		t.Error("an existing target was removed or rewritten")
	}
}

func TestResolveBinwalk(t *testing.T) {
	euid := uint64(os.Geteuid())
	if euid == 0 {
		t.Skip("needs an unprivileged user")
	}
	dir, file := trustFixture(t)
	other, _ := trustFixture(t)
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	path := other + ":" + dir + ":/usr/bin:/bin"

	got, err := resolveBinwalk(env(map[string]string{"PATH": path, "RSDD_BINWALK": file}), "/", euid)
	if err != nil || got.trust != trustUser || got.record.Path != mustEval(t, file) {
		t.Errorf("explicit selection: %+v err %v", got, err)
	}
	if got, err := resolveBinwalk(env(map[string]string{"PATH": "/nonexistent", "RSDD_BINWALK": file}), "/", euid); err != nil || got.record.Path != mustEval(t, file) {
		t.Errorf("explicit selection with an empty PATH: %+v err %v", got, err)
	}
	got, err = resolveBinwalk(env(map[string]string{"PATH": path, "RSDD_BINWALK_TEST_ONLY": filepath.Join(other, "binwalk")}), "/", euid)
	if err != nil || got.trust != trustOverride || got.gate != nil {
		t.Errorf("test override: %+v err %v", got, err)
	}
	if _, err := resolveBinwalk(env(map[string]string{"PATH": path}), "/", euid); err == nil || !strings.Contains(err.Error(), "RSDD_BINWALK") {
		t.Errorf("default branch is root-only: err = %v", err)
	}
	if _, err := resolveBinwalk(env(map[string]string{"PATH": path, "RSDD_BINWALK": "binwalk"}), "/", euid); err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Errorf("relative RSDD_BINWALK: err = %v", err)
	}
	cwd := dir
	if _, err := resolveBinwalk(env(map[string]string{"PATH": ".:/nonexistent"}), cwd, euid); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Errorf("a relative PATH entry must not be searched: err = %v", err)
	}
}

func TestWhichSkipsDirectoriesAndNonExecutables(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "tool"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, ok := which("tool", dir); ok {
		t.Error("a directory is not a program")
	}
	if err := os.WriteFile(filepath.Join(dir, "data"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, ok := which("data", dir); ok {
		t.Error("a file without the execute bit is not a program")
	}
	if _, ok := which("sh", ""); ok {
		t.Error("an empty search path finds nothing")
	}
}
