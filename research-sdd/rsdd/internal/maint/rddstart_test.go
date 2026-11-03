package maint

import (
	"errors"
	"os"
	"strings"
	"testing"
)

const startTokens = "review start --cwd /x --contract gentle-ai.review-integration/v2"

func TestStartNotDue(t *testing.T) {
	f := newFake()
	f.on("review assess", 0, fixture(t, "assess-notdue.json"))
	out, errs, rc, outfile := runStart(t, f)
	want := "kit-rdd-start: assess: rc=0 risk=passive review_due=False reason=passive\n" +
		"kit-rdd-start: rdd-not-due: passive\n"
	if rc != 10 || out != want || errs != "" {
		t.Fatalf("rc=%d out=%q err=%q", rc, out, errs)
	}
	if strings.Contains(f.callLines(), "review status") {
		t.Fatalf("STATUS ran: %s", f.callLines())
	}
	if _, err := os.Stat(outfile); err == nil {
		t.Fatal("output file written")
	}
}

func TestStartAssessSelectors(t *testing.T) {
	f := newFake()
	f.due(t)
	f.on(startTokens, 0, fixture(t, "start-granted.json"))
	_, _, rc, _ := runStart(t, f, "--base-ref", "main", "--agent", "pi")
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	want := []string{
		"gentle-ai review assess --cwd /wt --agent pi --base-ref main --committed-only --json",
		"gentle-ai review status --cwd /x --contract gentle-ai.review-integration/v2 --agent claude-code --base-ref origin/main --committed-only --next-transition",
		"gentle-ai " + startTokens,
	}
	if strings.Join(f.calls, "\n") != strings.Join(want, "\n") {
		t.Fatalf("calls:\n%s", f.callLines())
	}
	for i, d := range f.dirs {
		if d != "/wt" {
			t.Fatalf("call %d ran in %q, want /wt", i, d)
		}
	}
}

func TestStartDefaults(t *testing.T) {
	f := newFake()
	f.on("review assess", 0, fixture(t, "assess-notdue.json"))
	runStart(t, f)
	if got := f.calls[0]; got != "gentle-ai review assess --cwd /wt --agent claude-code --base-ref origin/main --committed-only --json" {
		t.Fatalf("default selectors: %s", got)
	}
}

func TestStartConsentRequired(t *testing.T) {
	f := newFake()
	f.due(t)
	f.on(startTokens, 0, fixture(t, "consent.json"))
	out, _, rc, outfile := runStart(t, f)
	if rc != 15 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	want := "kit-rdd-start: assess: rc=0 risk=high review_due=True reason=high_risk\n" +
		"{\n" +
		"  \"choices\": [\n" +
		"    {\n" +
		"      \"answer\": \"granted\",\n" +
		"      \"effect\": \"native review runs\",\n" +
		"      \"invocation\": \"gentle-ai review start --cwd /x --consent granted --target T1\",\n" +
		"      \"label\": \"Grant\"\n" +
		"    },\n" +
		"    {\n" +
		"      \"answer\": \"declined\",\n" +
		"      \"effect\": \"no review\",\n" +
		"      \"invocation\": \"gentle-ai review start --cwd /x --consent declined --target T1\",\n" +
		"      \"label\": \"Decline\"\n" +
		"    }\n" +
		"  ],\n" +
		"  \"headline\": \"Review this candidate?\",\n" +
		"  \"schema\": \"gentle-ai.review-integration.consent/v3\"\n" +
		"}\n" +
		"kit-rdd-start: consent-required: re-run with --consent granted to record the maintainer's standing grant\n"
	if out != want {
		t.Fatalf("out:\n%s", out)
	}
	if n := strings.Count(f.callLines(), "review start"); n != 1 {
		t.Fatalf("%d START calls: %s", n, f.callLines())
	}
	if _, err := os.Stat(outfile); err == nil {
		t.Fatal("output file written without consent")
	}
}

