package capa

// End-to-end tests of `rsdd corroborate capa` over a fake sandbox (see rig_test.go). They replace the
// logic cases of the retired tests/capa.test.sh; the old case ids are named in each test's comment.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

func adapterManifest(args []string, s cli.Stdio) int { return adapter.ManifestRun(args, s) }

func asMap(t *testing.T, v any) map[string]any {
	t.Helper()
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("not an object: %#v", v)
	}
	return m
}

// T1, T2, T2-fast: the happy path publishes capa-evidence.v1 with the full envelope and capability records.
func TestRunHappyPathPublishesEvidence(t *testing.T) {
	r := newRig(t)
	code, stdout, stderr := r.run(r.args("ev")...)
	if code != cli.ExitOK || stdout != "" || stderr != "" {
		t.Fatalf("code %d stdout %q stderr %q", code, stdout, stderr)
	}
	doc := r.evidence("ev")
	if doc["schema"] != "capa-evidence.v1" || doc["status"] != "complete" {
		t.Fatalf("schema/status: %v %v", doc["schema"], doc["status"])
	}
	c := asMap(t, doc["capabilities"])
	if c["total_count"] != float64(3) || c["total_sampled"] != float64(3) || c["truncated"] != false {
		t.Fatalf("counts: %v", c)
	}
	items := c["items"].([]any)
	first := asMap(t, items[0])
	if first["name"] != "compiled with gcc" || first["namespace"] != "compiler/gcc" || first["match_count"] != float64(0) {
		t.Fatalf("items must sort by (namespace, name): %v", items)
	}
	last := asMap(t, items[2])
	if last["name"] != "write file" || last["match_count"] != float64(2) ||
		strings.Join(toStrings(last["attack_ids"]), ",") != "T1105" || strings.Join(toStrings(last["mbc_ids"]), ",") != "C0052" {
		t.Fatalf("attack/mbc ids (empty ids are dropped): %v", last)
	}
	if c["capa_version"] != "capa 9.4.0" || !strings.HasPrefix(c["rules_path_digest"].(string), "sha256:") {
		t.Fatalf("capa_version / rules_path_digest: %v %v", c["capa_version"], c["rules_path_digest"])
	}
	argv := toStrings(c["argv"])
	if argv[1] != "-r" || argv[2] != "/tmp/rsdd/capa-rules" || argv[3] != "-j" || argv[4] != "/tmp/rsdd/work/input/binary.bin" {
		t.Fatalf("canonical argv: %v", argv)
	}
	for _, k := range []string{"input", "isolation", "limitations", "errors"} {
		if _, ok := doc[k]; !ok {
			t.Errorf("envelope key %q missing", k)
		}
	}
	if caps := asMap(t, c["caps"]); caps["max_capabilities"] != float64(500) || caps["timeout"] != float64(300) {
		t.Errorf("default caps: %v", caps)
	}
}

func toStrings(v any) []string {
	var out []string
	for _, e := range v.([]any) {
		out = append(out, e.(string))
	}
	return out
}

// T12, T12-fast (CONTAINMENT): the isolation block records the network-denied, no-execution profile.
func TestRunRecordsIsolationProfile(t *testing.T) {
	r := newRig(t)
	if code, _, stderr := r.run(r.args("ev")...); code != 0 {
		t.Fatalf("code %d: %s", code, stderr)
	}
	iso := asMap(t, r.evidence("ev")["isolation"])
	profile := asMap(t, iso["profile"])
	if profile["name"] != "bubblewrap-capa-offline" || profile["network_access"] != false || profile["target_execution"] != false {
		t.Fatalf("profile: %v", profile)
	}
	if launcher := asMap(t, iso["launcher"]); !strings.HasSuffix(launcher["path"].(string), "/bin/bwrap") {
		t.Fatalf("launcher: %v", launcher)
	}
}

// T3: two runs over the same input, capa and rules publish byte-identical evidence.
func TestRunEvidenceIsDeterministic(t *testing.T) {
	r := newRig(t)
	for _, name := range []string{"a", "b"} {
		if code, _, stderr := r.run(r.args(name)...); code != 0 {
			t.Fatalf("code %d: %s", code, stderr)
		}
	}
	a, _ := os.ReadFile(filepath.Join(r.output("a"), "capa-evidence.v1.json"))
	b, _ := os.ReadFile(filepath.Join(r.output("b"), "capa-evidence.v1.json"))
	if len(a) == 0 || string(a) != string(b) {
		t.Fatalf("evidence differs between runs:\n%s\n%s", a, b)
	}
}

