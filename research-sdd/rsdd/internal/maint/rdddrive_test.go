package maint

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func approveFake(t *testing.T) *fake {
	f := newFake()
	f.on("review status", 0, fixture(t, "status-collect.json"))
	f.on("review capture-result --lens risk", 0, fixture(t, "capture-pending.json")).barrier = 2
	f.on("review capture-result --lens resilience", 0, fixture(t, "capture-final-approved.json")).barrier = 2
	f.on("review acknowledge-approved", 0, fixture(t, "ack.json"))
	return f
}

func TestDriveApprove(t *testing.T) {
	f := approveFake(t)
	out, errs, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 0 || errs != "" {
		t.Fatalf("rc=%d err=%q out=\n%s", rc, errs, out)
	}
	want := "RUN gentle-ai review status --cwd /x --lineage L1\n" +
		`FORECAST [{"step": 1, "kind": "review", "reason_code": "four_lens", "description": "4 reviewers"}]` + "\n" +
		"COLLECT 2 inputs: ['risk', 'resilience']\n" +
		"LAUNCH gentle-ai review capture-result --lens risk\n" +
		"LAUNCH gentle-ai review capture-result --lens resilience\n" +
		`CAPTURE rc=0 {"schema": "gentle-ai.review-capture/v1", "status": "admitted"}` + "\n" +
		`CAPTURE rc=0 {"schema": "gentle-ai.review-capture/v1", "status": "approved", "status_continuation": {"kind": "execute", "execute": {"operation": "review.acknowledge-approved", "arguments": [{"token": "--lineage"}, {"token": "L1"}, {"token": "--token"}, {"token": "ACK1"}]}}}` + "\n" +
		"RUN gentle-ai review acknowledge-approved --lineage L1 --token ACK1\n" +
		`ACKNOWLEDGED {"schema": "gentle-ai.review-acknowledged/v1", "lineage_id": "L1", "target_identity": "T1", "outcome": "approved", "action": "acknowledged"}` + "\n"
	if out != want {
		t.Fatalf("out:\n%s\nwant:\n%s", out, want)
	}
	if last := f.calls[len(f.calls)-1]; last != "gentle-ai review acknowledge-approved --lineage L1 --token ACK1" {
		t.Fatalf("calls after acknowledge: %v", f.calls)
	}
	for _, d := range f.dirs {
		if d != "/wt" {
			t.Fatalf("ran in %q", d)
		}
	}
}

func TestDriveCapturesAreConcurrent(t *testing.T) {
	f := approveFake(t)
	out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 0 || strings.Contains(out, "barrier timeout") || strings.Contains(out, "rc=98") {
		t.Fatalf("captures ran serially: rc=%d\n%s", rc, out)
	}
}

func TestDriveRebound(t *testing.T) {
	f := newFake()
	f.on("review status", 0, fixture(t, "status-collect.json")).times = 1
	f.on("review status", 0, fixture(t, "status-stop-acked.json"))
	f.on("review capture-result", 0, fixture(t, "capture-pending.json"))
	out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 0 || strings.Count(f.callLines(), "review status") != 2 || !strings.Contains(out, "rdd-stop: target_already_acknowledged\n") {
		t.Fatalf("rc=%d calls=%s out=%s", rc, f.callLines(), out)
	}
}

func TestDriveLastTerminalCaptureDecides(t *testing.T) {
	f := newFake()
	f.on("review status", 0, fixture(t, "status-collect.json"))
	f.on("review capture-result --lens risk", 0, fixture(t, "capture-final-correction.json"))
	f.on("review capture-result --lens resilience", 0, fixture(t, "capture-final-approved.json"))
	f.on("review acknowledge-approved", 0, fixture(t, "ack.json"))
	_, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 0 || !strings.Contains(f.callLines(), "acknowledge-approved") {
		t.Fatalf("rc=%d calls=%s", rc, f.callLines())
	}
}

