package parity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRunCaseStreams(t *testing.T) {
	tests := []struct {
		name         string
		legacy, rsdd []string
		status       Status
		kind         string   // expected problem kind, "" when none
		contains     []string // substrings expected in the problem text
		absent       []string // substrings that must NOT appear
	}{
		{"equal", []string{"out=hi", "err=warn", "exit=2"}, []string{"out=hi", "err=warn", "exit=2"}, StatusEqual, "", nil, nil},
		{"stdout only", []string{"out=abcX"}, []string{"out=abcY"}, StatusFailed, KindUndeclared,
			[]string{"stdout differs at byte offset 3 (line 1)"}, []string{"stderr", "exit differs"}},
		{"stderr only", []string{"err=one"}, []string{"err=two"}, StatusFailed, KindUndeclared,
			[]string{"stderr differs at byte offset 0"}, []string{"stdout differs", "exit differs"}},
		{"exit only", []string{"exit=0"}, []string{"exit=3"}, StatusFailed, KindUndeclared,
			[]string{"exit differs: legacy 0, rsdd 3"}, []string{"stdout differs", "stderr differs"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t)
			res, _ := r.run(tt.legacy, tt.rsdd, nil)
			if res.Status != tt.status {
				t.Fatalf("status = %s, want %s; problems:\n%s", res.Status, tt.status, joined(res.Problems))
			}
			if tt.kind == "" && len(res.Problems) != 0 {
				t.Fatalf("unexpected problems: %s", joined(res.Problems))
			}
			if tt.kind != "" && !hasKind(res.Problems, tt.kind) {
				t.Fatalf("want kind %s, got:\n%s", tt.kind, joined(res.Problems))
			}
			for _, s := range tt.contains {
				if !strings.Contains(joined(res.Problems), s) {
					t.Errorf("problem text lacks %q:\n%s", s, joined(res.Problems))
				}
			}
			for _, s := range tt.absent {
				if strings.Contains(joined(res.Problems), s) {
					t.Errorf("problem text should not mention %q:\n%s", s, joined(res.Problems))
				}
			}
		})
	}
}

func TestDiffIsBounded(t *testing.T) {
	r := newRig(t)
	long := strings.Repeat("a", 5000)
	res, _ := r.run([]string{"out=" + long + "L"}, []string{"out=" + long + "R"}, nil)
	if res.Status != StatusFailed {
		t.Fatalf("status = %s", res.Status)
	}
	if n := len(joined(res.Problems)); n > 600 {
		t.Fatalf("diff output is %d bytes, want it bounded", n)
	}
	if !strings.Contains(joined(res.Problems), "offset 5000") {
		t.Fatalf("offset missing: %s", joined(res.Problems))
	}
}

func TestDiffLineNumber(t *testing.T) {
	r := newRig(t)
	res, _ := r.run([]string{"out=a\nb\nc1"}, []string{"out=a\nb\nc2"}, nil)
	if !strings.Contains(joined(res.Problems), "(line 3)") {
		t.Fatalf("line number missing: %s", joined(res.Problems))
	}
}

func TestDeclaredDivergenceHonoured(t *testing.T) {
	r := newRig(t)
	files := map[string]string{"intended.json": `[{"field":"stdout","reason":"rsdd drops the trailing banner"}]`}
	res, _ := r.run([]string{"out=a"}, []string{"out=b"}, files)
	if res.Status != StatusDeclared || len(res.Problems) != 0 {
		t.Fatalf("status = %s, problems:\n%s", res.Status, joined(res.Problems))
	}
}

func TestDeclaredButOtherStreamDiverges(t *testing.T) {
	r := newRig(t)
	files := map[string]string{"intended.json": `[{"field":"stdout","reason":"documented"}]`}
	res, _ := r.run([]string{"out=a", "exit=0"}, []string{"out=b", "exit=1"}, files)
	if res.Status != StatusFailed || !hasKind(res.Problems, KindUndeclared) || !strings.Contains(joined(res.Problems), "exit differs") {
		t.Fatalf("undeclared exit divergence must fail: %s %s", res.Status, joined(res.Problems))
	}
}

func TestDeclarationWithoutReasonFails(t *testing.T) {
	for _, reason := range []string{`""`, `"   "`} {
		r := newRig(t)
		files := map[string]string{"intended.json": `[{"field":"stdout","reason":` + reason + `}]`}
		res, c := r.run([]string{"out=a"}, []string{"out=b"}, files)
		if !hasKind(c.Problems, KindNoReason) {
			t.Fatalf("reason %s: load did not flag it: %v", reason, c.Problems)
		}
		if res.Status != StatusFailed || !hasKind(res.Problems, KindNoReason) {
			t.Fatalf("reason %s: status %s, problems:\n%s", reason, res.Status, joined(res.Problems))
		}
	}
}

