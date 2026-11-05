package scoreloop

import (
	"encoding/json"
	"fmt"
	"strings"
)

// allCases is the whole black-box corpus, one slice per theme file.
func allCases() []scase {
	var all []scase
	for _, part := range [][]scase{argCases(), blockCases(), windowCases(), shapeCases(), timeCases(), jqCases(),
		c1Cases(), c2Cases(), c3Cases(), c4Cases(), c4QualifierCases(), c4WindowCases()} {
		all = append(all, part...)
	}
	return all
}

func q(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// Transcript record builders (the Claude Code shapes the scorer reads).
func human(ts, text string) string {
	return fmt.Sprintf(`{"type":"user","origin":{"kind":"human"},"timestamp":%s,"message":{"role":"user","content":%s}}`, q(ts), q(text))
}

func asst(ts, text string) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":%s,"message":{"role":"assistant","content":[{"type":"text","text":%s}]}}`, q(ts), q(text))
}

func asstStr(ts, text string) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":%s,"message":{"role":"assistant","content":%s}}`, q(ts), q(text))
}

func toolRes(ts string) string {
	return fmt.Sprintf(`{"type":"user","timestamp":%s,"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}`, q(ts))
}

func sysRec(ts, subtype string) string {
	return fmt.Sprintf(`{"type":"system","subtype":%s,"timestamp":%s}`, q(subtype), q(ts))
}

func summary(ts string) string {
	return fmt.Sprintf(`{"type":"user","isCompactSummary":true,"timestamp":%s,"message":{"role":"user","content":"summary"}}`, q(ts))
}

func jl(lines ...string) *string {
	s := strings.Join(lines, "\n") + "\n"
	return &s
}

func raw(s string) *string { return &s }

const day = "2026-06-01T"

// ts is a timestamp of the fixture day: ts("00:10") is 2026-06-01T00:10:00Z.
func ts(hm string) string { return day + hm + ":00Z" }

func cm(hm, subject string) commit { return commit{ts(hm), subject} }

// Shared histories: B1 and B2 ten minutes apart, and a third block.
var (
	twoBlocks   = []commit{cm("00:10", "research(demo): B1 gap-a"), cm("00:20", "research(demo): B2 gap-b")}
	threeBlocks = append(append([]commit(nil), twoBlocks...), cm("00:30", "research(demo): B3 gap-c"))
)

// cleanRun is a transcript that spans twoBlocks with no operator turn between them and ends in a STOP.
func cleanRun() *string {
	return jl(human(ts("00:00"), "start"), asst(ts("00:25"), "finished\nSTOP: campaign complete"))
}

func envOf(kv ...string) map[string]string {
	m := map[string]string{}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	return m
}
