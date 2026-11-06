package ciworkflow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// check judges one workflow source against one guard and returns one finding per problem, so the ways a filter
// can stop protecting are told apart: the event gone, the filter unreadable or replaced by paths-ignore, a required
// entry missing, or a negation entry that carves changes back out of a required one.
func check(src string, events, paths []string) []string {
	var out []string
	for _, ev := range events {
		have, state := EventPaths(src, ev)
		switch {
		case state == NoPaths:
			// No filter: the event runs on every change, which is wider than any list.
		case state != Found:
			out = append(out, ev+": "+state.String())
		default:
			for _, m := range Missing(have, paths) {
				out = append(out, ev+": paths lacks "+m)
			}
			for _, h := range have {
				if strings.HasPrefix(h, "!") {
					out = append(out, ev+": paths has the negation entry "+h)
				}
			}
		}
	}
	return out
}

func TestWorkflowPathFiltersKeepTheirEntries(t *testing.T) {
	root := filepath.Dir(kitroot.Dir(t))
	for _, g := range guards {
		src, err := os.ReadFile(filepath.Join(root, g.workflow))
		if err != nil {
			t.Fatalf("%s: cannot read the workflow, so its filters were not checked: %v", g.workflow, err)
		}
		for _, f := range check(string(src), g.events, g.paths) {
			t.Errorf("%s: %s", g.workflow, f)
		}
	}
}

// The guard itself must bite: each way of weakening a filter is a finding, and the wider forms are not.
func TestCheckFindings(t *testing.T) {
	const ok = "on:\n  push:\n    paths:\n      - \"research-sdd/**\"\n      - x.yml\n  pull_request:\n    paths:\n      - \"research-sdd/**\"\n      - x.yml\n"
	events, paths := []string{"push", "pull_request"}, []string{"research-sdd/**", "x.yml"}
	cases := []struct {
		name, src string
		want      []string
	}{
		{"both lists complete", ok, nil},
		{"narrowed in push", strings.Replace(ok, `"research-sdd/**"`, `"research-sdd/rsdd/**"`, 1), []string{"push: paths lacks research-sdd/**"}},
		{"narrowed in pull_request", ok[:strings.LastIndex(ok, `"research-sdd/**"`)] + "\"research-sdd/rsdd/**\"\n      - x.yml\n", []string{"pull_request: paths lacks research-sdd/**"}},
		{"second entry dropped everywhere", strings.ReplaceAll(ok, "      - x.yml\n", ""), []string{"push: paths lacks x.yml", "pull_request: paths lacks x.yml"}},
		{"event removed", ok[:strings.Index(ok, "  pull_request:")], []string{"pull_request: no such event"}},
		{"filter removed is wider, not a finding", "on:\n  push:\n    branches: [main]\n  pull_request:\n", nil},
		{"paths-ignore instead of paths", strings.Replace(ok, "    paths:\n      - \"research-sdd/**\"\n      - x.yml\n", "    paths-ignore:\n      - \"research-sdd/toolbelt/**\"\n", 1), []string{"push: paths-ignore filter"}},
		{"negation entry after the required ones", strings.Replace(ok, "      - x.yml\n", "      - x.yml\n      - \"!research-sdd/toolbelt/**\"\n", 1), []string{"push: paths has the negation entry !research-sdd/toolbelt/**"}},
		{"flow-form event hides its filter", strings.Replace(ok, "  push:\n    paths:\n      - \"research-sdd/**\"\n      - x.yml\n", "  push: {paths: [\"research-sdd/rsdd/**\"]}\n", 1), []string{"push: unrecognised form"}},
		{"unreadable filter", strings.Replace(ok, "    paths:\n      - \"research-sdd/**\"\n      - x.yml\n", "    paths: research-sdd\n", 1), []string{"push: unrecognised form"}},
		{"no on block", "jobs: {}\n", []string{"push: unrecognised form", "pull_request: unrecognised form"}},
	}
	for _, c := range cases {
		got := check(c.src, events, paths)
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