func TestDeclarationWithBadFieldFails(t *testing.T) {
	r := newRig(t)
	files := map[string]string{"intended.json": `[{"field":"stdin","reason":"x"}]`}
	res, _ := r.run([]string{"out=a"}, []string{"out=a"}, files)
	if res.Status != StatusFailed || !hasKind(res.Problems, KindSpecInvalid) {
		t.Fatalf("bad field must be spec-invalid: %s %s", res.Status, joined(res.Problems))
	}
}

func TestStaleDeclarationFails(t *testing.T) {
	r := newRig(t)
	files := map[string]string{"intended.json": `[{"field":"stderr","reason":"was different once"}]`}
	res, _ := r.run([]string{"out=a"}, []string{"out=a"}, files)
	if res.Status != StatusFailed || !hasKind(res.Problems, KindStale) || !strings.Contains(joined(res.Problems), "stderr") {
		t.Fatalf("stale declaration must fail: %s %s", res.Status, joined(res.Problems))
	}
}

func TestTimeoutIsTypedAndDoesNotHang(t *testing.T) {
	for _, side := range []string{"legacy", "rsdd"} {
		r := newRig(t)
		r.runner.Cfg.Timeout = 300 * time.Millisecond
		legacy, rsdd := []string{"out=a"}, []string{"out=a"}
		if side == "legacy" {
			legacy = []string{"sleep=30"}
		} else {
			rsdd = []string{"sleep=30"}
		}
		start := time.Now()
		res, _ := r.run(legacy, rsdd, nil)
		if el := time.Since(start); el > 8*time.Second {
			t.Fatalf("%s: timeout took %s: the runner hung on the child's pipe", side, el)
		}
		if res.Status != StatusFailed || !hasKind(res.Problems, KindTimeout) || !strings.Contains(joined(res.Problems), side) {
			t.Fatalf("%s: want typed timeout, got %s %s", side, res.Status, joined(res.Problems))
		}
	}
}

func TestOutputCapIsTyped(t *testing.T) {
	old := maxOutput
	maxOutput = 8
	t.Cleanup(func() { maxOutput = old })
	r := newRig(t)
	res, _ := r.run([]string{"out=0123456789abcdef"}, []string{"out=0123456789abcdef"}, nil)
	if res.Status != StatusFailed || !hasKind(res.Problems, KindOutputTooBig) {
		t.Fatalf("want output-too-large, got %s %s", res.Status, joined(res.Problems))
	}
}

func TestExecFailureIsTyped(t *testing.T) {
	r := newRig(t)
	r.addRaw("c", `{"legacy":["toolbelt/missing.sh"],"rsdd":["out=a"]}`, map[string]string{})
	res := r.runner.RunCase(r.load()[0], "")
	if res.Status != StatusFailed || !hasKind(res.Problems, KindExecFailed) {
		t.Fatalf("want exec-failed, got %s %s", res.Status, joined(res.Problems))
	}
}

func TestSandboxPathIdenticalAndWiped(t *testing.T) {
	r := newRig(t)
	// Same absolute cwd/HOME/TMPDIR in both runs, with no normalization.
	res, _ := r.run([]string{"ctx"}, []string{"ctx"}, nil)
	if res.Status != StatusEqual {
		t.Fatalf("sandbox reuse must give identical absolute paths: %s %s", res.Status, joined(res.Problems))
	}
	// And the sandbox is wiped between the runs: legacy's file is gone for rsdd.
	r2 := newRig(t)
	files := map[string]string{"intended.json": `[{"field":"stdout","reason":"legacy sees its own leak, rsdd must not"}]`}
	res, _ = r2.run(
		[]string{"touch={{sandbox}}/leak", "exists={{sandbox}}/leak"},
		[]string{"exists={{sandbox}}/leak"}, files)
	if res.Status != StatusDeclared {
		t.Fatalf("rsdd saw legacy's leftover (sandbox not wiped) or legacy lost its own file: %s %s", res.Status, joined(res.Problems))
	}
}

func TestEnvIsFixedAndMinimal(t *testing.T) {
	r := newRig(t)
	t.Setenv("SOME_AMBIENT_VAR", "leaky")
	res, _ := r.run(
		[]string{"env=TZ", "env=LC_ALL", "env=SOME_AMBIENT_VAR", "env=FOO"},
		[]string{"out=UTCC", "env=FOO"}, nil)
	// legacy prints "UTC" "C" "" and FOO (unset: ""), rsdd prints "UTCC"+"": equal only if
	// the ambient var did not leak and TZ/LC_ALL are fixed.
	if res.Status != StatusEqual {
		t.Fatalf("fixed env violated: %s %s", res.Status, joined(res.Problems))
	}
}

