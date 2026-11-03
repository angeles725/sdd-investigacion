package resume

import (
	"sort"
	"strings"
)

// docOK is the resume-state document of toolbelt/tests/fixtures/resume-render/state-prs-ok.json (one PR, no remote).
const docOK = `{
  "schema": "research-sdd.resume-state/v1",
  "generated_at": "2026-10-03T12:00:00Z",
  "repo": {"toplevel": "/r/kit", "remote": null},
  "base_ref": "origin/main",
  "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "worktrees": [
    {"path": "/r/kit", "branch": "main", "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "exists": true, "prunable": false, "dirty": 0, "untracked": 0, "ahead": 0, "behind": 0}
  ],
  "branches": [],
  "prs": [
    {"number": 7, "branch": "feat/x", "state": "OPEN", "url": "https://example.com/pr/7"}
  ],
  "prs_truncated": false,
  "prs_status": "ok"
}`

// docDegraded is state-degraded.json: a remote, four worktrees (clean, dirty, missing, detached), two loose branches
// and an unknown PR list.
const docDegraded = `{
  "schema": "research-sdd.resume-state/v1",
  "generated_at": "2026-10-03T12:00:00Z",
  "repo": {"toplevel": "/r/kit", "remote": "git@example.com:o/kit.git"},
  "base_ref": "origin/main",
  "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "worktrees": [
    {"path": "/r/kit", "branch": "main", "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "exists": true, "prunable": false, "dirty": 0, "untracked": 0, "ahead": 0, "behind": 0},
    {"path": "/r/wt-feat", "branch": "feat/x", "head": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "exists": true, "prunable": false, "dirty": 3, "untracked": 2, "ahead": 4, "behind": 1},
    {"path": "/r/wt-gone", "branch": "feat/gone", "head": "cccccccccccccccccccccccccccccccccccccccc", "exists": false, "prunable": true, "dirty": null, "untracked": null, "ahead": 1, "behind": 0},
    {"path": "/r/wt-det", "branch": null, "head": "dddddddddddddddddddddddddddddddddddddddd", "exists": true, "prunable": false, "dirty": null, "untracked": null, "ahead": null, "behind": null}
  ],
  "branches": [
    {"name": "loose/one", "head": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "ahead": 2, "behind": 5},
    {"name": "loose/two", "head": "ffffffffffffffffffffffffffffffffffffffff", "ahead": null, "behind": null}
  ],
  "prs": null,
  "prs_truncated": null,
  "prs_status": "degraded:gh-timeout"
}`

// docEmpty is state-prs-empty.json.
const docEmpty = `{
  "schema": "research-sdd.resume-state/v1",
  "generated_at": "2026-10-03T12:00:00Z",
  "repo": {"toplevel": "/r/kit", "remote": null},
  "base_ref": "main",
  "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "worktrees": [],
  "branches": [],
  "prs": [],
  "prs_truncated": false,
  "prs_status": "ok"
}`

// edit returns doc with one exact substring replaced; a substring that is absent is a bug of the table.
func edit(doc, from, to string) string {
	if !strings.Contains(doc, from) {
		panic("edit: " + from + " not in the document")
	}
	return strings.Replace(doc, from, to, 1)
}

func state(name string, args ...string) scn {
	return scn{name: name, cmd: "resume-state", args: args}
}

func stateOn(name, wld string, args ...string) scn {
	return scn{name: name, cmd: "resume-state", world: wld, args: args}
}

func stateGh(name, stub string, args ...string) scn {
	return scn{name: name, cmd: "resume-state", path: "gh:" + stub, args: args}
}

