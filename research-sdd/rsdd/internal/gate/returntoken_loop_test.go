package gate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Loop-evidence scope of the return-token gate (kit issues #2792, #2841): a session is held to a continuation token,
// and told which one to copy, only when its transcript shows it ran the research loop. A target that merely has a
// RESEARCH-STATE file (the kit repository is one) is not evidence.
//
//	RTG-LOOP-EVIDENCE  TestNonLoopSessionIsNeitherHeldNorOfferedAToken, TestLoopSessionWithoutATokenIsStillBlocked,
//	                   TestEvidenceNamingAnotherTargetIsNotEvidence
//	RTG-EVIDENCE-READ  TestUnreadableLoopEvidenceIsTyped

// statusProbe makes the stub status script record that it ran, so a test can prove the gate never asked it for a token.
func (r *rig) statusProbe() string {
	ran := filepath.Join(r.root, "status-ran")
	r.status("echo ran >> '" + ran + "'; printf '%s\\n' 'NEXT | high | x' '" + nextLine + "'")
	return ran
}

// session writes a transcript of the given extra lines followed by a final report without a token.
func (r *rig) session(name string, lines ...string) string {
	r.t.Helper()
	body, err := os.ReadFile(r.rawTranscript("notoken.jsonl"))
	if err != nil {
		r.t.Fatal(err)
	}
	p := filepath.Join(r.root, "sessions", name+".jsonl")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"+string(body)), 0o644); err != nil {
		r.t.Fatal(err)
	}
	return p
}

func toolUse(name, key, val string) string {
	return `{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":` + jsonStr(name) + `,"input":{` + jsonStr(key) + `:` + jsonStr(val) + `}}]}}`
}

func TestNonLoopSessionIsNeitherHeldNorOfferedAToken(t *testing.T) {
	for _, name := range []string{"notoken.jsonl", "mismatch.jsonl", "final-has-none.jsonl", "unavailable-line-only.jsonl", "override-empty.jsonl"} {
		r := newRig(t, "corpus-next") // a corpus with a RESEARCH-STATE and an open gap: the old gate offered it
		ran := r.statusProbe()
		res := r.gate("s-nonloop", r.rawTranscript(name))
		wantAllow(t, "non-loop "+name, res, "no-loop-session")
		if strings.Contains(res.err, "return-token: ") || strings.Contains(res.err, "next: ") {
			t.Errorf("%s: a non-loop session was offered a token on stderr: %q", name, res.err)
		}
		if _, err := os.Stat(ran); err == nil {
			t.Errorf("%s: the status instrument was run for a session that never ran the loop", name)
		}
		if len(r.markers()) != 0 {
			t.Errorf("%s: a block-once marker was written for a session that was not blocked: %v", name, r.markers())
		}
	}
	// the same final reports with a loop-evidence line in front are still judged (the existing behaviour, pinned below)
	r := newRig(t, "corpus-next")
	wantBlock(t, "same report, loop session", r.gate("s-loop", r.transcript("notoken.jsonl")), "missing", nextLine)
}

func TestLoopSessionWithoutATokenIsStillBlocked(t *testing.T) {
	for _, tc := range []struct{ name, line string }{
		{"status --next", toolUse("Bash", "command", `bash "$KIT/toolbelt/research-sdd-status.sh" "$T" --next --emit-token`)},
		{"rsdd status show", toolUse("Bash", "command", "rsdd status show . --next")},
		{"block write", toolUse("Write", "file_path", "{{corpus}}/blocks/x-block7.md")},
		{"state write", toolUse("Edit", "file_path", "{{corpus}}/RESEARCH-STATE.md")},
		{"skill", toolUse("Skill", "skill", "research-sdd")},
		{"slash command", `{"type":"user","message":{"role":"user","content":"<command-message>research-sdd</command-message>\n<command-name>/research-sdd</command-name>"}}`},
	} {
		r := newRig(t, "corpus-next")
		line := strings.ReplaceAll(tc.line, "{{corpus}}", r.corpus)
		res := r.gate("s-"+tc.name, r.session("loop", line))
		wantBlock(t, "loop session ("+tc.name+")", res, "missing", "no continuation token", nextLine)
	}
}

func TestEvidenceNamingAnotherTargetIsNotEvidence(t *testing.T) {
	for _, tc := range []struct{ name, line string }{
		{"status run on another corpus", toolUse("Bash", "command", "bash /k/toolbelt/research-sdd-status.sh /somewhere/else-research --next")},
		{"block written in another corpus", toolUse("Write", "file_path", "/somewhere/else-research/blocks/x-block1.md")},
		{"a grep over the script", toolUse("Bash", "command", `grep -n -- '--next' research-sdd/toolbelt/research-sdd-status.sh`)},
		{"a fixture state file", toolUse("Write", "file_path", "{{corpus}}/tests/fixtures/c/RESEARCH-STATE.md")},
	} {
		r := newRig(t, "corpus-next")
		tc.line = strings.ReplaceAll(tc.line, "{{corpus}}", r.corpus)
		ran := r.statusProbe()
		wantAllow(t, tc.name, r.gate("s-other", r.session("other", tc.line)), "no-loop-session")
		if _, err := os.Stat(ran); err == nil {
			t.Errorf("%s: the status instrument was run", tc.name)
		}
	}
}

func TestUnreadableLoopEvidenceIsTyped(t *testing.T) {
	// a directory where the transcript should be: opening works, reading cannot, so absence of evidence is unproven
	r := newRig(t, "corpus-next")
	ran := r.statusProbe()
	dir := filepath.Join(r.root, "a-dir")
	_ = os.MkdirAll(dir, 0o755)
	res := r.gate("s1", dir)
	wantAllow(t, "directory as transcript", res, "degraded (loop evidence unreadable: ")
	if strings.Contains(res.err, "no-loop-session") {
		t.Errorf("an unreadable transcript must not read as 'no loop': %q", res.err)
	}
	if _, err := os.Stat(ran); err == nil {
		t.Error("the status instrument was run although the evidence could not be read")
	}

	// a transcript whose only content is a line too long to inspect cannot prove the session was not a loop
	big := filepath.Join(r.root, "big.jsonl")
	if err := os.WriteFile(big, []byte(`{"type":"user","message":{"content":"`+strings.Repeat("x", 5<<20)+`"}}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res = r.gate("s1", big)
	wantAllow(t, "oversize line", res, "degraded (loop evidence incomplete: 1 transcript line(s) over 4194304 bytes were not inspected)")

	// an empty transcript has nothing to inspect: its own state, not 'no loop'
	empty := filepath.Join(r.root, "empty.jsonl")
	_ = os.WriteFile(empty, nil, 0o644)
	res = r.gate("s1", empty)
	wantAllow(t, "empty transcript", res, "degraded (loop evidence absent: the transcript has no lines)")

	// the pre-existing 'could not look at the transcript at all' states keep their wording
	wantAllow(t, "missing transcript", r.gate("s1", filepath.Join(r.root, "nope.jsonl")), "degraded (transcript unreadable: "+r.root+"/nope.jsonl)")
}