func TestSpecEnvAndStdinAndInputs(t *testing.T) {
	r := newRig(t)
	r.addRaw("c", `{"legacy":["toolbelt/fake.sh","env=FOO","cat","catf={{input}}/a.txt"],"rsdd":["env=FOO","cat","catf={{input}}/a.txt"],"env":{"FOO":"bar"}}`,
		map[string]string{"stdin": "from-stdin", "inputs/a.txt": "from-input"})
	c := r.load()[0]
	res := r.runner.RunCase(c, "")
	if res.Status != StatusEqual {
		t.Fatalf("%s %s", res.Status, joined(res.Problems))
	}
	// The case's own inputs/ must never be modified by a run.
	r.addRaw("d", `{"legacy":["toolbelt/fake.sh","touch={{input}}/a.txt"],"rsdd":["out="]}`, map[string]string{"inputs/a.txt": "orig"})
	cases := r.load()
	for _, cc := range cases {
		r.runner.RunCase(cc, "")
	}
	b, err := os.ReadFile(filepath.Join(r.specs, "d", "inputs", "a.txt"))
	if err != nil || string(b) != "orig" {
		t.Fatalf("a run modified the case's inputs/: %q %v", b, err)
	}
}

func TestSpecValidation(t *testing.T) {
	tests := []struct {
		name, spec, want string
		files            map[string]string
	}{
		{"unknown placeholder", `{"legacy":["a.sh","{{nope}}"],"rsdd":["x"]}`, "unknown placeholder", nil},
		{"corpus placeholder without flag", `{"legacy":["a.sh","{{corpus}}"],"rsdd":["x"]}`, `"corpus": true is not set`, nil},
		{"corpus flag without placeholder", `{"legacy":["a.sh"],"rsdd":["x"],"corpus":true}`, "no {{corpus}} placeholder", nil},
		{"absolute legacy", `{"legacy":["/bin/true"],"rsdd":["x"]}`, "relative to the legacy kit root", nil},
		{"escaping legacy", `{"legacy":["../x.sh"],"rsdd":["x"]}`, "relative to the legacy kit root", nil},
		{"empty rsdd", `{"legacy":["a.sh"],"rsdd":[]}`, "rsdd argv is empty", nil},
		{"empty legacy", `{"rsdd":["x"]}`, "legacy argv is empty", nil},
		{"reserved env", `{"legacy":["a.sh"],"rsdd":["x"],"env":{"HOME":"/x"}}`, "fixed by the runner", nil},
		{"unknown field", `{"legacy":["a.sh"],"rsdd":["x"],"bogus":1}`, "unknown field", nil},
		{"input without inputs dir", `{"legacy":["a.sh","{{input}}"],"rsdd":["x"]}`, "no inputs/ directory", nil},
		{"not json", `nope`, "spec.json", nil},
		{"trailing data", `{"legacy":["a.sh"],"rsdd":["x"]} {}`, "trailing data", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t)
			files := tt.files
			if files == nil {
				files = map[string]string{}
			}
			r.addRaw("c", tt.spec, files)
			c := r.load()[0]
			if !hasKind(c.Problems, KindSpecInvalid) || !strings.Contains(joined(c.Problems), tt.want) {
				t.Fatalf("want spec-invalid containing %q, got %v", tt.want, c.Problems)
			}
			if res := r.runner.RunCase(c, ""); res.Status != StatusFailed {
				t.Fatalf("an invalid spec must fail, got %s", res.Status)
			}
		})
	}
}

func TestMissingSpecJSON(t *testing.T) {
	r := newRig(t)
	r.addRaw("c", "", map[string]string{"stdin": "x"})
	c := r.load()[0]
	if !hasKind(c.Problems, KindSpecInvalid) {
		t.Fatalf("a case dir without spec.json must be invalid: %v", c.Problems)
	}
}

