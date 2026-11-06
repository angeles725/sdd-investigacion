package ciworkflow

import (
	"reflect"
	"testing"
)

const block = `name: x
# on: [push]
on:
  push:
    branches: [main]
    # a comment inside the event
    paths:
      - "research-sdd/**"   # trailing comment
      - '.github/workflows/x.yml'

      - plain/entry
  pull_request:
    paths: ["a/**", 'b']
  schedule:
    - cron: "1 2 * * *"
  workflow_dispatch:
jobs:
  build:
    paths:
      - not/a/filter
`

func TestEventPaths(t *testing.T) {
	cases := []struct {
		name, src, event string
		want             []string
		state            State
	}{
		{"block list", block, "push", []string{"research-sdd/**", ".github/workflows/x.yml", "plain/entry"}, Found},
		{"flow list", block, "pull_request", []string{"a/**", "b"}, Found},
		{"event with a body and no paths", block, "schedule", nil, NoPaths},
		{"event with no body", block, "workflow_dispatch", nil, NoPaths},
		{"event absent", block, "release", nil, NoEvent},
		{"a job key is not an event", block, "build", nil, NoEvent},
		{"paths-ignore is its own state", "on:\n  push:\n    paths-ignore:\n      - a\n", "push", nil, Ignores},
		{"paths-ignore beside paths", "on:\n  push:\n    paths:\n      - a\n    paths-ignore:\n      - b\n", "push", nil, Ignores},
		{"flow-form event", "on:\n  push: {paths: [a]}\n", "push", nil, Unrecognised},
		{"flow-form empty event", "on:\n  push: {}\n", "push", nil, Unrecognised},
		{"negation entries are returned as written", "on:\n  push:\n    paths:\n      - a\n      - \"!a/b\"\n", "push", []string{"a", "!a/b"}, Found},
		{"list at the key's indent", "on:\n  push:\n    paths:\n    - a\n    - b\n", "push", []string{"a", "b"}, Found},
		{"last line without newline", "on:\n  push:\n    paths:\n      - a", "push", []string{"a"}, Found},
		{"single entry", "on:\n  push:\n    paths:\n      - a\n", "push", []string{"a"}, Found},
		{"quotes: empty, lone and unbalanced", "on:\n  push:\n    paths:\n      - \"\"\n      - \"\n      - \"a'\n      - 'b'\n", "push", []string{"", `"`, `"a'`, "b"}, Found},
		{"a comment right after the dash keeps the list unreadable", "on:\n  push:\n    paths:\n      - #x\n", "push", nil, Unrecognised},
		{"next event at the same level ends the list", "on:\n  push:\n    paths:\n      - a\n  pull_request:\n    paths:\n      - b\n", "pull_request", []string{"b"}, Found},
		{"no on block", "name: x\njobs: {}\n", "push", nil, Unrecognised},
		{"inline on", "on: [push, pull_request]\n", "push", nil, Unrecognised},
		{"indented on is not the trigger block", "jobs:\n  on:\n    push:\n      paths:\n        - a\n", "push", nil, Unrecognised},
		{"empty paths", "on:\n  push:\n    paths:\n  pull_request:\n", "push", nil, Unrecognised},
		{"empty flow list", "on:\n  push:\n    paths: []\n", "push", nil, Unrecognised},
		{"scalar paths", "on:\n  push:\n    paths: a\n", "push", nil, Unrecognised},
		{"unclosed flow list", "on:\n  push:\n    paths: [a\n", "push", nil, Unrecognised},
		{"mapping under paths", "on:\n  push:\n    paths:\n      a: b\n", "push", nil, Unrecognised},
		{"empty source", "", "push", nil, Unrecognised},
	}
	for _, c := range cases {
		got, state := EventPaths(c.src, c.event)
		if state != c.state || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %q (%v), want %q (%v)", c.name, got, state, c.want, c.state)
		}
	}
}

func TestMissing(t *testing.T) {
	cases := []struct{ have, want, missing []string }{
		{[]string{"a", "b"}, []string{"a", "b"}, nil},
		{[]string{"b", "a"}, []string{"a", "b"}, nil},
		{[]string{"a"}, []string{"a", "b", "c"}, []string{"b", "c"}},
		{nil, []string{"a"}, []string{"a"}},
		{[]string{"a/**"}, []string{"a"}, []string{"a"}},
		{[]string{"a"}, nil, nil},
	}
	for _, c := range cases {
		if got := Missing(c.have, c.want); !reflect.DeepEqual(got, c.missing) {
			t.Errorf("Missing(%q, %q) = %q, want %q", c.have, c.want, got, c.missing)
		}
	}
}

func TestStateNames(t *testing.T) {
	for s, want := range map[State]string{Found: "found", NoEvent: "no such event", NoPaths: "no paths filter", Ignores: "paths-ignore filter", Unrecognised: "unrecognised form"} {
		if s.String() != want {
			t.Errorf("State(%d) = %q, want %q", s, s.String(), want)
		}
	}
}
