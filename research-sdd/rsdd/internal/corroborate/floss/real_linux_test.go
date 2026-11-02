//go:build linux

package floss

// The slow lane (RSDD_TEST_LANE=slow or all): the real floss and the real bwrap on a generated PE32. These are the
// former slow-lane cases of tests/floss.test.sh (T1-T7, T10, T12); everything else runs against a stand-in floss.

import (
	"bytes"
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// tinyPE is a minimal PE32 whose .rdata holds the given NUL-terminated strings.
func tinyPE(strs ...string) []byte {
	le := binary.LittleEndian
	var b bytes.Buffer
	w := func(v ...any) {
		for _, x := range v {
			_ = binary.Write(&b, le, x)
		}
	}
	dos := make([]byte, 64)
	copy(dos, "MZ")
	le.PutUint32(dos[0x3c:], 64)
	b.Write(dos)
	b.WriteString("PE\x00\x00")
	w(uint16(0x14c), uint16(1), uint32(0), uint32(0), uint32(0), uint16(0xe0), uint16(0x102)) // COFF header
	b.Write([]byte{0x0b, 0x01, 0x01, 0x00})
	w(uint32(0), uint32(0x200), uint32(0), uint32(0x1000), uint32(0x1000), uint32(0x2000))
	w(uint32(0x400000), uint32(0x1000), uint32(0x200))
	w(uint16(4), uint16(0), uint16(0), uint16(0), uint16(4), uint16(0))
	w(uint32(0), uint32(0x3000), uint32(0x200), uint32(0), uint16(3), uint16(0))
	w(uint32(0x100000), uint32(0x1000), uint32(0x100000), uint32(0x1000), uint32(0), uint32(16))
	b.Write(make([]byte, 128))
	b.WriteString(".rdata\x00\x00")
	w(uint32(0x200), uint32(0x1000), uint32(0x200), uint32(0x200), uint32(0), uint32(0), uint16(0), uint16(0), uint32(0x40000040))
	b.Write(make([]byte, 0x200-b.Len()))
	var data []byte
	for _, s := range strs {
		data = append(append(data, s...), 0)
	}
	if pad := 0x200 - len(data)%0x200; pad < 0x200 {
		data = append(data, make([]byte, pad)...)
	}
	return append(b.Bytes(), data...)
}

func TestRealFlossSlowLane(t *testing.T) {
	if lane := os.Getenv("RSDD_TEST_LANE"); lane != "slow" && lane != "all" {
		t.Skip("slow lane only (RSDD_TEST_LANE=slow or all): runs the real floss")
	}
	if _, err := exec.LookPath("floss"); err != nil {
		skipOrFail(t, "floss not installed")
	}
	w := newWorld(t, flossHappy)
	env := map[string]string{"PATH": filepath.Join(w.root, "pybin") + ":" + os.Getenv("PATH"), "RSDD_FLOSS": ""}
	w.input = w.out("tiny_pe.exe")
	must(t, os.WriteFile(w.input, tinyPE("StaticAlphaString", "StaticBetaString", "StaticGammaString", "ObfuscatedTokenXYZ", "SecretKeyValue123"), 0o644))

	if code, _, stderr := w.runEnv(env, w.out("a")); code != 0 {
		if code == 1 && bytes.Contains(w.read("a/engine/stderr.txt"), []byte("bwrap: execvp")) {
			// The venv's interpreter lives outside the tree the sandbox binds (a Homebrew or pyenv python):
			// the sandbox cannot start this floss at all, with the legacy script as well.
			skipOrFail(t, "the installed floss cannot start inside the sandbox: "+strings.TrimSpace(string(w.read("a/engine/stderr.txt"))))
		}
		t.Fatalf("happy path: code=%d %s\nfloss said: %.1500s", code, stderr, w.read("a/engine/stderr.txt"))
	}
	d := evidence(t, w, "a")
	s := sub(t, d, "strings")
	if d["status"] != "complete" || s["floss_version"] == "" || s["total_count"].(float64) < 1 {
		t.Errorf("evidence: status=%v version=%v total=%v", d["status"], s["floss_version"], s["total_count"])
	}
	profile := sub(t, d, "isolation", "profile")
	if profile["network_access"] != false || profile["target_execution"] != false {
		t.Errorf("profile: %v", profile)
	}
	if code, _, _ := w.runEnv(env, w.out("b")); code != 0 || !bytes.Equal(w.read("a/floss-evidence.v1.json"), w.read("b/floss-evidence.v1.json")) {
		t.Errorf("two runs must produce byte-identical evidence (code %d)", code)
	}
	manifest := w.out("a/engine/analysis-manifest.v1.json")
	if out, err := exec.Command(w.python, w.manifest, "verify", "--root", w.out("a"), manifest).CombinedOutput(); err != nil {
		t.Errorf("manifest verify: %v\n%s", err, out)
	}

	if code, _, _ := w.runEnv(env, w.out("cap"), "--max-strings", "2"); code != 0 {
		t.Errorf("string cap: code=%d", code)
	} else if c := evidence(t, w, "cap"); sub(t, c, "strings")["total_sampled"].(float64) > 2 || sub(t, c, "strings")["truncated"] != true || !contains(c["limitations"], "inventory truncated: string cap 2 reached") {
		t.Errorf("string cap not enforced: %v", sub(t, c, "strings")["total_sampled"])
	}

	if code, _, _ := w.runEnv(env, w.out("len"), "--max-string-len", "5"); code != 0 {
		t.Errorf("length cap: code=%d", code)
	} else {
		c := evidence(t, w, "len")
		for _, cat := range []string{"static_strings", "stack_strings", "tight_strings", "decoded_strings"} {
			for _, e := range sub(t, c, "strings", cat)["strings"].([]any) {
				if v := e.(map[string]any)["value"].(string); len([]rune(v)) > 5 {
					t.Errorf("value exceeds the cap: %q", v)
				}
			}
		}
		if !contains(c["limitations"], "inventory truncated: string-length cap 5 reached") {
			t.Errorf("limitations: %v", c["limitations"])
		}
	}

	w.input = w.out("empty.bin")
	must(t, os.WriteFile(w.input, make([]byte, 256), 0o644))
	if code, _, stderr := w.runEnv(env, w.out("empty")); code != 0 {
		t.Errorf("empty input: code=%d %s", code, stderr)
	} else if c := evidence(t, w, "empty"); c["status"] != "complete" || sub(t, c, "strings")["total_count"] != float64(0) || sub(t, c, "strings")["truncated"] != false {
		t.Errorf("empty input must be a complete empty inventory: %v", c["status"])
	}

	w.input = w.out("tiny_pe.exe")
	switch code, _, _ := w.runEnv(env, w.out("slow"), "--timeout", "1"); {
	case code == 0:
		t.Log("floss finished within 1 s: the timeout case is not exercised on this host")
	case code == 1:
		c := evidence(t, w, "slow")
		if c["status"] != "failed" || !contains(c["errors"], "timeout") || sub(t, c, "strings")["truncated"] != true {
			t.Errorf("timeout must be visible: %v", c["errors"])
		}
		if !strings.Contains(strings.Join(toStrings(c["limitations"]), "|"), "timeout") {
			t.Errorf("no timeout limitation: %v", c["limitations"])
		}
	default:
		t.Errorf("timeout run: code=%d", code)
	}
}

func toStrings(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}