func TestLoadCasesTypedEmptyAndAbsent(t *testing.T) {
	dir := t.TempDir()
	if _, err := LoadCases(dir); err == nil || !strings.Contains(err.Error(), "empty-input: 0 parity specs") {
		t.Fatalf("empty dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "stray-file"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCases(dir); err == nil || !strings.Contains(err.Error(), "empty-input") {
		t.Fatalf("a dir with only files is still empty-input: %v", err)
	}
	if _, err := LoadCases(filepath.Join(dir, "nope")); err == nil || !strings.Contains(err.Error(), "absent-input") {
		t.Fatalf("absent dir: %v", err)
	}
}

func TestNewRunnerDegraded(t *testing.T) {
	needSh(t)
	r := newRig(t)
	file := filepath.Join(t.TempDir(), "afile")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		cfg  Config
		want string
	}{
		{"legacy unset", Config{Bin: r.bin, Work: r.work}, "absent-input"},
		{"legacy missing", Config{LegacyRoot: filepath.Join(r.work, "nope"), Bin: r.bin, Work: r.work}, "absent-input"},
		{"legacy not a dir", Config{LegacyRoot: file, Bin: r.bin, Work: r.work}, "absent-input"},
		{"bin unset", Config{LegacyRoot: r.root, Work: r.work}, "absent-input"},
		{"bin missing", Config{LegacyRoot: r.root, Bin: filepath.Join(r.work, "nope"), Work: r.work}, "absent-input"},
		{"bin not executable", Config{LegacyRoot: r.root, Bin: file, Work: r.work}, "absent-input"},
		{"work unset", Config{LegacyRoot: r.root, Bin: r.bin}, "absent-input"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rn, err := NewRunner(tt.cfg)
			d, ok := err.(*Degraded)
			if rn != nil || !ok || d.Kind != tt.want {
				t.Fatalf("want *Degraded{%s}, got %v %v", tt.want, rn, err)
			}
			if !strings.HasPrefix(err.Error(), tt.want+": ") {
				t.Fatalf("error text must lead with the kind: %q", err.Error())
			}
		})
	}
}

func TestConfigFromEnv(t *testing.T) {
	env := map[string]string{"RSDD_PARITY_LEGACY": "/k", "RSDD_BIN": "/b", "RSDD_PARITY_TIMEOUT": "7s"}
	cfg, err := ConfigFromEnv(func(k string) string { return env[k] }, "/w")
	if err != nil || cfg.LegacyRoot != "/k" || cfg.Bin != "/b" || cfg.Work != "/w" || cfg.Timeout != 7*time.Second {
		t.Fatalf("%+v %v", cfg, err)
	}
	cfg, err = ConfigFromEnv(func(string) string { return "" }, "/w")
	if err != nil || cfg.LegacyRoot != "" || cfg.Timeout <= 0 {
		t.Fatalf("unset env must leave roots empty (NewRunner types it) and use a default timeout: %+v %v", cfg, err)
	}
	for _, bad := range []string{"soon", "-1s", "0s"} {
		_, err = ConfigFromEnv(func(k string) string {
			if k == "RSDD_PARITY_TIMEOUT" {
				return bad
			}
			return ""
		}, "/w")
		if err == nil {
			t.Fatalf("timeout %q must be rejected", bad)
		}
	}
}

func TestNewRunnerTimeout(t *testing.T) {
	r := newRig(t)
	for _, tt := range []struct {
		in, want time.Duration
	}{
		{0, defaultTimeout},
		{-time.Second, defaultTimeout},
		{time.Nanosecond, time.Nanosecond},
		{5 * time.Second, 5 * time.Second},
	} {
		rn, err := NewRunner(Config{LegacyRoot: r.root, Bin: r.bin, Work: r.work, Timeout: tt.in})
		if err != nil {
			t.Fatal(err)
		}
		if rn.Cfg.Timeout != tt.want {
			t.Fatalf("Timeout %s: got %s, want %s (only a non-positive timeout takes the default)", tt.in, rn.Cfg.Timeout, tt.want)
		}
	}
}

func TestClip(t *testing.T) {
	for _, tt := range []struct {
		s    string
		n    int
		want string
	}{
		{"abc", 4, "abc"},
		{"abcd", 4, "abcd"},
		{"abcde", 4, "abcd..."},
		{"", 0, ""},
	} {
		if got := clip(tt.s, tt.n); got != tt.want {
			t.Fatalf("clip(%q, %d) = %q, want %q", tt.s, tt.n, got, tt.want)
		}
	}
}

func TestEffectLabelsTreesOnlyWhenThereAreSeveral(t *testing.T) {
	r := newRig(t)
	for _, name := range []string{"input", "corpus"} {
		for _, d := range []string{r.runner.pristine(), r.runner.sandbox()} {
			if err := os.MkdirAll(filepath.Join(d, name), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(r.runner.sandbox(), name, "new.txt"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	one, err := r.runner.effect([]treeSpec{{name: "corpus"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(one) == 0 || strings.Contains(string(one), "[corpus]") {
		t.Fatalf("a single tree's effect is unlabelled: %q", one)
	}
	two, err := r.runner.effect([]treeSpec{{name: "input"}, {name: "corpus"}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(two), "[input]\n") || !strings.Contains(string(two), "\n[corpus]\n") {
		t.Fatalf("several trees label each part: %q", two)
	}
}