// renderDocs maps a file name to its content; each is rendered by its own scenario.
func renderDocs() map[string]string {
	prs := docOK
	return map[string]string{
		"degraded":        docDegraded,
		"prs-ok":          docOK,
		"prs-empty":       docEmpty,
		"truncated":       edit(prs, `"prs_truncated": false`, `"prs_truncated": true`),
		"trunc-null":      edit(prs, `"prs_truncated": false`, `"prs_truncated": null`),
		"incons":          edit(prs, `"prs_status": "ok"`, `"prs_status": "skipped"`),
		"nostatus":        edit(edit(prs, `"prs_status": "ok"`, `"x": 1`), `"prs": [`, `"prs": null, "y": [`),
		"status-false":    edit(edit(prs, `"prs_status": "ok"`, `"prs_status": false`), `"prs": [`, `"prs": null, "y": [`),
		"status-num":      edit(edit(prs, `"prs_status": "ok"`, `"prs_status": 4.50`), `"prs": [`, `"prs": null, "y": [`),
		"v0":              edit(prs, "resume-state/v1", "resume-state/v0"),
		"schema-obj":      edit(prs, `"schema": "research-sdd.resume-state/v1"`, `"schema": {"a":[1,2.0,true,null,"é"]}`),
		"schema-num":      edit(prs, `"schema": "research-sdd.resume-state/v1"`, `"schema": 1E2`),
		"schema-null":     edit(prs, `"schema": "research-sdd.resume-state/v1"`, `"schema": null`),
		"no-worktrees":    edit(prs, `"worktrees": [`, `"zz": [`),
		"no-branches":     edit(prs, `"branches": []`, `"zz": []`),
		"no-base":         edit(prs, `"base_ref": "origin/main"`, `"zz": 1`),
		"base-num":        edit(prs, `"base_ref": "origin/main"`, `"base_ref": 5`),
		"wt-scalar":       edit(prs, `"worktrees": [`, `"worktrees": [1], "zz": [`),
		"br-scalar":       edit(prs, `"branches": []`, `"branches": ["x"]`),
		"prs-scalar":      edit(prs, `"prs": [`, `"prs": ["x"], "zz": [`),
		"prs-object":      edit(prs, `"prs": [`, `"prs": {}, "zz": [`),
		"repo-string":     edit(prs, `"repo": {"toplevel": "/r/kit", "remote": null}`, `"repo": "s"`),
		"repo-null":       edit(prs, `"repo": {"toplevel": "/r/kit", "remote": null}`, `"repo": null`),
		"repo-missing":    edit(prs, `"repo": {"toplevel": "/r/kit", "remote": null},`, ``),
		"remote-missing":  edit(prs, `"remote": null`, `"zz": 1`),
		"remote-string":   edit(prs, `"remote": null`, `"remote": "u"`),
		"toplevel-miss":   edit(prs, `"toplevel": "/r/kit", `, ``),
		"toplevel-false":  edit(prs, `"toplevel": "/r/kit"`, `"toplevel": false`),
		"gen-missing":     edit(prs, `"generated_at": "2026-10-03T12:00:00Z",`, ``),
		"gen-false":       edit(prs, `"generated_at": "2026-10-03T12:00:00Z"`, `"generated_at": false`),
		"exists-missing":  edit(docDegraded, `"exists": true, "prunable": false, "dirty": 3`, `"prunable": false, "dirty": 3`),
		"exists-string":   edit(docDegraded, `"exists": true, "prunable": false, "dirty": 3`, `"exists": "yes", "prunable": false, "dirty": 3`),
		"prunable-str":    edit(docDegraded, `"exists": false, "prunable": true`, `"exists": false, "prunable": "true"`),
		"branch-missing":  edit(prs, `"branch": "main", `, ``),
		"branch-num":      edit(prs, `"branch": "main"`, `"branch": 12`),
		"path-missing":    edit(prs, `"path": "/r/kit", `, ``),
		"head-missing":    edit(prs, `"head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", `, ``),
		"head-short":      edit(prs, `"head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"head": "é😀abc"`),
		"head-num":        edit(prs, `"head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"head": 123456789012`),
		"head-obj":        edit(prs, `"head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"head": {"a":1}`),
		"counts-types":    edit(edit(prs, `"dirty": 0`, `"dirty": 1.50`), `"untracked": 0`, `"untracked": "many"`),
		"counts-numbers":  edit(edit(edit(prs, `"dirty": 0`, `"dirty": 1e2`), `"ahead": 0`, `"ahead": 0.0001`), `"behind": 0`, `"behind": 12345678901234567890123`),
		"counts-exp":      edit(edit(edit(prs, `"dirty": 0`, `"dirty": 1.5e-7`), `"ahead": 0`, `"ahead": -0`), `"behind": 0`, `"behind": 10E-3`),
		"counts-bool":     edit(edit(prs, `"dirty": 0`, `"dirty": false`), `"ahead": 0`, `"ahead": [1,2]`),
		"base-sha-miss":   edit(prs, `"base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",`, ``),
		"br-noname":       edit(prs, `"branches": []`, `"branches": [{"head":"abcdef0123"}]`),
		"br-nohead":       edit(prs, `"branches": []`, `"branches": [{"name":"n"}]`),
		"br-full":         edit(prs, `"branches": []`, `"branches": [{"name":"n","head":"abcdef0123456","ahead":0,"behind":3}]`),
		"pr-nulls":        edit(prs, `{"number": 7, "branch": "feat/x", "state": "OPEN", "url": "https://example.com/pr/7"}`, `{"number": null, "branch": null, "state": null, "url": null}`),
		"pr-empty-obj":    edit(prs, `{"number": 7, "branch": "feat/x", "state": "OPEN", "url": "https://example.com/pr/7"}`, `{}`),
		"pr-types":        edit(prs, `{"number": 7, "branch": "feat/x", "state": "OPEN", "url": "https://example.com/pr/7"}`, `{"number": 7.0, "branch": 5, "state": true, "url": ["a",{"b":null}]}`),
		"pr-two":          edit(prs, `{"number": 7, "branch": "feat/x", "state": "OPEN", "url": "https://example.com/pr/7"}`, `{"number": 7, "branch": "feat/x", "state": "OPEN", "url": "u7"}, {"number": 8, "branch": "feat/y", "state": "DRAFT", "url": "u8"}`),
		"pr-trunc-two":    edit(edit(prs, `"prs_truncated": false`, `"prs_truncated": true`), `{"number": 7, "branch": "feat/x", "state": "OPEN", "url": "https://example.com/pr/7"}`, `{"number": 7, "branch": "b", "state": "s", "url": "u"}, {"number": 8, "branch": "c", "state": "t", "url": "v"}`),
		"unicode-escape":  edit(prs, `"path": "/r/kit"`, `"path": "/r/é\u007f\n\t\"x "`),
		"dup-keys":        edit(prs, `"base_ref": "origin/main",`, `"base_ref": "x", "base_ref": "origin/main",`),
		"false-doc":       `false`,
		"null-doc":        `null`,
		"array-doc":       `[]`,
		"string-doc":      `"x"`,
		"number-doc":      `7`,
		"true-doc":        `true`,
		"empty":           ``,
		"spaces":          "  \n\n",
		"garbage":         `{not json`,
		"truncated-json":  `{"schema": "research-sdd.resume-state/v1"`,
		"two-docs":        docOK + "\n" + docOK,
		"doc-then-null":   docOK + "\nnull",
		"doc-then-junk":   docOK + "\n{",
		"trailing-comma":  `{"a":1,}`,
		"bom":             "\xef\xbb\xbf" + docOK,
		"crlf":            strings.ReplaceAll(docOK, "\n", "\r\n"),
		"invalid-utf8":    edit(docOK, `"path": "/r/kit"`, "\"path\": \"/r/\xff\xfek\""),
		"tab-gen":         edit(docOK, `"generated_at": "2026-10-03T12:00:00Z"`, `"generated_at": "a	b"`),
		"deep":            edit(docOK, `"prs_truncated": false`, `"prs_truncated": false, "deep": [[[[[[[[1]]]]]]]]`),
		"exists-null":     edit(docDegraded, `"exists": true, "prunable": false, "dirty": 3`, `"exists": null, "prunable": false, "dirty": 3`),
		"exists-false-ok": edit(docDegraded, `"exists": false, "prunable": true`, `"exists": false, "prunable": false`),
		"prunable-miss":   edit(docDegraded, `"exists": false, "prunable": true,`, `"exists": false,`),
		"gen-num":         edit(docOK, `"generated_at": "2026-10-03T12:00:00Z"`, `"generated_at": 5`),
	}
}