// T4, T4-fast: the capability cap bounds the list, sets truncated and records the limitation.
func TestRunCapabilityCapTruncatesLoudly(t *testing.T) {
	r := newRig(t)
	if code, _, stderr := r.run(r.args("ev", "--max-capabilities", "1")...); code != 0 {
		t.Fatalf("code %d: %s", code, stderr)
	}
	doc := r.evidence("ev")
	c := asMap(t, doc["capabilities"])
	if c["total_sampled"] != float64(1) || c["total_count"] != float64(3) || c["truncated"] != true {
		t.Fatalf("cap not enforced: %v", c)
	}
	want := "inventory truncated: capability cap 1 reached (total_count=3)"
	if lims := toStrings(doc["limitations"]); lims[len(lims)-1] != want {
		t.Fatalf("limitation %q, got %v", want, lims)
	}
}

// T8: an existing output path is refused fail-closed (exit 2) and nothing is published.
func TestRunRefusesExistingOutput(t *testing.T) {
	r := newRig(t)
	if err := os.Mkdir(r.output("taken"), 0o755); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := r.run(r.args("taken")...)
	if code != cli.ExitUsage || stderr != "corroborate-capa: output must be a new non-colliding path\n" || r.published("taken") {
		t.Fatalf("code %d stderr %q published %v", code, stderr, r.published("taken"))
	}
}

// T9, T10, T11, T15b: every --rules rejection is fail-closed, in the legacy order and wording.
func TestRunRulesDirRejections(t *testing.T) {
	r := newRig(t)
	missing := filepath.Join(r.root, "nope")
	link := filepath.Join(r.root, "rules-link")
	if err := os.Symlink(r.rules, link); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(r.root, "empty-rules")
	stray := filepath.Join(r.root, "stray")
	for _, d := range []string{empty, stray} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	r.write(filepath.Join(stray, "ci.yml"), "# stray\n", 0o644)
	file := filepath.Join(r.root, "rules-file")
	r.write(file, "x", 0o644)
	cases := []struct{ name, rules, want string }{
		{"T9 missing", missing, "--rules path does not exist: " + missing},
		{"T10 symlink", link, "--rules must not be a symlink (symlink-to-rules-dir is rejected to prevent redirection to a sensitive path): " + link},
		{"not a directory", file, "--rules is not a directory: " + file},
		{"T11 no yml", empty, "--rules directory does not appear to be a capa-rules directory (found 0 .yml files; expected ≥ 50 or a known structural subdir like nursery/, lib/, host-interaction/): " + empty},
		{"T15b stray yml", stray, "--rules directory does not appear to be a capa-rules directory (found 1 .yml files; expected ≥ 50 or a known structural subdir like nursery/, lib/, host-interaction/): " + stray},
	}
	for i, c := range cases {
		out := "out" + string(rune('a'+i))
		code, _, stderr := r.run(r.input0(out, c.rules)...)
		if code != cli.ExitUsage || stderr != "corroborate-capa: "+c.want+"\n" || r.published(out) {
			t.Errorf("%s: code %d stderr %q", c.name, code, stderr)
		}
		if _, err := os.Stat(r.output(out)); err == nil {
			t.Errorf("%s: output directory was created", c.name)
		}
	}
}

func (r *rig) input0(out, rules string) []string {
	a := r.args(out)
	for i, v := range a {
		if v == r.rules {
			a[i] = rules
		}
	}
	return a
}

// T13: the published analysis manifest validates and verifies against the published tree.
func TestRunManifestValidatesAndVerifies(t *testing.T) {
	r := newRig(t)
	if code, _, stderr := r.run(r.args("ev")...); code != 0 {
		t.Fatalf("code %d: %s", code, stderr)
	}
	manifest := filepath.Join(r.output("ev"), "engine", "analysis-manifest.v1.json")
	for _, verb := range [][]string{{"validate", manifest}, {"verify", "--root", r.output("ev"), manifest}} {
		var err strings.Builder
		s := cli.Stdio{In: strings.NewReader(""), Out: &err, Err: &err, Env: func(string) string { return "" }, Cwd: r.root}
		if code := adapterManifest(verb, s); code != 0 {
			t.Fatalf("manifest %s: code %d: %s", verb[0], code, err.String())
		}
	}
}

