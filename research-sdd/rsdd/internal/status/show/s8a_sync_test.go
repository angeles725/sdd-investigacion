package show

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// S8a: the --sync-state cases of the bash suites that the case map marks UNMAPPED. Every scenario is in the S3
// table (the differential against the frozen script and the replay golden pin the whole run); the legacy
// ASSERTIONS (the envelope values the bash case read back, the stderr text it grepped) are stated in s8aSyncExp
// and checked against the port by TestS8aSync.

type syncExp struct {
	env    map[string]string // envelope key -> value after the run
	out    []string          // regexes the combined stdout+stderr must match
	notOut []string          // regexes it must not match
	rc     int
	file   string // the state file read back ("" = corpus/RESEARCH-STATE.md)
}

var s8aSyncExp = map[string]syncExp{}

func s8aSync(sc s3Scenario, e syncExp) s3Scenario {
	s8aSyncExp[sc.name] = e
	return sc
}

// ibState is the in-place-blocked suite's corpus: zeroed declared counters (kgd for known_gaps), the raw rows, an
// optional Blocked gaps section holding the raw bullets.
func ibState(kgd string, bullets []string, rows ...string) string {
	var b strings.Builder
	b.WriteString("# T — Research State\n\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: " + kgd +
		"\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n")
	for _, r := range rows {
		b.WriteString(r + "\n")
	}
	b.WriteString("\n")
	if len(bullets) > 0 {
		b.WriteString("## Blocked gaps\n\n")
		for _, x := range bullets {
			b.WriteString("- " + x + "\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("## Stop control\n\n")
	return b.String()
}

const (
	ibPend    = "| high | live gap | web | pending |"
	ibDone    = "| low | done gap | web | ✅ covered |"
	ibB1      = "| medium | blk-first | web | blocked (requires-hardware) |"
	ibDualID  = "| low | AB. Builders de config del equipo (TBL_X/Y) — offsets de campo | binario X.exe | blocked-on-tool: necesita decompilar X.exe · tried: y |"
	ibIDBull  = "**AB. Offsets de campo de las tablas de config** (TBL_X/Y) — needs: a decompiler"
	inPlaceRe = `sync-state: WARN: .*1 in-place blocked row`
)

func s8aSyncScenarios() []s3Scenario {
	var scs []s3Scenario
	mk := func(name, state string, e syncExp) s3Scenario { return s8aSync(ss(name, state, nil), e) }
	bo1gc1 := syncExp{env: map[string]string{"blocked_open": "1", "gaps_closed": "1"}}
	scs = append(scs,
		mk("s8a-ib-5-dual-listed-by-exact-name-counted-once", ibState("0", []string{"blk-first — needs: a tool"}, ibPend, ibDone, ibB1), bo1gc1),
		mk("s8a-ib-7a-id-matched-dual-listing-counted-once", ibState("0", []string{ibIDBull}, ibPend, ibDone, ibDualID),
			syncExp{env: bo1gc1.env, notOut: []string{`in-place blocked`}}),
		mk("s8a-ib-7c-plain-word-first-token-is-not-an-id", ibState("0", []string{"Builders de otra cosa — needs: tool"}, ibPend, ibDone, "| low | Builders de config — x | web | blocked (requires-tool) |"),
			syncExp{env: map[string]string{"blocked_open": "1", "gaps_closed": "0"}}),
		mk("s8a-ib-8-keep-path-kg-10-gaps-closed-1", ibState("10", nil, ibPend, ibDone, ibB1, "| high | a | b | c | d | e |"),
			syncExp{env: map[string]string{"known_gaps": "10", "gaps_closed": "1"}, out: []string{inPlaceRe}}),
		mk("s8a-ib-11-1-row-id-AB.-matches-bullet-AB", ibState("0", []string{"**AB Offsets de campo** (X) — needs: a decompiler"}, ibPend, ibDone, "| low | AB. Builders de config — x | web | blocked-on-tool: y |"), bo1gc1),
		mk("s8a-ib-11-2-row-id-AB-matches-bullet-ab:", ibState("0", []string{"**ab: Offsets de campo** (X) — needs: a decompiler"}, ibPend, ibDone, "| low | AB Builders de config — x | web | blocked-on-tool: y |"), bo1gc1),
		mk("s8a-ib-11-3-row-id-ab:-matches-bullet-AB.", ibState("0", []string{"**AB. Offsets de campo** (X) — needs: a decompiler"}, ibPend, ibDone, "| low | ab: Builders de config — x | web | blocked-on-tool: y |"), bo1gc1),
		mk("s8a-ib-12-needs-less-bullet-does-not-suppress-the-row", ibState("0", []string{"**AB. Offsets de campo** (X) — no clause here"}, ibPend, ibDone, ibDualID),
			syncExp{env: map[string]string{"blocked_open": "0", "gaps_closed": "1"}, out: []string{`1 in-place blocked row`}}),
	)

	// main suite 3093: a row with too many cells OUTSIDE a Gap-backlog section is no malformed row.
	n2 := "# T\n\n" + fence("schema: research-state.v1", "covered_blocks: 0", "gaps_closed: 0", "known_gaps: 0", "investigable_open: 0", "requires_execution_open: 0") +
		"\n## Other\n\n| P | G | t | S |\n|---|---|---|---|\n| high | g | t | pending | extra | cell |\n\n## Gap-backlog\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n| high | g | t | covered |\n\n## Coverage\nCoverage metric: 1/1\n## Blocked gaps\n\n## Stop control\n- **Open gaps — read-only investigable**: 0\n"
	scs = append(scs, mk("s8a-L3093-malformed-row-outside-the-backlog-is-silent", n2, syncExp{notOut: []string{`(?i)malformed (backlog )?row`}}))

	// main suite 3165: `pr.` as a data-row priority is unknown (the dead header skip was removed).
	n3 := "# T\n\n" + fence("schema: research-state.v1", "covered_blocks: 0", "gaps_closed: 0", "known_gaps: 0", "investigable_open: 0", "requires_execution_open: 0") +
		"\n## Gap-backlog\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n| pr. | g | t | pending |\n\n## Coverage\nCoverage metric: 0/0\n## Blocked gaps\n\n## Stop control\n- **Open gaps — read-only investigable**: 0\n"
	scs = append(scs, mk("s8a-L3165-pr-dot-priority-row-is-unknown", n3, syncExp{rc: 1, out: []string{`(?i)unknown priority|INVALID_PRIORITY`}}))

	// main suite 6826 (T-1307-EOF): a near-miss table whose last row has no trailing newline is still read.
	eof := "# T\n\n" + fence("schema: research-state.v1", "covered_blocks: 0", "gaps_closed: 0", "known_gaps: 0", "investigable_open: 0", "requires_execution_open: 0", "blocked_open: 0", "deferred_open: 0") +
		"\n## Backlog\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n| high | g1 | web | pending |\n| — | e-1 | web | closed |"
	scs = append(scs, mk("s8a-L6826-near-miss-table-at-eof-without-a-trailing-newline", eof,
		syncExp{env: map[string]string{"known_gaps": "2", "gaps_closed": "1", "investigable_open": "1", "deferred_open": "0"}}))

	// research-sdd-init 323-326: a document corpus mid-run; the Outline ratio must not feed gaps_closed/known_gaps.
	doc := "# Doc — Research State (document mode)\n\n> Operational state.\n\n<!-- research-state.v1 -->\nschema: research-state.v1\nmethod: document-cycle\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblocks_since_retro: 0\nlast_iteration_ts:\n<!-- /research-state.v1 -->\n\n## Coverage\n\n- **Covered blocks**: 0 (B1..B0)\n- **Outline coverage**: 2 / 5 covered   ← THE real document-mode progress number\n- **Coverage metric**: — (intentionally left blank in document mode; never fill this in)\n\n## Outline\n\n| # | Outline item | Genre | Block | Status |\n|---|---|---|---|---|\n| 1 | a topic | subject | | pending |\n\n## Gap-backlog\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n\n## Blocked gaps\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 0\n"
	scs = append(scs, mk("s8a-doc-midrun-outline-ratio-does-not-feed-the-gap-counters", doc,
		syncExp{env: map[string]string{"gaps_closed": "0", "known_gaps": "0"}, out: []string{`gaps_closed=0`, `known_gaps=0`}}))

	// blocked-rows 128 (W2, #2017): a degraded blocked read leaves EVERY focus file untouched; two focus files and no
	// --focus is refused by the scope guard before any derivation (the tree in the golden pins both files unchanged).
	two := s3Scenario{name: "s8a-br-128-two-focus-sync-with-an-unreadable-file-writes-nothing",
		files: files{"corpus/RESEARCH-STATE-a.md": nbBlocked, "corpus/RESEARCH-STATE-b.md": nbBlocked},
		runs:  [][]string{{"{ROOT}/corpus", "--sync-state"}}, unreadable: []string{"corpus/RESEARCH-STATE-b.md"}, needsUser: true}
	scs = append(scs, s8aSync(two, syncExp{rc: 1, out: []string{`refusing without explicit scope|derivation degraded`}, file: "corpus/RESEARCH-STATE-a.md"}))
	return scs
}

var (
	envKV     = regexp.MustCompile(`(?m)^([a-z_]+): *(.*?) *$`)
	coverLine = regexp.MustCompile(`(?mi)^.*\*{0,2}coverage metric\*{0,2}:.*$`) // the lines _cm_digits looks at
	ratio     = regexp.MustCompile(`[0-9]+[[:space:]]*/[[:space:]]*[0-9]+`)
)

func envOf(body string) map[string]string {
	in, m := false, map[string]string{}
	for _, l := range strings.Split(body, "\n") {
		switch {
		case strings.Contains(l, "<!-- research-state.v1 -->"):
			in = true
		case strings.Contains(l, "<!-- /research-state.v1 -->"):
			in = false
		case in:
			if k := envKV.FindStringSubmatch(l); k != nil {
				if _, seen := m[k[1]]; !seen {
					m[k[1]] = k[2]
				}
			}
		}
	}
	return m
}

func TestS8aSync(t *testing.T) {
	for _, sc := range s8aSyncScenarios() {
		e := s8aSyncExp[sc.name]
		t.Run(sc.name, func(t *testing.T) {
			if sc.needsUser && os.Geteuid() == 0 {
				t.Skip("mode-000 files are readable by root")
			}
			root := sc.build(t)
			outs := runGoS3(t, sc, root)
			if outs[0].rc != e.rc {
				t.Errorf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", outs[0].rc, e.rc, outs[0].out, outs[0].err)
			}
			all := outs[0].out + outs[0].err
			for _, re := range e.out {
				if !regexp.MustCompile(re).MatchString(all) {
					t.Errorf("output lacks /%s/:\n%s", re, all)
				}
			}
			for _, re := range e.notOut {
				if regexp.MustCompile(re).MatchString(all) {
					t.Errorf("output must not match /%s/:\n%s", re, all)
				}
			}
			rel := stateRel
			if e.file != "" {
				rel = e.file
			}
			body, err := os.ReadFile(filepath.Join(root, rel))
			if err != nil {
				t.Fatal(err)
			}
			if e.file != "" && string(body) != nbBlocked {
				t.Errorf("%s was rewritten", rel)
			}
			got := envOf(string(body))
			for k, want := range e.env {
				if got[k] != want {
					t.Errorf("%s = %q, want %q", k, got[k], want)
				}
			}
			if strings.HasPrefix(sc.name, "s8a-doc-midrun") {
				for _, l := range coverLine.FindAllString(string(body), -1) {
					if d := ratio.FindString(l); d != "" {
						t.Errorf("the Coverage metric line holds the ratio %q after --sync-state: %s", d, l)
					}
				}
			}
		})
	}
}