// scenarios is the whole table: every scenario is recorded from the frozen scripts and replayed against the Go port.
func scenarios() []scn {
	var out []scn
	add := func(s ...scn) { out = append(out, s...) }

	// resume-state: documents and the envelope
	add(
		state("state-default", "--no-gh"),
		state("state-json", "--no-gh", "--json"),
		state("state-default-json-first", "--json", "--no-gh"),
		scn{name: "state-cwd-flag", cmd: "resume-state", cwd: ".", args: []string{"--cwd", "{R}", "--no-gh"}},
		scn{name: "state-cwd-subdir", cmd: "resume-state", cwd: ".", args: []string{"--cwd", "{R}/sub", "--no-gh"}},
		scn{name: "state-cwd-relative", cmd: "resume-state", cwd: ".", args: []string{"--cwd", "r/sub", "--no-gh"}},
		scn{name: "state-cwd-last-wins", cmd: "resume-state", cwd: ".", args: []string{"--cwd", "/nonexistent", "--cwd", "{R}", "--no-gh"}},
		state("state-gh-default", "--no-gh", "--no-gh"),
		stateGh("state-gh-ok", "ok"),
		stateGh("state-gh-ok-json", "ok", "--json"),
		stateGh("state-gh-empty", "empty"),
		stateGh("state-gh-empty-json", "empty", "--json"),
		stateGh("state-gh-bad", "bad"),
		stateGh("state-gh-bad-json", "bad", "--json"),
		stateGh("state-gh-junk", "junk"),
		stateGh("state-gh-junk-json", "junk", "--json"),
		stateGh("state-gh-t124", "t124"),
		stateGh("state-gh-t124-json", "t124", "--json"),
		stateGh("state-gh-full", "full"),
		stateGh("state-gh-full-json", "full", "--json"),
		stateGh("state-gh-obj", "obj"),
		stateGh("state-gh-obj-json", "obj", "--json"),
		stateGh("state-gh-nullel", "nullel"),
		stateGh("state-gh-scalar", "scalar"),
		stateGh("state-gh-scalar0", "scalar0"),
		stateGh("state-gh-silent", "silent"),
		stateGh("state-gh-partial", "partial"),
		stateGh("state-gh-partial-json", "partial", "--json"),
		stateGh("state-gh-noghflag", "ok", "--no-gh"),
		scn{name: "state-gh-missing", cmd: "resume-state", path: "nogh"},
		scn{name: "state-gh-missing-json", cmd: "resume-state", path: "nogh", args: []string{"--json"}},
		scn{name: "state-gh-noexec", cmd: "resume-state", path: "noexec-gh"},
		scn{name: "state-gh-notimeout", cmd: "resume-state", path: "notimeout:ok"},
		scn{name: "state-gh-notimeout-json", cmd: "resume-state", path: "notimeout:ok", args: []string{"--json"}},
		scn{name: "state-gh-notimeout-nogh", cmd: "resume-state", path: "notimeout:ok", args: []string{"--no-gh"}},
		scn{name: "state-bulk", cmd: "resume-state", world: "bulk", args: []string{"--no-gh"}},
		scn{name: "state-bulk-json", cmd: "resume-state", world: "bulk", args: []string{"--no-gh", "--json"}},
		scn{name: "state-gitlog", cmd: "resume-state", path: "gitlog", args: []string{"--no-gh"}, env: map[string]string{"GIT_OPTIONAL_LOCKS": "1"}},
		scn{name: "state-ambient-git-dir", cmd: "resume-state", args: []string{"--no-gh"}, env: map[string]string{"GIT_DIR": "/nonexistent", "GIT_WORK_TREE": "/nonexistent", "GIT_COMMON_DIR": "/nonexistent", "GIT_INDEX_FILE": "/nonexistent"}},
	)
	// base ref
	add(
		state("state-base-loose", "--no-gh", "--base-ref", "loose"),
		state("state-base-loose-json", "--no-gh", "--base-ref", "loose", "--json"),
		state("state-base-sha", "--no-gh", "--base-ref", "{SHA:main~1}"),
		state("state-base-main", "--no-gh", "--base-ref", "main"),
		state("state-base-origin", "--no-gh", "--base-ref", "origin/main"),
		state("state-base-tag", "--no-gh", "--base-ref", "dup"),
		state("state-base-bad", "--no-gh", "--base-ref", "no-such-ref"),
		state("state-base-bad-json", "--no-gh", "--base-ref", "no-such-ref", "--json"),
		state("state-base-dash", "--no-gh", "--base-ref", "--help"),
		state("state-base-dash-x", "--no-gh", "--base-ref", "-x"),
		state("state-base-empty-value", "--no-gh", "--base-ref", ""),
		state("state-base-missing-value", "--base-ref"),
		stateOn("state-plain", "plain", "--no-gh"),
		stateOn("state-plain-json", "plain", "--no-gh", "--json"),
		stateOn("state-plain-gh", "plain", "--base-ref", "main"),
		stateOn("state-nobase", "nobase", "--no-gh"),
		stateOn("state-nobase-json", "nobase", "--no-gh", "--json"),
		stateOn("state-nobase-explicit", "nobase", "--no-gh", "--base-ref", "trunk"),
	)
	// usage and operational failures
	add(
		state("state-help", "--help"),
		state("state-help-short", "-h"),
		state("state-help-after-cwd", "--cwd", "--help"),
		state("state-help-after-bogus", "--bogus", "--help"),
		state("state-help-before-bogus", "--help", "--bogus"),
		state("state-bogus", "--bogus"),
		state("state-bogus-json", "--json", "--bogus"),
		state("state-positional", "stray"),
		state("state-cwd-missing-value", "--cwd"),
		state("state-cwd-dash", "--cwd", "-x", "--no-gh"),
		state("state-cwd-gone", "--cwd", "{ROOT}/not-a-dir", "--no-gh"),
		state("state-cwd-gone-json", "--cwd", "{ROOT}/not-a-dir", "--no-gh", "--json"),
		state("state-cwd-not-repo", "--cwd", "{ROOT}/plain", "--no-gh"),
		state("state-cwd-not-repo-json", "--cwd", "{ROOT}/plain", "--no-gh", "--json"),
		scn{name: "state-cwd-file", cmd: "resume-state", args: []string{"--cwd", "{R}/a", "--no-gh"}},
		scn{name: "state-bare", cmd: "resume-state", world: "bare", cwd: "r", args: []string{"--no-gh"}},
		scn{name: "state-cwd-empty", cmd: "resume-state", args: []string{"--cwd", "", "--no-gh"}},
	)
	// degraded
	add(
		scn{name: "state-nojq", cmd: "resume-state", path: "nojq", args: []string{"--no-gh"}},
		scn{name: "state-nojq-json", cmd: "resume-state", path: "nojq", args: []string{"--no-gh", "--json"}},
		scn{name: "state-nogit", cmd: "resume-state", path: "nogit", args: []string{"--no-gh"}},
		scn{name: "state-nogit-json", cmd: "resume-state", path: "nogit", args: []string{"--json", "--no-gh"}},
		scn{name: "state-nogit-help", cmd: "resume-state", path: "nogit", args: []string{"--help"}},
		scn{name: "state-nojq-bogus", cmd: "resume-state", path: "nojq", args: []string{"--bogus"}},
		scn{name: "state-nogit-badcwd", cmd: "resume-state", path: "nogit", args: []string{"--cwd", "{ROOT}/not-a-dir"}},
	)

	// resume-render over documents
	docs := renderDocs()
	names := make([]string, 0, len(docs))
	for n := range docs {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		add(scn{name: "render-doc-" + n, cmd: "resume-render", args: []string{"--json", "{IN}/" + n + ".json"}, files: map[string]string{n + ".json": docs[n]}})
	}
	add(
		scn{name: "render-stdin-ok", cmd: "resume-render", args: []string{"--json", "-"}, stdin: docOK},
		scn{name: "render-stdin-degraded", cmd: "resume-render", args: []string{"--json", "-"}, stdin: docDegraded},
		scn{name: "render-stdin-empty", cmd: "resume-render", args: []string{"--json", "-"}},
		scn{name: "render-stdin-bad", cmd: "resume-render", args: []string{"--json", "-"}, stdin: "{"},
		scn{name: "render-file-absent", cmd: "resume-render", args: []string{"--json", "{IN}/absent.json"}},
		scn{name: "render-file-dir", cmd: "resume-render", args: []string{"--json", "{ROOT}"}},
		scn{name: "render-file-dash", cmd: "resume-render", cwd: "in", args: []string{"--json", "-state.json"}, files: map[string]string{"-state.json": docOK}},
		scn{name: "render-file-dot-slash-dash", cmd: "resume-render", cwd: "in", args: []string{"--json", "./-state.json"}, files: map[string]string{"-state.json": docOK}},
		scn{name: "render-json-missing-value", cmd: "resume-render", args: []string{"--json"}},
		scn{name: "render-json-empty-value", cmd: "resume-render", args: []string{"--json", ""}},
		scn{name: "render-json-empty-nogh", cmd: "resume-render", args: []string{"--json", "", "--no-gh"}},
		scn{name: "render-json-and-nogh", cmd: "resume-render", args: []string{"--json", "{IN}/x.json", "--no-gh"}, files: map[string]string{"x.json": docOK}},
		scn{name: "render-json-and-cwd", cmd: "resume-render", args: []string{"--cwd", "{R}", "--json", "{IN}/x.json"}, files: map[string]string{"x.json": docOK}},
		scn{name: "render-json-and-base", cmd: "resume-render", args: []string{"--base-ref", "main", "--json", "{IN}/x.json"}, files: map[string]string{"x.json": docOK}},
		scn{name: "render-json-twice", cmd: "resume-render", args: []string{"--json", "{IN}/x.json", "--json", "{IN}/y.json"}, files: map[string]string{"x.json": docOK, "y.json": docEmpty}},
		scn{name: "render-help", cmd: "resume-render", args: []string{"--help"}},
		scn{name: "render-help-short", cmd: "resume-render", args: []string{"-h"}},
		scn{name: "render-help-after-json", cmd: "resume-render", args: []string{"--json", "--help"}},
		scn{name: "render-bogus", cmd: "resume-render", args: []string{"--bogus"}},
		scn{name: "render-positional", cmd: "resume-render", args: []string{"stray"}},
		scn{name: "render-cwd-missing-value", cmd: "resume-render", args: []string{"--cwd"}},
		scn{name: "render-base-missing-value", cmd: "resume-render", args: []string{"--base-ref"}},
		scn{name: "render-nojq", cmd: "resume-render", path: "nojq", args: []string{"--json", "{IN}/x.json"}, files: map[string]string{"x.json": docOK}},
		scn{name: "render-nojq-selfrun", cmd: "resume-render", path: "nojq", args: []string{"--no-gh"}},
		scn{name: "render-nojq-help", cmd: "resume-render", path: "nojq", args: []string{"--help"}},
		scn{name: "render-nojq-bogus", cmd: "resume-render", path: "nojq", args: []string{"--bogus"}},
		scn{name: "render-nojq-conflict", cmd: "resume-render", path: "nojq", args: []string{"--json", "x", "--no-gh"}},
	)
	// resume-render, self-run mode: the sibling resume-state runs and its document is rendered
	add(
		scn{name: "render-self-nogh", cmd: "resume-render", args: []string{"--no-gh"}, toolbl: true},
		scn{name: "render-self-cwd", cmd: "resume-render", cwd: ".", args: []string{"--cwd", "{R}", "--no-gh"}, toolbl: true},
		scn{name: "render-self-base", cmd: "resume-render", args: []string{"--no-gh", "--base-ref", "loose"}, toolbl: true},
		scn{name: "render-self-gh-ok", cmd: "resume-render", path: "gh:ok", toolbl: true},
		scn{name: "render-self-gh-empty", cmd: "resume-render", path: "gh:empty", toolbl: true},
		scn{name: "render-self-gh-bad", cmd: "resume-render", path: "gh:bad", toolbl: true},
		scn{name: "render-self-gh-full", cmd: "resume-render", path: "gh:full", toolbl: true},
		scn{name: "render-self-gh-missing", cmd: "resume-render", path: "nogh", toolbl: true},
		scn{name: "render-self-plain", cmd: "resume-render", world: "plain", args: []string{"--no-gh"}, toolbl: true},
		scn{name: "render-self-bulk", cmd: "resume-render", world: "bulk", args: []string{"--no-gh"}, toolbl: true},
		scn{name: "render-self-bad-cwd", cmd: "resume-render", args: []string{"--cwd", "{ROOT}/not-a-dir", "--no-gh"}, toolbl: true},
		scn{name: "render-self-bad-base", cmd: "resume-render", args: []string{"--no-gh", "--base-ref", "no-such-ref"}, toolbl: true},
		scn{name: "render-self-no-base", cmd: "resume-render", world: "nobase", args: []string{"--no-gh"}, toolbl: true},
		scn{name: "render-self-not-repo", cmd: "resume-render", args: []string{"--cwd", "{ROOT}/plain", "--no-gh"}, toolbl: true},
		scn{name: "render-self-nogit", cmd: "resume-render", path: "nogit", args: []string{"--no-gh"}, toolbl: true},
		scn{name: "render-self-dash-base", cmd: "resume-render", args: []string{"--no-gh", "--base-ref", "-x"}, toolbl: true},
	)
	return out
}