// T14: a timeout still publishes evidence, status=failed, truncated and with a timeout limitation.
func TestRunTimeoutPublishesFailedEvidence(t *testing.T) {
	r := newRig(t)
	r.capaFile("sleep", "30")
	code, _, stderr := r.run(r.args("ev", "--timeout", "1")...)
	if code != cli.ExitOperational {
		t.Fatalf("code %d: %s", code, stderr)
	}
	doc := r.evidence("ev")
	if doc["status"] != "failed" || strings.Join(toStrings(doc["errors"]), ",") != "timeout" {
		t.Fatalf("status/errors: %v %v", doc["status"], doc["errors"])
	}
	if asMap(t, doc["capabilities"])["truncated"] != true {
		t.Error("capabilities.truncated must be true after a timeout")
	}
	lims := toStrings(doc["limitations"])
	if lims[len(lims)-1] != "capa run truncated: timeout reached — inventory is incomplete" {
		t.Errorf("limitations: %v", lims)
	}
	if want := "capa-evidence.v1: completed with issues (timeout) — see " + r.output("ev") + "/capa-evidence.v1.json\n"; stderr != want {
		t.Errorf("stderr %q, want %q", stderr, want)
	}
}

// A capa that exits non-zero is an analyzer error: evidence is published with status=failed, exit 1.
func TestRunAnalyzerExitIsRecorded(t *testing.T) {
	r := newRig(t)
	r.capaOutput("")
	r.capaFile("rc", "3")
	code, _, _ := r.run(r.args("ev")...)
	doc := r.evidence("ev")
	if code != 1 || doc["status"] != "failed" || strings.Join(toStrings(doc["errors"]), ",") != "analyzer-exit:3" {
		t.Fatalf("code %d doc %v", code, doc)
	}
	if c := asMap(t, doc["capabilities"]); c["total_count"] != float64(0) || c["truncated"] != false {
		t.Errorf("an unanalyzable binary is an empty inventory: %v", c)
	}
}

// Malformed capa JSON on exit 0 is an explicit error with the decoder's message, never an empty inventory.
func TestRunMalformedJSONIsAnError(t *testing.T) {
	r := newRig(t)
	r.capaOutput("not json at all {{{{")
	code, _, _ := r.run(r.args("ev")...)
	doc := r.evidence("ev")
	want := "malformed JSON in capa stdout: Expecting value: line 1 column 1 (char 0)"
	if code != 1 || doc["status"] != "failed" || strings.Join(toStrings(doc["errors"]), ",") != want {
		t.Fatalf("code %d errors %v", code, doc["errors"])
	}
}

// Zero capabilities (exit 0, empty rules) is a valid complete inventory.
func TestRunZeroCapabilitiesIsComplete(t *testing.T) {
	for _, body := range []string{`{"rules": {}}`, ``, `null`, `{}`} {
		r := newRig(t)
		r.capaOutput(body)
		if code, _, stderr := r.run(r.args("ev")...); code != 0 {
			t.Fatalf("%q: code %d: %s", body, code, stderr)
		}
		doc := r.evidence("ev")
		if doc["status"] != "complete" || asMap(t, doc["capabilities"])["total_count"] != float64(0) {
			t.Errorf("%q: %v", body, doc)
		}
	}
}

// T16b: a non-dict "rules" is schema drift, recorded as a limitation, not an AttributeError.
func TestRunNonDictRulesIsSchemaDrift(t *testing.T) {
	r := newRig(t)
	r.capaOutput(`{"rules": ["list"]}`)
	if code, _, stderr := r.run(r.args("ev")...); code != 0 {
		t.Fatalf("code %d: %s", code, stderr)
	}
	lims := toStrings(r.evidence("ev")["limitations"])
	if lims[len(lims)-1] != "capa JSON 'rules' is not a dict (schema drift): 'list'" {
		t.Fatalf("limitations: %v", lims)
	}
}

