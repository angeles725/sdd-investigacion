package loopevidence

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tool(name string, input map[string]any) string {
	b, _ := json.Marshal(map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant",
		"content": []any{map[string]any{"type": "tool_use", "id": "t1", "name": name, "input": input}}}})
	return string(b)
}

func bash(cmd string) string { return tool("Bash", map[string]any{"command": cmd}) }

func TestClassifyStatusRuns(t *testing.T) {
	for _, tc := range []struct {
		name, cmd string
		want      bool
	}{
		{"script with --next --emit-token", `bash /k/toolbelt/research-sdd-status.sh /t --next --emit-token`, true},
		{"quoted var path", `"$KIT/toolbelt/research-sdd-status.sh" "$T" --next`, true},
		{"after cd &&", `cd /t && research-sdd-status.sh . --next`, true},
		{"rsdd status show", `rsdd status show /t --next`, true},
		{"env assignment and timeout wrappers", `FOO=1 timeout 20 bash x/research-sdd-status.sh $T --emit-token`, true},
		{"command substitution", `out=$(bash x/research-sdd-status.sh /t --next)`, true},
		{"bash -c", `bash -c 'x/research-sdd-status.sh /t --next'`, true},
		{"kit-run wrapper", `bash tools/hooks/kit-run.sh toolbelt/research-sdd-status.sh /t --next`, true},
		{"second command of a pipeline", `echo go | bash x/research-sdd-status.sh /t --next | head -3`, true},
		{"grep over the script", `grep -n -- '--next' research-sdd/toolbelt/research-sdd-status.sh`, false},
		{"rg for the flag", `rg -n "emit-token" research-sdd/toolbelt/research-sdd-status.sh`, false},
		{"default mode is not a loop step", `bash research-sdd-status.sh /t`, false},
		{"echo of the command", `echo "research-sdd-status.sh /t --next"`, false},
		{"commit message", `git commit -m "fix research-sdd-status.sh --next"`, false},
		{"cat then flag word elsewhere", `cat research-sdd-status.sh; echo --next`, false},
		{"unrelated tool", `go test ./...`, false},
	} {
		_, ok := Classify([]byte(bash(tc.cmd)), Options{})
		if ok != tc.want {
			t.Errorf("%s: Classify(%q) = %v, want %v", tc.name, tc.cmd, ok, tc.want)
		}
	}
	ev, ok := Classify([]byte(bash(`bash x/research-sdd-status.sh /t --next`)), Options{})
	if !ok || ev.Kind != KindStatusRun || !strings.Contains(ev.Detail, "research-sdd-status.sh") {
		t.Errorf("evidence = %+v %v", ev, ok)
	}
}

func TestClassifyStatusRunTargetRelatedness(t *testing.T) {
	o := Options{Target: "/home/u/kit"}
	for _, tc := range []struct {
		cmd  string
		want bool
	}{
		{`bash s/research-sdd-status.sh /home/u/other --next`, false},
		{`bash s/research-sdd-status.sh /home/u/kit2 --next`, false}, // a path boundary, not a string prefix
		{`bash s/research-sdd-status.sh /home/u/kit --next`, true},
		{`bash s/research-sdd-status.sh /home/u/kit/corpus --next`, true},
		{`bash s/research-sdd-status.sh /home/u --next`, true}, // a parent of the target holds it
		{`bash s/research-sdd-status.sh . --next`, true},       // relative: cannot tell, counts
		{`bash s/research-sdd-status.sh "$T" --next`, true},
		{`bash /home/u/other/toolbelt/research-sdd-status.sh /home/u/kit --next`, true}, // the script path is not a target
	} {
		if _, ok := Classify([]byte(bash(tc.cmd)), o); ok != tc.want {
			t.Errorf("Classify(%q) = %v, want %v", tc.cmd, ok, tc.want)
		}
	}
}

func TestClassifyWrites(t *testing.T) {
	o := Options{Target: "/t"}
	for _, tc := range []struct {
		name, tool, key, path string
		want                  Kind
	}{
		{"block write", "Write", "file_path", "/t/blocks/niagara-block12.md", KindBlockWrite},
		{"bloque with slug", "Edit", "file_path", "/t/blocks/niagara-bloque3-intro.md", KindBlockWrite},
		{"pi lowercase tool, path key", "write", "path", "/t/blocks/x-block1.md", KindBlockWrite},
		{"multiedit", "MultiEdit", "file_path", "/t/blocks/x-block2.md", KindBlockWrite},
		{"state file", "Write", "file_path", "/t/RESEARCH-STATE.md", KindStateWrite},
		{"focus state file", "Edit", "file_path", "/t/RESEARCH-STATE-wifi.md", KindStateWrite},
		{"template is not state", "Write", "file_path", "/t/research-sdd/templates/RESEARCH-STATE.template.md", ""},
		{"fixture state is not state", "Write", "file_path", "/t/research-sdd/toolbelt/tests/fixtures/c/RESEARCH-STATE.md", ""},
		{"testdata block is not a block", "Write", "file_path", "/t/internal/testdata/x-block1.md", ""},
		{"plain markdown", "Write", "file_path", "/t/README.md", ""},
		{"a read is not a write", "Read", "file_path", "/t/blocks/x-block1.md", ""},
		{"another target", "Write", "file_path", "/elsewhere/blocks/x-block1.md", ""},
		{"a sibling with the same prefix", "Write", "file_path", "/t2/blocks/x-block1.md", ""},
	} {
		ev, ok := Classify([]byte(tool(tc.tool, map[string]any{tc.key: tc.path})), o)
		if tc.want == "" {
			if ok {
				t.Errorf("%s: unexpected evidence %+v", tc.name, ev)
			}
			continue
		}
		if !ok || ev.Kind != tc.want || ev.Detail != tc.path {
			t.Errorf("%s: got %+v %v, want kind %s", tc.name, ev, ok, tc.want)
		}
	}
	// a relative path resolves against the session cwd, which is the target: it counts
	if ev, ok := Classify([]byte(tool("Write", map[string]any{"file_path": "blocks/x-block1.md"})), o); !ok || ev.Kind != KindBlockWrite {
		t.Errorf("relative block path: %+v %v", ev, ok)
	}
}