func TestDriveNextTransitionKindsDecideTerminal(t *testing.T) {
	// execute is terminal: its own operation runs; collect is not: the bound STATUS is asked again
	for kind, wantSecond := range map[string]string{
		"execute": "gentle-ai review status",
		"collect": "gentle-ai review status --cwd /x --lineage L1",
	} {
		f := newFake()
		f.on("review status", 0, fixture(t, "status-collect.json")).times = 1
		f.on("review status", 0, fixture(t, "status-stop-acked.json"))
		f.on("review capture-result", 0, `{"next_transition":{"kind":"`+kind+`","execute":{"operation":"review.status","arguments":[]}}}`)
		runDrive(t, f, fixture(t, "start-granted.json"))
		if got := f.calls[len(f.calls)-1]; got != wantSecond {
			t.Fatalf("kind %s: last call %q, want %q", kind, got, wantSecond)
		}
	}
	f := newFake()
	f.on("review status", 0, fixture(t, "status-collect.json"))
	f.on("review capture-result", 0, `{"next_transition":{"kind":"stop","reason_code":"lens_context_budget_exceeded"}}`)
	out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 13 || !strings.Contains(out, "rdd-stop: lens_context_budget_exceeded\n") || strings.Count(f.callLines(), "review status") != 1 {
		t.Fatalf("a stop-kind capture must end the run: rc=%d calls=%s out=%s", rc, f.callLines(), out)
	}
}