// A document the legacy tool cannot handle (a traceback there) is an internal error, exit 1, no evidence.
func TestRunStructuralDriftCrashesCleanly(t *testing.T) {
	r := newRig(t)
	r.capaOutput(`{"rules": {"x": 3}}`)
	code, _, stderr := r.run(r.args("ev")...)
	if code != cli.ExitOperational || !strings.HasPrefix(stderr, "corroborate-capa: internal error: ") || r.published("ev") {
		t.Fatalf("code %d stderr %q", code, stderr)
	}
	if _, err := os.Stat(filepath.Join(r.outDir, ".ev.stage")); err == nil {
		t.Error("the stage directory must be removed")
	}
}

// The stage directory is removed on every failure after it was created.
func TestRunCleansStageOnFailure(t *testing.T) {
	r := newRig(t)
	r.write(r.input(), "x", 0o644)
	if err := os.Remove(r.input()); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := r.run(r.args("ev")...)
	if code != cli.ExitUsage || stderr != "corroborate-capa: source cannot be opened safely\n" {
		t.Fatalf("code %d stderr %q", code, stderr)
	}
	entries, _ := os.ReadDir(r.outDir)
	if len(entries) != 0 {
		t.Errorf("output directory must stay empty, found %d entries", len(entries))
	}
}

// Input validation order: caps first, then the output path, parent, collision, manifest-cli.
func TestRunValidationOrderAndMessages(t *testing.T) {
	r := newRig(t)
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"timeout", r.args("e", "--timeout", "0"), "--timeout must be >= 1"},
		{"max caps", r.args("e", "--max-capabilities", "-3"), "--max-capabilities must be >= 1"},
		{"dotdot", []string{"--input", r.input(), "--output", r.outDir + "/../x", "--manifest-cli", r.input()}, "output must be a canonical path"},
		{"backslash", []string{"--input", r.input(), "--output", r.outDir + `/a\b`, "--manifest-cli", r.input()}, "output must be a canonical path"},
		{"parent missing", []string{"--input", r.input(), "--output", r.root + "/nodir/x", "--manifest-cli", r.input()}, "[Errno 2] No such file or directory: '" + r.root + "/nodir'"},
		{"manifest missing", []string{"--input", r.input(), "--output", r.output("m"), "--manifest-cli", "/nonexist"}, "[Errno 2] No such file or directory: '/nonexist'"},
	}
	for _, c := range cases {
		code, _, stderr := r.run(c.args...)
		if code != cli.ExitUsage || stderr != "corroborate-capa: "+c.want+"\n" {
			t.Errorf("%s: code %d stderr %q", c.name, code, stderr)
		}
	}
}

// A missing bwrap or capa is an AdapterError (exit 2), not a silent success.
func TestRunMissingToolsAreFailClosed(t *testing.T) {
	r := newRig(t)
	r.extraEv = []string{"PATH=" + r.bin}
	code, _, stderr := r.run(r.args("ev")...)
	if code != cli.ExitUsage || stderr != "corroborate-capa: PATH-selected capa is missing\n" {
		t.Fatalf("code %d stderr %q", code, stderr)
	}
}

// A configured RSDD_CAPA that does not exist is named in the error.
func TestRunConfiguredToolMustExist(t *testing.T) {
	r := newRig(t)
	r.extraEv = []string{"RSDD_CAPA=/nonexistent/capa"}
	code, _, stderr := r.run(r.args("ev")...)
	if code != cli.ExitUsage || stderr != "corroborate-capa: configured capa path does not exist: /nonexistent/capa\n" {
		t.Fatalf("code %d stderr %q", code, stderr)
	}
}

// The version probe falls back to "unknown" when capa prints nothing.
func TestRunVersionFallsBackToUnknown(t *testing.T) {
	r := newRig(t)
	r.capaFile("version", "")
	if code, _, stderr := r.run(r.args("ev")...); code != 0 {
		t.Fatalf("code %d: %s", code, stderr)
	}
	if v := asMap(t, r.evidence("ev")["capabilities"])["capa_version"]; v != "unknown" {
		t.Fatalf("capa_version %v", v)
	}
}