func TestClassifySkillAndSlashCommand(t *testing.T) {
	for _, tc := range []struct {
		name, line string
		want       Kind
	}{
		{"skill tool", tool("Skill", map[string]any{"skill": "research-sdd"}), KindSkill},
		{"namespaced skill", tool("Skill", map[string]any{"skill": "kit:research-sdd"}), KindSkill},
		{"another skill", tool("Skill", map[string]any{"skill": "sdd-apply"}), ""},
		{"slash command string content", `{"type":"user","message":{"role":"user","content":"<command-message>research-sdd</command-message>\n<command-name>/research-sdd</command-name>"}}`, KindSlashCommand},
		{"slash command text block", `{"type":"user","message":{"content":[{"type":"text","text":"<command-name>/research-sdd</command-name>\n<command-args>x</command-args>"}]}}`, KindSlashCommand},
		{"another slash command", `{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}`, ""},
		{"assistant text that quotes the tag", `{"type":"assistant","message":{"content":[{"type":"text","text":"<command-name>/research-sdd</command-name>"}]}}`, ""},
		{"tool_result that quotes the tag", `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"<command-name>/research-sdd</command-name>"}]}}`, ""},
	} {
		ev, ok := Classify([]byte(tc.line), Options{})
		if tc.want == "" {
			if ok {
				t.Errorf("%s: unexpected evidence %+v", tc.name, ev)
			}
			continue
		}
		if !ok || ev.Kind != tc.want {
			t.Errorf("%s: got %+v %v, want %s", tc.name, ev, ok, tc.want)
		}
	}
}

func TestClassifyMalformedLinesAreNoEvidence(t *testing.T) {
	for _, l := range []string{"", "{not json", "null", `[1]`, `{"type":"assistant"}`, `{"type":"assistant","message":"research-sdd-status.sh --next"}`,
		`{"type":"assistant","message":{"content":"tool_use research-sdd-status.sh --next"}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":"research-sdd-status.sh --next"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":5}}]}}`,
		`{"type":"assistant","message":{"content":[7,"x",null]}}`} {
		if ev, ok := Classify([]byte(l), Options{}); ok {
			t.Errorf("Classify(%q) = %+v, want none", l, ev)
		}
	}
}

func TestScanReaderStopsAtTheFirstEvidenceAndCountsLines(t *testing.T) {
	in := `{"type":"user","message":{"content":"go"}}` + "\n" + bash("true") + "\n" + bash("bash s/research-sdd-status.sh /t --next") + "\n" + bash("bash s/research-sdd-status.sh /t --emit-token") + "\n"
	sc, err := ScanReader(strings.NewReader(in), Options{})
	if err != nil || !sc.Found || sc.First.Kind != KindStatusRun || sc.Lines != 3 {
		t.Errorf("scan = %+v err=%v", sc, err)
	}
	// no evidence: the whole stream is read, and the count says so (no-match, not empty)
	sc, err = ScanReader(strings.NewReader(`{"type":"user","message":{"content":"go"}}`+"\n"+bash("true")), Options{})
	if err != nil || sc.Found || sc.Lines != 2 || sc.Oversize != 0 {
		t.Errorf("no-match scan = %+v err=%v", sc, err)
	}
	// empty input is its own state: zero lines
	sc, err = ScanReader(strings.NewReader(""), Options{})
	if err != nil || sc.Found || sc.Lines != 0 {
		t.Errorf("empty scan = %+v err=%v", sc, err)
	}
	// a final line without a newline is still a line
	sc, _ = ScanReader(strings.NewReader(bash("bash s/research-sdd-status.sh /t --next")), Options{})
	if !sc.Found {
		t.Errorf("unterminated last line missed: %+v", sc)
	}
}

func TestScanReaderCountsOversizeLinesAndKeepsReading(t *testing.T) {
	big := `{"type":"user","message":{"content":"` + strings.Repeat("x", 300) + `"}}`
	in := big + "\n" + bash("bash s/research-sdd-status.sh /t --next") + "\n" + big
	sc, err := ScanReader(strings.NewReader(in), Options{MaxLineBytes: 200})
	if err != nil || !sc.Found || sc.Oversize != 1 {
		t.Errorf("scan = %+v err=%v (an oversize line must not hide a later line)", sc, err)
	}
	sc, _ = ScanReader(strings.NewReader(big+"\n"+big), Options{MaxLineBytes: 200})
	if sc.Found || sc.Oversize != 2 || sc.Lines != 2 {
		t.Errorf("all-oversize scan = %+v", sc)
	}
}

func TestScanTranscriptUnreadableIsTyped(t *testing.T) {
	dir := t.TempDir()
	if _, err := ScanTranscript(filepath.Join(dir, "missing.jsonl"), Options{}); !errors.Is(err, ErrUnreadable) {
		t.Errorf("missing file: %v", err)
	}
	if _, err := ScanTranscript(dir, Options{}); !errors.Is(err, ErrUnreadable) {
		t.Errorf("a directory is not a transcript: %v", err)
	}
	p := filepath.Join(dir, "t.jsonl")
	if err := os.WriteFile(p, []byte(bash("bash s/research-sdd-status.sh /t --next")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if sc, err := ScanTranscript(p, Options{}); err != nil || !sc.Found {
		t.Errorf("file scan = %+v err=%v", sc, err)
	}
}
