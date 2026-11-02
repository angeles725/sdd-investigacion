//go:build linux

package pcap

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// End-to-end parity: the real legacy corroborate_pcap.py / pcap_flows.py and the Go commands run the same
// scenarios against the same fake Bubblewrap/capinfos/tshark and must leave the same exit code, stdout, stderr
// and published tree (file modes and bytes). Only the run clock of the analysis manifest is not compared.

type tool struct {
	name   string // scenario prefix
	legacy string // script under testdata/legacy
	run    func([]string, cli.Stdio) int
}

var (
	evidenceTool = tool{"pcap", "corroborate_pcap.py", Run}
	flowsTool    = tool{"flows", "pcap_flows.py", RunFlows}
)

type outcome struct {
	code           int
	stdout, stderr string
	tree           map[string]string
}

type scenario struct {
	name  string
	tools []tool
	// prep adjusts the fakes and the working directory before either implementation runs.
	prep func(r *rig, cwd string)
	args []string
	env  []string
	// loose leaves the run record's exit_code and signal out of the comparison: a pipe-fed run stopped at the output cap
	// ends on SIGTERM where the legacy file-fed run ended on SIGXFSZ (RLIMIT_FSIZE has no meaning for a pipe).
	loose bool
	// raw sends args as written (--manifest-cli included, as @MANIFEST@) instead of appending the manifest tool.
	raw bool
	// diverges replaces the comparison for a scenario whose difference is intended and documented.
	diverges func(t *testing.T, tl tool, want, got outcome)
}

var defaultArgs = []string{"--input", "in.pcap", "--output", "out"}

func pcapOnly(f ...func(*rig, string)) func(*rig, string) {
	return func(r *rig, cwd string) {
		for _, g := range f {
			g(r, cwd)
		}
	}
}

func put(name, content string) func(*rig, string) {
	return func(r *rig, _ string) { r.set(name, content) }
}

func write(rel string, body []byte) func(*rig, string) {
	return func(_ *rig, cwd string) {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(cwd, rel)), 0o755); err != nil {
			panic(err)
		}
		if err := os.WriteFile(filepath.Join(cwd, rel), body, 0o644); err != nil {
			panic(err)
		}
	}
}

func both() []tool { return []tool{evidenceTool, flowsTool} }