func TestStartConsentGranted(t *testing.T) {
	f := newFake()
	f.due(t)
	f.on(startTokens, 0, fixture(t, "consent.json"))
	f.on("review start --cwd /x --consent granted --target T1", 0, fixture(t, "start-granted.json"))
	out, _, rc, outfile := runStart(t, f, "--consent", "granted")
	if rc != 0 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	if !strings.HasSuffix(out, "kit-rdd-start: started: granted START action=started\n") {
		t.Fatalf("out=%q", out)
	}
	if strings.Contains(f.callLines(), "declined") {
		t.Fatalf("declined invocation ran: %s", f.callLines())
	}
	got, err := os.ReadFile(outfile)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"schema": "gentle-ai.review-integration/v2", "action": "started", "next_transition": {"kind": "execute", "execute": {"operation": "review.status", "arguments": [{"token": "--cwd"}, {"token": "/x"}, {"token": "--lineage"}, {"token": "L1"}]}}}`
	if string(got) != want {
		t.Fatalf("outfile:\n%s", got)
	}
}

func TestStartDirect(t *testing.T) {
	f := newFake()
	f.due(t)
	f.on(startTokens, 0, fixture(t, "start-granted.json"))
	out, _, rc, outfile := runStart(t, f)
	if rc != 0 || !strings.HasSuffix(out, "kit-rdd-start: started: no consent envelope\n") {
		t.Fatalf("rc=%d out=%q", rc, out)
	}
	if st, err := os.Stat(outfile); err != nil || st.Size() == 0 {
		t.Fatalf("outfile: %v", err)
	}
}

func TestStartStatusContinuationAccepted(t *testing.T) {
	f := newFake()
	f.due(t)
	f.on(startTokens, 0, `{"action":"started","status_continuation":{"kind":"execute"}}`)
	_, _, rc, _ := runStart(t, f)
	if rc != 0 {
		t.Fatalf("a START with only status_continuation must count as started, rc=%d", rc)
	}
}

func TestStartErrors(t *testing.T) {
	cases := []struct {
		name  string
		setup func(f *fake, t *testing.T)
		args  []string
		want  string // substring of stdout
		calls string // substring that must NOT be in the calls
	}{
		{"granted twice", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, fixture(t, "consent-dup.json"))
		}, []string{"--consent", "granted"}, "rdd-start-error: no unique granted choice (2)", "--consent granted"},
		{"foreign granted invocation", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, fixture(t, "consent-evil.json"))
		}, []string{"--consent", "granted"}, "rdd-start-error: granted invocation is not 'gentle-ai review start'; refused", "sh -c"},
		{"granted invocation is review status", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, fixture(t, "consent-wrongop.json"))
		}, []string{"--consent", "granted"}, "rdd-start-error: granted invocation is not 'gentle-ai review start'; refused", ""},
		{"choices not objects", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, fixture(t, "consent-badchoices.json"))
		}, []string{"--consent", "granted"}, "rdd-start-error: no unique granted choice (0)", ""},
		{"choices missing", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, `{"schema":"gentle-ai.review-integration.consent/v3"}`)
		}, []string{"--consent", "granted"}, "no unique granted choice (0)", ""},
		{"granted without invocation", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, `{"schema":"gentle-ai.review-integration.consent/v3","choices":[{"answer":"granted"}]}`)
		}, []string{"--consent", "granted"}, "rdd-start-error: granted choice has no usable invocation", ""},
		{"granted invocation unparseable", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, `{"schema":"gentle-ai.review-integration.consent/v3","choices":[{"answer":"granted","invocation":"gentle-ai 'review"}]}`)
		}, []string{"--consent", "granted"}, "rdd-start-error: granted invocation is not parseable", ""},
		{"refused start", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, fixture(t, "start-refused.json"))
		}, nil, "rdd-start-error: START did not start a review (action=refused reason=managed_assets_outdated)", ""},
		{"refused granted start", func(f *fake, t *testing.T) {
			f.due(t)
			f.on(startTokens, 0, fixture(t, "consent.json"))
			f.on("review start --cwd /x --consent granted", 0, fixture(t, "start-refused.json"))
		}, []string{"--consent", "granted"}, "rdd-start-error: START did not start a review (action=refused reason=managed_assets_outdated)", ""},
		{"non-JSON assess", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "head.txt"))
		}, nil, "rdd-start-error: non-JSON answer from gentle-ai review assess --cwd rc=0 stdout=abc1234", ""},
		{"assess rc 1 even when not due", func(f *fake, t *testing.T) {
			f.on("review assess", 1, fixture(t, "assess-notdue.json"))
		}, nil, "rdd-start-error: assessment failed or undecidable (rc=1); not treated as 'not due'", ""},
		{"assess without review_due", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-nokey.json"))
		}, nil, "rdd-start-error: assessment failed or undecidable (rc=0)", ""},
		{"review_due is a string", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-string.json"))
		}, nil, "review_due=false reason=None\nkit-rdd-start: rdd-start-error: assessment failed or undecidable (rc=0)", ""},
		{"assess answer is a list", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "list.json"))
		}, nil, "rdd-start-error: answer from gentle-ai review assess --cwd is not a JSON object", ""},
		{"due without command", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due-nocmd.json"))
		}, nil, "rdd-start-error: assess answer has no next_transition.command", ""},
		{"command not parseable", func(f *fake, t *testing.T) {
			f.on("review assess", 0, `{"review_due":true,"next_transition":{"command":"gentle-ai 'review"}}`)
		}, nil, "rdd-start-error: next_transition.command is not parseable", ""},
		{"empty command", func(f *fake, t *testing.T) {
			f.on("review assess", 0, `{"review_due":true,"next_transition":{"command":""}}`)
		}, nil, "rdd-start-error: STATUS command is not 'gentle-ai review status'; refused: ", ""},
		{"sh -c as STATUS", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due-shcmd.json"))
		}, nil, "rdd-start-error: STATUS command is not 'gentle-ai review status'; refused: sh -c 'touch PWNED'", "sh -c"},
		{"assess as STATUS", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due-assesscmd.json"))
		}, nil, "rdd-start-error: STATUS command is not 'gentle-ai review status'; refused", "assess --cwd /x"},
		{"STATUS is a list", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due.json"))
			f.on("review status", 0, fixture(t, "list.json"))
		}, nil, "rdd-start-error: answer from gentle-ai review status --cwd is not a JSON object", ""},
		{"STATUS is not a start", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due.json"))
			f.on("review status", 0, fixture(t, "status-not-start.json"))
		}, nil, `rdd-start-error: STATUS is not a review.start execute: {"kind": "stop", "reason_code": "target_already_acknowledged"}`, ""},
		{"STATUS without transition", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due.json"))
			f.on("review status", 0, `{}`)
		}, nil, "rdd-start-error: STATUS is not a review.start execute: null", ""},
		{"STATUS kind is not execute", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due.json"))
			f.on("review status", 0, `{"next_transition":{"kind":"collect","execute":{"operation":"review.start"}}}`)
		}, nil, "rdd-start-error: STATUS is not a review.start execute", ""},
		{"STATUS operation is not start", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due.json"))
			f.on("review status", 0, `{"next_transition":{"kind":"execute","execute":{"operation":"review.status"}}}`)
		}, nil, "rdd-start-error: STATUS is not a review.start execute", ""},
		{"START argument without token", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due.json"))
			f.on("review status", 0, fixture(t, "status-bad-args.json"))
		}, nil, `rdd-start-error: provider argument without a string token: {"nottoken": 1}`, ""},
		{"START arguments empty", func(f *fake, t *testing.T) {
			f.on("review assess", 0, fixture(t, "assess-due.json"))
			f.on("review status", 0, `{"next_transition":{"kind":"execute","execute":{"operation":"review.start","arguments":[]}}}`)
		}, nil, "rdd-start-error: provider arguments are missing or empty", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFake()
			c.setup(f, t)
			out, errs, rc, outfile := runStart(t, f, c.args...)
			if rc != 14 && rc != 10 {
				t.Fatalf("rc=%d out=%s", rc, out)
			}
			if rc != 14 || !strings.Contains(out, c.want) || errs != "" {
				t.Fatalf("rc=%d want %q in:\n%s\nerr=%q", rc, c.want, out, errs)
			}
			if c.calls != "" && strings.Contains(f.callLines(), c.calls) {
				t.Fatalf("forbidden call %q ran:\n%s", c.calls, f.callLines())
			}
			if _, err := os.Stat(outfile); err == nil {
				t.Fatal("output file written on an error")
			}
		})
	}
}

func TestStartDegraded(t *testing.T) {
	f := newFake()
	f.absent = true
	out, errs, rc, _ := runStart(t, f)
	if rc != 3 || out != "kit-rdd-start: degraded: degraded: missing runtime dependency: gentle-ai\n" ||
		errs != "DEGRADED: missing runtime dependency: gentle-ai\n" {
		t.Fatalf("rc=%d out=%q err=%q", rc, out, errs)
	}
	if len(f.calls) != 0 {
		t.Fatalf("ran with gentle-ai absent: %v", f.calls)
	}
}

func TestStartCannotRun(t *testing.T) {
	f := newFake()
	f.runErr = errors.New("chdir /wt: no such file or directory")
	out, _, rc, _ := runStart(t, f)
	want := "kit-rdd-start: rdd-start-error: malformed provider output or unusable path: OSError: chdir /wt: no such file or directory\n"
	if rc != 14 || out != want {
		t.Fatalf("rc=%d out=%q", rc, out)
	}
}

func TestStartUnwritableOutfile(t *testing.T) {
	f := newFake()
	f.due(t)
	f.on(startTokens, 0, fixture(t, "start-granted.json"))
	s, o, _ := stdio("/work")
	rc := rddStart([]string{"/wt", "/nonexistent-dir-rdd/out.json"}, s, f)
	if rc != 14 || !strings.Contains(o.String(), "rdd-start-error: malformed provider output or unusable path: OSError: ") ||
		strings.Contains(o.String(), "started") {
		t.Fatalf("rc=%d out=%q", rc, o.String())
	}
}

func TestStartUsageNamesMissingArguments(t *testing.T) {
	s, _, e := stdio("/work")
	if rc := rddStart([]string{"/wt"}, s, newFake()); rc != 2 || !strings.HasSuffix(e.String(), "error: the following arguments are required: outfile\n") {
		t.Fatalf("rc=%d err=%q", rc, e.String())
	}
}

func TestStartUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"/wt"}, {"/a", "/b", "/c"}, {"--consent", "declined", "/a", "/b"}, {"--bogus", "/a", "/b"}, {"--consent"}} {
		s, o, e := stdio("/work")
		rc := rddStart(args, s, newFake())
		if rc != 2 || o.String() != "" || !strings.HasPrefix(e.String(), startUsage+"\nrsdd maint rdd-start: error: ") {
			t.Fatalf("%v: rc=%d out=%q err=%q", args, rc, o.String(), e.String())
		}
	}
	s, o, _ := stdio("/work")
	if rc := rddStart([]string{"-h"}, s, newFake()); rc != 0 || o.String() != startUsage+"\n" {
		t.Fatalf("help rc=%d out=%q", rc, o.String())
	}
}

func TestStartOptionForms(t *testing.T) {
	f := newFake()
	f.on("review assess", 0, fixture(t, "assess-notdue.json"))
	outfile := t.TempDir() + "/o"
	s, _, _ := stdio("/work")
	// interleaved, "=" form and a unique prefix, as argparse accepts them
	rc := rddStart([]string{"/wt", "--base=feature", outfile, "--ag", "pi"}, s, f)
	if rc != 10 || f.calls[0] != "gentle-ai review assess --cwd /wt --agent pi --base-ref feature --committed-only --json" {
		t.Fatalf("rc=%d calls=%v", rc, f.calls)
	}
}
