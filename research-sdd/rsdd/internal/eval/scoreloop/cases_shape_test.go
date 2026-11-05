package scoreloop

import "fmt"

func tr(name string, t *string) scase { return scase{name: name, commits: twoBlocks, transcript: t} }

// shapeCases: transcript shapes the scorer recognises, skips, or refuses (anti-silent-zero: a shape it cannot
// interpret is degraded, never a clean pass).
func shapeCases() []scase {
	h, a := human(ts("00:00"), "go"), asst(ts("00:25"), "end\nSTOP: campaign complete")
	noOrigin := func(ts string) string {
		return fmt.Sprintf(`{"type":"user","timestamp":%s,"message":{"role":"user","content":"hi"}}`, q(ts))
	}
	cases := []scase{
		tr("shape-clean", cleanRun()),
		tr("shape-no-origin-anywhere", jl(noOrigin(ts("00:00")), a)),
		tr("shape-headless-run", jl(noOrigin(ts("00:00")), noOrigin(ts("00:05")), a)),
		tr("shape-partial-origin-still-scores", jl(noOrigin(ts("00:00")), a, sysRecOrigin(ts("00:26")))),
		tr("shape-zero-operator-zero-assistant-with-origin", jl(sysRecOrigin(ts("00:00")), sysRecOrigin(ts("00:25")))),
		tr("shape-rollout-response-item", jl(`{"type":"response_item","timestamp":"2026-06-01T00:00:00Z","payload":{"role":"user","content":"x"}}`,
			`{"type":"response_item","timestamp":"2026-06-01T00:25:00Z","payload":{"role":"assistant","content":"y"}}`)),
		tr("shape-empty-file", raw("")),
		tr("shape-whitespace-only", raw("\n  \n\t\n")),
		tr("shape-malformed-line", jl(h, "not-json")),
		tr("shape-truncated-last-line", raw(h+"\n"+`{"type":"assistant","timestamp":"2026-06-01T00:25:00Z"`)),
		tr("shape-no-trailing-newline", raw(h+"\n"+a)),
		tr("shape-two-values-on-one-line", raw(h+" "+a+"\n")),
		tr("shape-pretty-printed-values", raw("{\n \"type\":\"user\",\n \"origin\":{\"kind\":\"human\"},\n \"timestamp\":\""+ts("00:00")+"\",\n \"message\":{\"content\":\"go\"}\n}\n"+a+"\n")),
		tr("shape-top-level-array", jl(h, "[1,2]", a)),
		tr("shape-top-level-number", jl(h, "5", a)),
		tr("shape-top-level-string", jl(h, `"text"`, a)),
		tr("shape-top-level-true", jl(h, "true", a)),
		tr("shape-message-is-string", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":"hi"}`, a)),
		tr("shape-message-is-array", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":[1]}`, a)),
		tr("shape-message-null", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":null}`, a)),
		tr("shape-content-number", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":5}}`, a)),
		tr("shape-content-object", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":{"a":1}}}`, a)),
		tr("shape-content-element-string", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":["x"]}}`, a)),
		tr("shape-content-element-null", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":[null,{"type":"text","text":"ok?"}]}}`, a)),
		tr("shape-content-text-null", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":[{"type":"text"}]}}`, a)),
		tr("shape-content-text-number", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":[{"type":"text","text":5},{"type":"text","text":true}]}}`, a)),
		tr("shape-content-text-array-fails", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":[{"type":"text","text":[1]}]}}`, a)),
		tr("shape-content-non-text-blocks-ignored", jl(h, `{"type":"assistant","timestamp":"2026-06-01T00:12:00Z","message":{"content":[{"type":"tool_use","name":"x"},{"type":"text","text":"fine"}]}}`, a)),
		tr("shape-origin-string-on-user-fails", jl(h, `{"type":"user","origin":"human","timestamp":"2026-06-01T00:12:00Z"}`, a)),
		tr("shape-origin-string-on-assistant-ok", jl(h, `{"type":"assistant","origin":"x","timestamp":"2026-06-01T00:12:00Z","message":{"content":"x"}}`, a)),
		tr("shape-origin-false-on-user-fails", jl(h, `{"type":"user","origin":false,"timestamp":"2026-06-01T00:12:00Z"}`, a)),
		tr("shape-origin-kind-number", jl(h, `{"type":"user","origin":{"kind":5},"timestamp":"2026-06-01T00:12:00Z"}`, a)),
		tr("shape-record-without-type-skipped", jl(h, `{"timestamp":"2026-06-01T00:12:00Z","origin":{"kind":"human"}}`, a)),
		tr("shape-type-false-skipped", jl(h, `{"type":false,"timestamp":"2026-06-01T00:12:00Z"}`, a)),
		tr("shape-record-without-timestamp-skipped", jl(h, `{"type":"user","origin":{"kind":"human"}}`, a)),
		tr("shape-timestamp-null-skipped", jl(h, `{"type":"user","origin":{"kind":"human"},"timestamp":null}`, a)),
		tr("shape-timestamp-empty-dropped", jl(h, `{"type":"user","origin":{"kind":"human"},"timestamp":""}`, a)),
		withDiv(tr("shape-timestamp-number-dropped", jl(h, `{"type":"user","origin":{"kind":"human"},"timestamp":5}`, a)), div(reasonTSNum, "stdout")),
		tr("shape-type-number-not-assistant", jl(h, `{"type":7,"timestamp":"2026-06-01T00:12:00Z"}`, a)),
		tr("shape-records-out-of-order", jl(a, h)),
		tr("shape-equal-timestamps-keep-file-order", jl(h, asst(ts("00:25"), "first?"), asst(ts("00:25"), "second\nSTOP: x"))),
		tr("shape-unicode-and-emoji", jl(h, asst(ts("00:25"), "listo \U0001F680\n\u00bfseguimos?"))),
		tr("shape-backslash-roundtrip", jl(h, asst(ts("00:25"), `see C:\new\table and a literal \n here`+"\nSTOP: campaign complete"))),
	}
	return append(cases, tr("shape-long-run", longRun()))
}

func sysRecOrigin(ts string) string {
	return fmt.Sprintf(`{"type":"system","origin":{"kind":"harness"},"timestamp":%s}`, q(ts))
}

// longRun is 400 assistant steps between a human start and a STOP, all within the fixture day.
func longRun() *string {
	lines := []string{human(ts("00:00"), "go")}
	for i := 1; i <= 400; i++ {
		lines = append(lines, asst(fmt.Sprintf("%s00:%02d:%02dZ", day, i/60, i%60), fmt.Sprintf("step %d", i)))
	}
	return jl(append(lines, asst(ts("00:25"), "done\nSTOP: campaign complete"))...)
}