func scenarios() []scenario {
	pcapng := append([]byte{0x0a, 0x0d, 0x0d, 0x0a}, []byte("section header")...)
	be := append([]byte{0xa1, 0xb2, 0xc3, 0xd4}, []byte("big endian")...)
	return []scenario{
		{name: "ok", tools: both(), args: defaultArgs},
		{name: "ok-with-caps", tools: both(), args: append([]string{"--timeout-seconds", "5", "--max-bytes", "100000"}, defaultArgs...)},
		{name: "ok-abbreviated-option-and-equals-form", tools: both(), args: []string{"--inp=in.pcap", "--out", "out", "--timeout-s", "7"}},
		{name: "pcapng-magic", tools: both(), prep: write("in.pcap", pcapng), args: defaultArgs},
		{name: "big-endian-magic", tools: both(), prep: write("in.pcap", be), args: defaultArgs},
		{name: "capinfos-exits-nonzero", tools: []tool{evidenceTool}, prep: put("fail-capinfos", "3"), args: defaultArgs},
		{name: "phs-exits-nonzero", tools: []tool{evidenceTool}, prep: put("fail-phs", "4"), args: defaultArgs},
		{name: "both-exit-nonzero", tools: []tool{evidenceTool}, prep: pcapOnly(put("fail-phs", "4"), put("fail-capinfos", "5")), args: defaultArgs},
		{name: "capinfos-int-unparseable", tools: []tool{evidenceTool}, prep: put("capinfos.txt", "Number of packets: 1,234\n"), args: defaultArgs},
		{name: "capinfos-float-unparseable", tools: []tool{evidenceTool}, prep: put("capinfos.txt", "Capture duration: soon seconds\n"), args: defaultArgs},
		{name: "capinfos-empty-output", tools: []tool{evidenceTool}, prep: put("capinfos.txt", ""), args: defaultArgs},
		{name: "phs-garbage", tools: []tool{evidenceTool}, prep: put("phs.txt", "nothing parseable\n==\n"), args: defaultArgs},
		{name: "output-cap", tools: both(), loose: true, args: append([]string{"--max-bytes", "20"}, defaultArgs...)},
		{name: "timeout", tools: []tool{evidenceTool}, prep: put("sleep-capinfos", "5"), args: append([]string{"--timeout-seconds", "1"}, defaultArgs...)},
		{name: "zero-timeout", tools: both(), args: append([]string{"--timeout-seconds", "0"}, defaultArgs...)},
		{name: "zero-max-bytes", tools: both(), args: append([]string{"--max-bytes", "0"}, defaultArgs...)},
		{name: "negative-max-bytes", tools: both(), args: append([]string{"--max-bytes=-5"}, defaultArgs...)},
		{name: "huge-caps", tools: both(), args: append([]string{"--timeout-seconds", "99999999999999999999", "--max-bytes", "99999999999999999999"}, defaultArgs...)},
		{name: "not-a-pcap", tools: both(), prep: write("in.pcap", []byte("not a pcap file\n")), args: defaultArgs},
		{name: "empty-input", tools: both(), prep: write("in.pcap", nil), args: defaultArgs},
		{name: "two-byte-input", tools: both(), prep: write("in.pcap", []byte{0xd4, 0xc3}), args: defaultArgs},
		{name: "directory-input", tools: both(), prep: func(_ *rig, cwd string) { _ = os.Mkdir(filepath.Join(cwd, "dir.pcap"), 0o755) }, args: []string{"--input", "dir.pcap", "--output", "out"}},
		{name: "missing-input", tools: both(), args: []string{"--input", "absent.pcap", "--output", "out"}},
		{name: "symlink-input", tools: both(), prep: func(_ *rig, cwd string) { _ = os.Symlink("in.pcap", filepath.Join(cwd, "link.pcap")) }, args: []string{"--input", "link.pcap", "--output", "out"}},
		{name: "input-path-is-normalised-in-messages", tools: both(), args: []string{"--input", "./sub//absent.pcap", "--output", "out"}},
		{name: "output-exists", tools: both(), prep: func(_ *rig, cwd string) { _ = os.Mkdir(filepath.Join(cwd, "out"), 0o700) }, args: defaultArgs},
		{name: "output-is-a-dangling-symlink", tools: both(), prep: func(_ *rig, cwd string) { _ = os.Symlink("nowhere", filepath.Join(cwd, "out")) }, args: defaultArgs},
		{name: "output-is-the-input", tools: both(), args: []string{"--input", "in.pcap", "--output", "in.pcap"}},
		{name: "output-parent-missing", tools: both(), args: []string{"--input", "in.pcap", "--output", "nowhere/out"}},
		{name: "output-parent-is-a-file", tools: both(), args: []string{"--input", "in.pcap", "--output", "in.pcap/out"}},
		{name: "output-in-a-subdirectory", tools: both(), prep: func(_ *rig, cwd string) { _ = os.Mkdir(filepath.Join(cwd, "sub"), 0o755) }, args: []string{"--input", "in.pcap", "--output", "sub/./out/"}},
		{name: "output-through-a-symlinked-parent", tools: both(), prep: func(_ *rig, cwd string) {
			_ = os.Mkdir(filepath.Join(cwd, "real"), 0o755)
			_ = os.Symlink("real", filepath.Join(cwd, "via"))
		}, args: []string{"--input", "in.pcap", "--output", "via/out"}},
		{name: "output-empty-string", tools: both(), args: []string{"--input", "in.pcap", "--output", ""}},
		{name: "bwrap-missing", tools: both(), prep: func(r *rig, _ string) { _ = os.Remove(filepath.Join(r.dir, "bwrap")) }, args: defaultArgs},
		{name: "tshark-missing", tools: both(), prep: func(r *rig, _ string) { _ = os.Remove(filepath.Join(r.dir, "tshark")) }, args: defaultArgs},
		{name: "capinfos-missing", tools: []tool{evidenceTool}, prep: func(r *rig, _ string) { _ = os.Remove(filepath.Join(r.dir, "capinfos")) }, args: defaultArgs},
		{name: "configured-tshark-does-not-exist", tools: both(), env: []string{"RSDD_TSHARK=/nonexistent/tshark"}, args: defaultArgs},
		{name: "configured-tshark-is-another-file", tools: both(), env: []string{"RSDD_TSHARK=/usr/bin/true"}, args: defaultArgs},
		{name: "configured-tshark-empty", tools: both(), env: []string{"RSDD_TSHARK="}, args: defaultArgs},
		{name: "tshark-version-empty", tools: both(), prep: put("version.txt", ""), args: defaultArgs},
		{name: "tshark-version-blank-first-line", tools: both(), prep: put("version.txt", "\n  second\n"), args: defaultArgs, diverges: manifestRefusal},
		{name: "tshark-version-whitespace-only", tools: both(), prep: put("version.txt", " \n\t\n"), args: defaultArgs},
		{name: "tshark-version-crlf", tools: both(), prep: put("version.txt", "TShark 3.6.2\r\nmore\r\n"), args: defaultArgs},
		// command-line handling
		{name: "usage-help", tools: both(), raw: true, args: []string{"--help"}},
		{name: "usage-help-short-after-valid-options", tools: both(), raw: true, args: []string{"--input", "in.pcap", "-h"}},
		{name: "usage-no-arguments", tools: both(), raw: true, args: nil},
		{name: "usage-missing-input", tools: both(), raw: true, args: []string{"--output", "out", "--manifest-cli", "@MANIFEST@"}},
		{name: "usage-missing-manifest-cli", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--output", "out"}},
		{name: "usage-unknown-option", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@", "--bogus"}},
		{name: "usage-unknown-short-option-and-stray-values", tools: both(), raw: true, args: []string{"-x", "stray", "--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@", "more"}},
		{name: "usage-invalid-int", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@", "--timeout-seconds", "x"}},
		{name: "usage-invalid-int-before-missing-required", tools: both(), raw: true, args: []string{"--max-bytes", "1.5"}},
		{name: "usage-expected-one-argument", tools: both(), raw: true, args: []string{"--input"}},
		{name: "usage-option-as-value", tools: both(), raw: true, args: []string{"--input", "--output", "out"}},
		{name: "usage-dash-value-with-space", tools: both(), raw: true, args: []string{"--input", "-in pcap", "--output", "out", "--manifest-cli", "@MANIFEST@"}},
		{name: "usage-ambiguous-prefix", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--output", "out", "--m", "1"}},
		{name: "usage-ambiguous-prefix-with-value", tools: both(), raw: true, args: []string{"--ma=1"}},
		{name: "usage-help-with-value", tools: both(), raw: true, args: []string{"--help=x"}},
		{name: "usage-short-help-glued", tools: both(), raw: true, args: []string{"-hx"}},
		{name: "usage-short-help-repeated", tools: both(), raw: true, args: []string{"-hhh"}},
		{name: "usage-short-help-with-equals", tools: both(), raw: true, args: []string{"-h=x"}},
		{name: "usage-help-prefix", tools: both(), raw: true, args: []string{"--he"}},
		{name: "usage-double-dash-alone", tools: both(), raw: true, args: []string{"--"}},
		{name: "usage-double-dash-before-extras", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@", "--", "--extra", "x"}},
		{name: "usage-double-dash-as-value-separator", tools: both(), raw: true, args: []string{"--input", "--", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@"}},
		{name: "usage-double-dash-after-value", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--", "--output", "out", "--manifest-cli", "@MANIFEST@"}},
		{name: "usage-negative-values", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@", "--max-bytes", "-5", "--timeout-seconds", "-.5"}},
		{name: "usage-int-forms", tools: both(), raw: true, args: []string{"--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@", "--max-bytes", " 1_000_000 ", "--timeout-seconds", "+7"}},
		{name: "usage-repeated-option-last-wins", tools: both(), raw: true, args: []string{"--input", "nope", "--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@"}},
		{name: "usage-single-dash-long-option", tools: both(), raw: true, args: []string{"-input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@"}},
		{name: "usage-flows-max-streams-invalid", tools: []tool{flowsTool}, raw: true, args: []string{"--max-streams", "many"}},
		{name: "usage-flows-help-shows-max-streams", tools: []tool{flowsTool}, raw: true, args: []string{"-h"}},
		{name: "usage-evidence-rejects-max-streams", tools: []tool{evidenceTool}, raw: true, args: []string{"--input", "in.pcap", "--output", "out", "--manifest-cli", "@MANIFEST@", "--max-streams", "3"}},
		// pcap-flows
		{name: "flows-fields-fail", tools: []tool{flowsTool}, prep: put("fail-fields", "6"), args: defaultArgs},
		{name: "flows-no-tcp-streams", tools: []tool{flowsTool}, prep: put("fields.txt", "\n\n\n"), args: defaultArgs},
		{name: "flows-max-streams-1", tools: []tool{flowsTool}, args: append([]string{"--max-streams", "1"}, defaultArgs...)},
		{name: "flows-max-streams-0", tools: []tool{flowsTool}, args: append([]string{"--max-streams", "0"}, defaultArgs...)},
		{name: "flows-max-streams-negative", tools: []tool{flowsTool}, args: append([]string{"--max-streams", "-1"}, defaultArgs...)},
		{name: "flows-max-streams-huge", tools: []tool{flowsTool}, args: append([]string{"--max-streams", "99999999999999999999999"}, defaultArgs...)},
		{name: "flows-follow-fails", tools: []tool{flowsTool}, prep: put("fail-follow-1", "7"), args: defaultArgs},
		{name: "flows-follow-output-missing", tools: []tool{flowsTool}, prep: func(r *rig, _ string) { _ = os.Remove(filepath.Join(r.data, "follow-1.txt")) }, args: defaultArgs},
		{name: "flows-conv-fails", tools: []tool{flowsTool}, prep: put("fail-conv", "8"), args: defaultArgs},
		{name: "flows-stream-ids-sorted-deduplicated", tools: []tool{flowsTool}, prep: pcapOnly(
			put("fields.txt", "10\n2\n2 007\nx\n12abc\n"),
			put("follow-2.txt", "===\nNode 0: a\nNode 1: b\n41\n===\n"),
			put("follow-7.txt", "===\nNode 0: c\nNode 1: d\n\t42\n===\n"),
			put("follow-10.txt", "===\nNode 0: e\nNode 1: f\nzz\n===\n"),
		), args: defaultArgs},
		{name: "flows-huge-stream-index", tools: []tool{flowsTool}, prep: pcapOnly(
			put("fields.txt", "99999999999999999999\n"),
			put("follow-99999999999999999999.txt", "===\nNode 0: a\nNode 1: b\n41\n===\n"),
		), args: defaultArgs},
		{name: "flows-conv-garbage", tools: []tool{flowsTool}, prep: put("conv.txt", "no sections at all\n"), args: defaultArgs},
	}
}

// snapshot is the observable result of one run: the process outcome and everything left under cwd.
func snapshot(t *testing.T, cwd string, loose bool, code int, stdout, stderr string) outcome {
	t.Helper()
	return snapshotWith(t, cwd, code, stdout, stderr, func(body string) string { return normaliseManifest(t, []byte(body), loose) })
}

// snapshotWith is snapshot with the treatment of the analysis manifest chosen by the caller.
func snapshotWith(t *testing.T, cwd string, code int, stdout, stderr string, manifest func(string) string) outcome {
	t.Helper()
	norm := func(s string) string { return strings.ReplaceAll(s, cwd, "ROOT") }
	o := outcome{code: code, stdout: norm(stdout), stderr: norm(stderr), tree: map[string]string{}}
	err := filepath.WalkDir(cwd, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(cwd, p)
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		switch {
		case fi.Mode()&fs.ModeSymlink != 0:
			target, _ := os.Readlink(p)
			o.tree[rel] = "symlink -> " + target
		case fi.IsDir():
			o.tree[rel] = "dir " + fi.Mode().Perm().String()
		default:
			body, rerr := os.ReadFile(p)
			if rerr != nil {
				return rerr
			}
			content := norm(string(body))
			if filepath.Base(p) == "analysis-manifest.v1.json" {
				content = manifest(content)
			}
			o.tree[rel] = "file " + fi.Mode().Perm().String() + " " + content
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return o
}

// normaliseManifest drops what depends on the wall clock: the run timings and the identity hash derived from them.
func normaliseManifest(t *testing.T, body []byte, loose bool) string {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("manifest is not JSON: %v\n%s", err, body)
	}
	delete(m, "identity")
	// The evidence file names the working directory, which differs between the two runs, so its hash does; the
	// file itself is compared byte for byte (root-normalised) as its own tree entry.
	if outs, ok := m["outputs"].([]any); ok {
		for _, o := range outs {
			if om, ok := o.(map[string]any); ok {
				delete(om, "sha256")
			}
		}
	}
	if run, ok := m["run"].(map[string]any); ok {
		keys := []string{"started_at", "ended_at", "duration_ms", "exit_code", "signal"}
		if !loose {
			keys = keys[:3]
		}
		for _, k := range keys {
			if _, has := run[k]; !has {
				t.Errorf("manifest run lacks %s", k)
			}
			delete(run, k)
		}
	}
	out, _ := json.Marshal(m)
	return string(out)
}
func report(t *testing.T, want, got outcome) {
	t.Helper()
	if want.code != got.code {
		t.Errorf("exit code: python %d, go %d\npython stderr: %q\ngo stderr:     %q", want.code, got.code, want.stderr, got.stderr)
	}
	if want.stdout != got.stdout {
		t.Errorf("stdout differs:\npython: %q\ngo:     %q", want.stdout, got.stdout)
	}
	if want.stderr != got.stderr {
		t.Errorf("stderr differs:\npython: %q\ngo:     %q", want.stderr, got.stderr)
	}
	keys := map[string]bool{}
	for k := range want.tree {
		keys[k] = true
	}
	for k := range got.tree {
		keys[k] = true
	}
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		w, g := want.tree[k], got.tree[k]
		if w != g {
			t.Errorf("tree entry %q differs at byte %d:\npython: %q\ngo:     %q", k, firstDiff(w, g), window(w, firstDiff(w, g)), window(g, firstDiff(w, g)))
		}
	}
}

// manifestRefusal is the one intended difference of the matrix. When the manifest tool refuses the spec (an empty
// tshark version here), the legacy script died with a Python stack dump and exit 1: ManifestError subclasses the
// AdapterError of adapter_core as lib/adapter_helpers.py imports it, a second module object next to the
// lib.adapter_core the script catches, so the script's handler never sees it. The Go command reports the same
// refusal cleanly (exit 2, one "<tool>: ..." line, no stack dump). Both leave the same tree: nothing published,
// no stage left behind.
func manifestRefusal(t *testing.T, tl tool, want, got outcome) {
	t.Helper()
	const refusal = "analysis-manifest: tool.version must be a non-empty string\n"
	if want.code != 1 || !strings.HasPrefix(want.stderr, refusal) || !strings.Contains(want.stderr, "Traceback (most recent call last)") {
		t.Errorf("the legacy tool no longer dies with a stack dump: exit %d\n%s", want.code, want.stderr)
	}
	prog := map[string]string{"pcap": "corroborate-pcap", "flows": "pcap-flows"}[tl.name]
	if wantErr := refusal + prog + ": manifest-cli 'create' failed (exit 2)\n"; got.code != 2 || got.stderr != wantErr {
		t.Errorf("go: exit %d stderr %q, want exit 2 and %q", got.code, got.stderr, wantErr)
	}
	if len(want.tree) != len(got.tree) {
		t.Errorf("trees differ: python %v, go %v", want.tree, got.tree)
	}
	for k := range want.tree {
		if _, ok := got.tree[k]; !ok {
			t.Errorf("go lacks %q", k)
		}
	}
}

// firstDiff is the index of the first byte where a and b differ.
func firstDiff(a, b string) int {
	n := min(len(a), len(b))
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

// window is the text around index i, enough to see what differs in a long entry.
func window(s string, i int) string {
	lo, hi := max(0, i-80), min(len(s), i+160)
	return s[lo:hi]
}