func TestDriveNonCaptureCollect(t *testing.T) {
	f := newFake()
	f.on("review status", 0, fixture(t, "status-correction.json"))
	out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	want := "RUN gentle-ai review status --cwd /x --lineage L1\n" +
		"rdd-stop: non-capture-collect (review.capture-correction-plan)\n" +
		`{"kind": "collect", "collect": {"inputs": [{"name": "plan", "capture_operation": "review.capture-correction-plan", "arguments": [{"token": "--lineage"}, {"token": "L1"}]}]}}` + "\n"
	if rc != 13 || out != want || strings.Contains(f.callLines(), "capture-correction-plan") {
		t.Fatalf("rc=%d out:\n%s", rc, out)
	}
	// a correction_request, when the provider supplies one, is the detail
	f = newFake()
	f.on("review status", 0, `{"next_transition":{"kind":"collect","correction_request":{"why":"x"},"collect":{"inputs":[{"capture_operation":"a"},{"capture_operation":"b"}]}}}`)
	out, _, rc = runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 13 || !strings.HasSuffix(out, "rdd-stop: non-capture-collect (a, b)\n{\"why\": \"x\"}\n") {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
}

func TestDriveStops(t *testing.T) {
	cases := []struct {
		name, status string
		rc           int
		want         string
	}{
		{"budget", "status-stop-budget.json", 13, "rdd-stop: lens_context_budget_exceeded\n{\"kind\": \"stop\", \"reason_code\": \"lens_context_budget_exceeded\"}\n"},
		{"already acknowledged", "status-stop-acked.json", 0, "rdd-stop: target_already_acknowledged\n{\"kind\": \"stop\", \"reason_code\": \"target_already_acknowledged\"}\n"},
		{"correction", "status-stop-correction.json", 13, "rdd-stop: correction_required\n{\"kind\": \"stop\", \"reason_code\": \"correction_required\"}\n"},
		{"no transition", "status-notrans.json", 13, "rdd-stop: no-transition\n{\"schema\": \"gentle-ai.review-status/v1\"}\n"},
	}
	for _, c := range cases {
		f := newFake()
		f.on("review status", 0, fixture(t, c.status))
		out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
		if rc != c.rc || !strings.HasSuffix(out, c.want) {
			t.Fatalf("%s: rc=%d out=%q", c.name, rc, out)
		}
	}
	f := newFake()
	f.on("review status", 0, `{"next_transition":{"kind":"stop"}}`)
	out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 13 || !strings.HasSuffix(out, "rdd-stop: stop-without-reason\n{\"kind\": \"stop\"}\n") {
		t.Fatalf("stop-without-reason rc=%d out=%q", rc, out)
	}
	f = newFake()
	f.on("review status", 0, `{"next_transition":{"kind":"wait"}}`)
	out, _, rc = runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 13 || !strings.HasSuffix(out, "rdd-stop: unknown-transition\n{\"kind\": \"wait\"}\n") {
		t.Fatalf("unknown-transition rc=%d out=%q", rc, out)
	}
	f = newFake()
	f.on("review status", 0, `{"status_continuation":{"kind":"stop","reason_code":"from_cont"},"next_transition":{"kind":"stop","reason_code":"from_next"}}`)
	out, _, _ = runDrive(t, f, fixture(t, "start-granted.json"))
	if !strings.Contains(out, "rdd-stop: from_cont\n") {
		t.Fatalf("status_continuation must win over next_transition: %s", out)
	}
}

func TestDriveConsentDocument(t *testing.T) {
	f := newFake()
	out, _, rc := runDrive(t, f, fixture(t, "consent.json"))
	if rc != 15 || len(f.calls) != 0 ||
		!strings.HasPrefix(out, "kit-rdd-drive: consent-required: the document is a consent envelope; nothing was run\n{\n  \"choices\": [") ||
		!strings.Contains(out, "--consent granted --target T1") {
		t.Fatalf("rc=%d calls=%v out=%s", rc, f.calls, out)
	}
}

func TestDriveStepLimit(t *testing.T) {
	f := newFake()
	f.on("review status", 0, fixture(t, "start-granted.json"))
	out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"), "--max-steps", "3")
	if rc != 13 || !strings.HasSuffix(out, "rdd-stop: step-limit\n") || len(f.calls) != 3 {
		t.Fatalf("rc=%d calls=%d out=%s", rc, len(f.calls), out)
	}
	f = newFake()
	out, _, rc = runDrive(t, f, fixture(t, "start-granted.json"), "--max-steps", "0")
	if rc != 13 || out != "rdd-stop: step-limit\n" || len(f.calls) != 0 {
		t.Fatalf("zero steps: rc=%d out=%q", rc, out)
	}
	f = newFake()
	f.on("review status", 0, fixture(t, "start-granted.json"))
	_, _, _ = runDrive(t, f, fixture(t, "start-granted.json"))
	if len(f.calls) != 40 {
		t.Fatalf("default step limit: %d calls, want 40", len(f.calls))
	}
}

func TestDriveNonJSON(t *testing.T) {
	f := newFake()
	f.on("review status", 0, "garbage\n")
	out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 13 || !strings.Contains(out, "NON-JSON rc=0 stdout=garbage stderr=\nrdd-stop: non-json\n") {
		t.Fatalf("rc=%d out=%q", rc, out)
	}
	// the last JSON object of noisy output is the answer
	f = newFake()
	f.on("review status", 0, "progress...\n"+fixture(t, "status-stop-acked.json"))
	out, _, rc = runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 0 || !strings.Contains(out, "rdd-stop: target_already_acknowledged") {
		t.Fatalf("rc=%d out=%q", rc, out)
	}
	// JSON null is treated like non-JSON, without the NON-JSON diagnostic
	f = newFake()
	f.on("review status", 0, "null")
	out, _, rc = runDrive(t, f, fixture(t, "start-granted.json"))
	if rc != 13 || strings.Contains(out, "NON-JSON") || !strings.HasSuffix(out, "rdd-stop: non-json\n") {
		t.Fatalf("rc=%d out=%q", rc, out)
	}
	// a capture that is not JSON is shown as None and the bound STATUS is asked again
	f = newFake()
	f.on("review status", 0, fixture(t, "status-collect.json")).times = 1
	f.on("review status", 0, fixture(t, "status-stop-acked.json"))
	f.on("review capture-result", 3, "oops")
	out, _, _ = runDrive(t, f, fixture(t, "start-granted.json"))
	if !strings.Contains(out, "NON-JSON rc=3 stdout=oops stderr=\n") || !strings.Contains(out, "CAPTURE rc=3 None\n") {
		t.Fatalf("out=%s", out)
	}
}

func TestDriveProtocolErrors(t *testing.T) {
	cases := []struct{ name, status, want string }{
		{"operation without dot", "bad-op-nodot.json", "operation is not review.<name>: 'reviewstatus'"},
		{"operation outside review", "bad-op-nonreview.json", "operation is not review.<name>: 'shell.exec'"},
		{"no arguments list", "bad-noargs.json", "operation review.status has no arguments list"},
		{"token missing", "bad-token.json", `operation review.status has an argument without a string token: {"nottoken": 1}`},
		{"empty inputs", "bad-collect-empty.json", "collect transition without a non-empty inputs list"},
		{"no inputs key", "bad-collect-nokey.json", "collect transition without a non-empty inputs list"},
		{"status is a list", "list.json", "document is not a JSON object: []"},
	}
	for _, c := range cases {
		f := newFake()
		f.on("review status", 0, fixture(t, c.status))
		out, errs, rc := runDrive(t, f, fixture(t, "start-granted.json"))
		if rc != 14 || errs != "" || !strings.HasSuffix(out, "kit-rdd-drive: rdd-protocol-error: "+c.want+"\n") {
			t.Fatalf("%s: rc=%d out=%q err=%q", c.name, rc, out, errs)
		}
		if strings.Contains(f.callLines(), "shell") {
			t.Fatalf("%s: a non-review operation ran: %s", c.name, f.callLines())
		}
	}
	for name, status := range map[string]string{
		"transition not an object": `{"next_transition":"x"}`,
		"execute not an object":    `{"next_transition":{"kind":"execute","execute":"x"}}`,
		"inputs not objects":       `{"next_transition":{"kind":"collect","collect":{"inputs":["x"]}}}`,
		"argument without token":   `{"next_transition":{"kind":"collect","collect":{"inputs":[{"capture_operation":"review.capture-result"}]}}}`,
		"artifact subject":         `{"next_transition":{"kind":"collect","collect":{"inputs":[{"capture_operation":"review.capture-result","arguments":[],"artifact_subject":"x"}]}}}`,
		"capture next_transition":  "CAPTURE",
	} {
		f := newFake()
		if status == "CAPTURE" {
			f.on("review status", 0, fixture(t, "status-collect.json"))
			f.on("review capture-result", 0, `{"next_transition":"x"}`)
		} else {
			f.on("review status", 0, status)
		}
		out, _, rc := runDrive(t, f, fixture(t, "start-granted.json"))
		if rc != 14 || !strings.Contains(out, "kit-rdd-drive: rdd-protocol-error: ") {
			t.Fatalf("%s: rc=%d out=%q", name, rc, out)
		}
	}
}

func TestDriveFirstDocument(t *testing.T) {
	f := newFake()
	for name, first := range map[string]string{"list": fixture(t, "list.json"), "not json": "{", "trailing": "{} x"} {
		out, _, rc := runDrive(t, f, first)
		if rc != 14 || !strings.Contains(out, "kit-rdd-drive: rdd-protocol-error: ") {
			t.Fatalf("%s: rc=%d out=%q", name, rc, out)
		}
	}
	s, o, _ := stdio("/work")
	rc := rddDrive([]string{"/wt", filepath.Join(t.TempDir(), "missing.json")}, s, f)
	if rc != 14 || !strings.HasPrefix(o.String(), "kit-rdd-drive: rdd-protocol-error: first document unreadable: ") {
		t.Fatalf("missing file: rc=%d out=%q", rc, o.String())
	}
	// null as the first document is non-json
	out, _, rc := runDrive(t, f, "null")
	if rc != 13 || out != "rdd-stop: non-json\n" {
		t.Fatalf("null: rc=%d out=%q", rc, out)
	}
}

func TestDriveDegradedAndUsage(t *testing.T) {
	f := newFake()
	f.absent = true
	out, errs, rc := runDrive(t, f, "{}")
	if rc != 3 || out != "kit-rdd-drive: degraded: missing runtime dependency: gentle-ai\n" ||
		errs != "DEGRADED: missing runtime dependency: gentle-ai\n" {
		t.Fatalf("rc=%d out=%q err=%q", rc, out, errs)
	}
	for _, args := range [][]string{nil, {"/wt"}, {"--max-steps", "x", "/a", "/b"}, {"--max-steps"}, {"/a", "/b", "/c"}} {
		s, o, e := stdio("/work")
		rc := rddDrive(args, s, newFake())
		if rc != 2 || o.String() != "" || !strings.HasPrefix(e.String(), driveUsage+"\nrsdd maint rdd-drive: error: ") {
			t.Fatalf("%v: rc=%d out=%q err=%q", args, rc, o.String(), e.String())
		}
	}
	s, o, _ := stdio("/work")
	if rc := rddDrive([]string{"--help"}, s, newFake()); rc != 0 || o.String() != driveUsage+"\n" {
		t.Fatalf("help rc=%d out=%q", rc, o.String())
	}
	// a negative step count is a number, not an option
	out, _, rc = runDrive(t, newFake(), "{}", "--max-steps", "-1")
	if rc != 13 || out != "rdd-stop: step-limit\n" {
		t.Fatalf("negative max-steps: rc=%d out=%q", rc, out)
	}
}

func TestDriveCannotRun(t *testing.T) {
	f := newFake()
	f.runErr = errors.New("boom")
	s, o, e := stdio("/work")
	first := filepath.Join(t.TempDir(), "first.json")
	writeFile(t, first, fixture(t, "start-granted.json"))
	rc := rddDrive([]string{"/wt", first}, s, f)
	if rc != 1 || !strings.Contains(e.String(), "rsdd: maint rdd-drive: boom") {
		t.Fatalf("rc=%d out=%q err=%q", rc, o.String(), e.String())
	}
}
