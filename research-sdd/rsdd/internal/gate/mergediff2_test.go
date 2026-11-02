//go:build !nodiff

package gate

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func lookPath(name string) (string, error) { return exec.LookPath(name) }

func readFixture(w *world, name string) string {
	b, err := os.ReadFile(mgFixtures + "/" + name)
	if err != nil {
		w.t.Fatal(err)
	}
	return string(b)
}

func (r *diffRig) pathFilters() {
	w := r.w
	fx := func(n string) string { return readFixture(w, n) }
	for _, name := range []string{"paths", "ignore", "negation", "nofilter", "push-only", "real-toolbelt-tests", "quoted-id", "name-expr", "jobs-flow", "jobs4", "prt", "merge-group", "inline", "narrow", "docs-paths"} {
		text := fx("wf-" + name + ".yml")
		w.workflowRepo("wf-"+name, text, text, nil)
	}
	w.workflowRepo("wf-selfx", fx("wf-paths.yml"), fx("wf-narrow.yml"), nil)
	w.workflowRepo("wf-bothnarrow", fx("wf-narrow.yml"), fx("wf-narrow.yml"), nil)
	multi := func(key, a, z string, extra map[string]string) {
		ex := map[string]string{"a-first.yml": fx(a), "z-last.yml": fx(z)}
		for k, v := range extra {
			ex[k] = v
		}
		w.workflowRepo(key, fx(a), fx(a), ex)
	}
	multi("wf-multi-ab", "wf-paths.yml", "wf-docs-paths.yml", nil)
	multi("wf-multi-ba", "wf-docs-paths.yml", "wf-paths.yml", nil)
	multi("wf-multi-bothskip", "wf-paths.yml", "wf-paths.yml", nil)
	multi("wf-multi-nopr", "wf-paths.yml", "wf-push-only.yml", nil)
	multi("wf-real2", "wf-real-toolbelt-tests.yml", "wf-real-pr-check.yml", nil)
	w.workflowRepo("wf-gitlink", fx("wf-paths.yml"), fx("wf-paths.yml"), map[string]string{"a-first.yml": fx("wf-paths.yml")})
	w.git("wf-gitlink", "update-index", "--add", "--cacheinfo", "160000,0123456789abcdef0123456789abcdef01234567,.github/workflows/zz-sub.yml")
	w.git("wf-gitlink", "commit", "-q", "--amend", "--no-edit")
	badPats := []string{"**/x.md", "a/**/b", "docs/[a-z]*.md", "docs/+x", "docs/{a,b}", "**.md", "docs/**/x", "docs/a b", "docs/?.md", "docs/a?"}
	for i, pat := range badPats {
		text := fmt.Sprintf("name: t\non:\n  pull_request:\n    paths:\n      - \"%s\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n", pat)
		w.workflowRepo(fmt.Sprintf("wf-bad%d", i), text, text, nil)
	}
	// odd shapes of the scanner: CRLF, tabs, comments, quoted values, duplicate job ids, empty items, other triggers
	shapes := map[string]string{
		"crlf":          strings.ReplaceAll(fx("wf-paths.yml"), "\n", "\r\n"),
		"tabs":          strings.ReplaceAll(fx("wf-paths.yml"), "    paths:", "    paths:\t"),
		"emptyitem":     "on:\n  pull_request:\n    paths:\n      -\n      - \"docs/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"onlyempty":     "on:\n  pull_request:\n    paths:\n      -\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"flowpaths":     "on:\n  pull_request:\n    paths: [\"docs/**\"]\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"prinline":      "on: pull_request\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"nojobs":        "on:\n  pull_request:\n    paths:\n      - \"docs/**\"\n",
		"dupjob":        "on:\n  pull_request:\n    paths:\n      - \"nothing/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  toolbelt-tests:\n    name: other\n  shellcheck:\n    runs-on: x\n",
		"quotedname":    "on:\n  pull_request:\n    paths:\n      - \"nothing/**\"\njobs:\n  a:\n    name: 'toolbelt-tests'\n  b:\n    name: \"shellcheck\" # c\n",
		"anchorname":    "on:\n  pull_request:\n    paths:\n      - \"nothing/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  b:\n    name: *anchor\n",
		"emptyname":     "on:\n  pull_request:\n    paths:\n      - \"nothing/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  b:\n    name:\n",
		"commentpat":    "on:\n  pull_request:\n    paths:\n      - nothing/** # why\n      - 'docs/*.md'\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"extrakey":      "on:\n  pull_request:\n    branches:\n      - main\n    paths:\n      - \"docs/**\"\n    types: [opened]\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"othertop":      "env:\n  A: b\non:\n  pull_request:\n    paths:\n      - \"nothing/**\"\npermissions:\n  contents: read\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"jobskey":       "on:\n  pull_request:\n    paths:\n      - \"nothing/**\"\njobs:\n  - bad\n",
		"jobsflowkey":   "on:\n  pull_request:\n    paths:\n      - \"nothing/**\"\njobs:  \n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"matrixname":    "on:\n  pull_request:\n    paths:\n      - \"nothing/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n  other:\n    name: x-${{ matrix.y }}\n",
		"onheadcomment": "on: # triggers\n  pull_request: # pr\n    paths: # p\n      - \"nothing/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"pathsdotslash": "on:\n  pull_request:\n    paths:\n      - \"./docs/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"atsign":        "on:\n  pull_request:\n    paths:\n      - \"a/@@DS@@\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
		"exactdir":      "on:\n  pull_request:\n    paths:\n      - \"/**\"\n      - \"x/*\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n",
	}
	var shapeNames []string
	for n, text := range shapes {
		w.workflowRepo("wf-shape-"+n, text, text, nil)
		shapeNames = append(shapeNames, n)
	}

	p := w.assessFile("false", "passive")
	checksDoc := r.ck("pr-validation:completed:success")
	files := func(entries ...string) string {
		var es []string
		for _, n := range entries {
			es = append(es, fmt.Sprintf(`{"status":"added","filename":%q}`, n))
		}
		return w.file("[" + strings.Join(es, ",") + "]\n")
	}
	docs := files("odd/tasks/x.md", "docs/yy.md")
	tool := files("research-sdd/toolbelt/merge-gate.sh")
	one := func(repo, name string, fileList string, extra ...string) {
		env := append([]string{"STUB_CHECKS_JSON=" + checksDoc, "STUB_FILES_JSON=" + fileList}, extra...)
		r.add(r.mg("pf "+name, repo, p, with(argsMerge, "--no-closure-evidence"), env...))
	}
	for _, name := range []string{"paths", "ignore", "negation", "nofilter", "push-only", "real-toolbelt-tests", "quoted-id", "name-expr", "jobs-flow", "jobs4", "prt", "merge-group", "inline", "narrow", "selfx", "bothnarrow", "multi-ab", "multi-ba", "multi-bothskip", "multi-nopr", "real2", "gitlink"} {
		repo := "wf-" + name
		one(repo, name+" docs", docs)
		one(repo, name+" tool", tool)
	}
	for i := range badPats {
		one(fmt.Sprintf("wf-bad%d", i), fmt.Sprintf("bad pattern %d", i), files("docs/yy.md"))
	}
	for _, n := range shapeNames {
		for fi, fl := range []string{docs, tool, files("docs/a.md"), files("x/y"), files("a/@@DS@@"), files("a/zzz")} {
			one("wf-shape-"+n, fmt.Sprintf("shape %s files %d", n, fi), fl)
		}
	}
	matches := []string{"research-sdd/toolbelt/x.sh", "research-sdd/METHODOLOGY.md", "research-sdd/METHODOLOGY.mdx", "research-sdd/METHODOLOGYxmd", "x/research-sdd/toolbelt/y.sh",
		"configs/a/b.cfg", "configs/a.cfg", "tools/a/b/c.py", "tools", "research-sdd/push-only/a.sh", "research-sdd/profiles/p.md", ".github/workflows/toolbelt-tests.yml"}
	for i, m := range matches {
		one("wf-paths", fmt.Sprintf("match %d", i), files(m))
		one("wf-real-toolbelt-tests", fmt.Sprintf("real match %d", i), files(m))
	}
	one("wf-paths", "mixed first", files("tools/gen.py", "docs/a.md", "odd/b.md"))
	one("wf-paths", "mixed middle", files("docs/a.md", "tools/gen.py", "odd/b.md"))
	one("wf-paths", "mixed last", files("docs/a.md", "odd/b.md", "tools/gen.py"))
	for i, f := range [][]string{{".github/workflows/toolbelt-tests.yml", "odd/a.md"}, {"odd/a.md", ".github/workflows/other.yml", "odd/b.md"}, {"odd/a.md", ".github/workflows/new.yml"}, {".githubx/workflows/a.yml", "odd/a.md"}} {
		one("wf-bothnarrow", fmt.Sprintf("workflow change %d", i), files(f...))
	}
	var many, few []string
	for i := 0; i < 3000; i++ {
		many = append(many, fmt.Sprintf("odd/f%d.md", i))
		if i < 2999 {
			few = append(few, fmt.Sprintf("odd/f%d.md", i))
		}
	}
	one("wf-paths", "3000 files", files(many...))
	one("wf-paths", "2999 files", files(few...))
	one("wf-paths", "no changed files", w.file("[]\n"))
	one("wf-paths", "empty files answer", w.file(""))
	one("wf-paths", "malformed files", w.file("{nope\n"))
	one("wf-paths", "files not an array", w.file(`{"a":1}`+"\n"))
	one("wf-paths", "files entry not an object", w.file("[3]\n"))
	one("wf-paths", "files null entry", w.file("[null]\n"))
	one("wf-paths", "files without filename", w.file(`[{"status":"added"}]`+"\n"))
	one("wf-paths", "files numeric filename", w.file(`[{"filename":5}]`+"\n"))
	one("wf-paths", "files renamed", w.file(`[{"status":"renamed","filename":"docs/new.md","previous_filename":"tools/old.py"}]`+"\n"))
	one("wf-paths", "files renamed docs", w.file(`[{"status":"renamed","filename":"docs/new.md","previous_filename":"odd/old.md"}]`+"\n"))
	one("wf-paths", "files two pages", w.file(`[{"filename":"docs/a.md"}]`+"\n"+`[{"filename":"odd/b.md"}]`+"\n"))
	one("wf-paths", "files page not array", w.file(`[{"filename":"docs/a.md"}]`+"\n"+`{"x":1}`+"\n"))
	one("wf-paths", "files newline name", w.file(`[{"filename":"docs/a.md\nresearch-sdd/toolbelt/x"}]`+"\n"))
	one("wf-paths", "files fail", docs, "STUB_FILES_FAIL=1")
	one("wf-paths", "nothing missing", docs, "MERGE_GATE_REQUIRED_CHECKS=pr-validation")
	one("wf-paths", "required name no job", docs, "MERGE_GATE_REQUIRED_CHECKS=shellcheck,nope")
	one("wf-paths", "required name with backslash", docs, "MERGE_GATE_REQUIRED_CHECKS=a\\\\b")
	one("wf-paths", "required name duplicate", docs, "MERGE_GATE_REQUIRED_CHECKS=shellcheck,shellcheck")
	one("wf-paths", "one reported green", docs, "STUB_CHECKS_JSON="+r.ck("pr-validation:completed:success", "toolbelt-tests:completed:success"))
	one("wf-paths", "one reported failed", docs, "STUB_CHECKS_JSON="+r.ck("pr-validation:completed:success", "toolbelt-tests:completed:failure"))
	one("wf-paths", "docs but pr-validation failed", docs, "STUB_CHECKS_JSON="+r.ck("pr-validation:completed:failure"))
	one("wf-paths", "docs but pending", docs, "STUB_CHECKS_JSON="+r.ck("pr-validation:in_progress:"))
	// no workflows at HEAD (the plain repo has no .github)
	r.add(r.mg("pf no workflows", "repo", p, with(argsMerge, "--no-closure-evidence"), "STUB_CHECKS_JSON="+checksDoc, "STUB_FILES_JSON="+docs))
	// a PR base without the workflow while the head has it
	w.initRepo("wf-nobase")
	w.write(w.repos["wf-nobase"]+"/x", "x")
	w.git("wf-nobase", "add", "x")
	w.commit("wf-nobase", "c0")
	w.git("wf-nobase", "tag", "base")
	w.write(w.repos["wf-nobase"]+"/.github/workflows/toolbelt-tests.yml", fx("wf-narrow.yml"))
	w.git("wf-nobase", "add", "-A")
	w.commit("wf-nobase", "head")
	one("wf-nobase", "base tree without workflows", docs)
	// pull_request.paths listing with the pr empty: --merge "" is outside the contract and is not compared
}

func (r *diffRig) closure() {
	w := r.w
	p := w.assessFile("false", "passive")
	ckCE := r.ck("pr-validation:completed:success")
	ce := func(name, files, gql string, extra ...string) {
		env := append([]string{"MERGE_GATE_REQUIRED_CHECKS=", "STUB_CHECKS_JSON=" + ckCE, "STUB_FILES_JSON=" + files, "STUB_GQL_JSON=" + gql}, extra...)
		r.add(r.mg("closure "+name, "repo", p, argsMerge, env...))
	}
	tests := w.file(ceTests + "\n")
	g := func(content string) string { return w.file(content + "\n") }
	ce("posted", tests, g(gql("true", "MERGED", hMerge, 2, "o/r#41", "o/r#42")))
	ce("posted one", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")))
	ce("none", tests, g(gql("true", "MERGED", hMerge, 0)))
	ce("cross", tests, g(gql("true", "MERGED", hMerge, 3, "o/r#41", "other/x#9", "O/R#43")))
	ce("big", tests, g(gql("true", "MERGED", hMerge, 51, "o/r#41")))
	ce("exactly 50", tests, g(gql("true", "MERGED", hMerge, 50, "o/r#41")))
	ce("unmerged", tests, g(gql("false", "MERGED", hMerge, 1, "o/r#41")))
	ce("open", tests, g(gql("true", "OPEN", hMerge, 1, "o/r#41")))
	ce("no oid", tests, g(gql("true", "MERGED", "null", 1, "o/r#41")))
	ce("short oid", tests, g(gql("true", "MERGED", "abc1234", 1, "o/r#41")))
	ce("nl oid", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"`+hMerge+`\n"},"closingIssuesReferences":{"totalCount":1,"nodes":[{"number":41,"repository":{"nameWithOwner":"o/r"}}]}}}}}`))
	ce("fork", tests, g(gqlRepo("acme/fork", "true", "MERGED", hMerge, 2, "acme/fork#41", "acme/fork#42")), "GH_REPO=acme/fork", "STUB_REPO_VIEW=o/r")
	ce("repo mismatch GH_REPO", tests, g(gql("true", "MERGED", hMerge, 2, "o/r#41")), "GH_REPO=acme/fork")
	ce("repo mismatch", tests, g(gqlRepo("other/y", "true", "MERGED", hMerge, 1, "other/y#41")))
	ce("GH_REPO three parts", tests, g(gqlRepo("o/r", "true", "MERGED", hMerge, 1, "o/r#41")), "GH_REPO=host/o/r")
	ce("GH_REPO one part", tests, g(gqlRepo("r/r", "true", "MERGED", hMerge, 1, "r/r#41")), "GH_REPO=r")
	ce("GH_REPO empty", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")), "GH_REPO=")
	ce("case-insensitive repo", tests, g(gqlRepo("O/R", "true", "MERGED", hMerge, 1, "O/R#41")))
	ce("repo view fails", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")), "STUB_REPO_VIEW_RC=1")
	ce("repo view garbage", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")), "STUB_REPO_VIEW=not a repo")
	ce("repo view empty", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")), "STUB_REPO_VIEW=")
	ce("gql fails", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")), "STUB_GQL_FAIL=1")
	ce("gql timeout", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")), "STUB_GQL_SLEEP=6", "MERGE_GATE_GH_TIMEOUT=1")
	ce("gql malformed", tests, g("{not json"))
	ce("gql empty", tests, "")
	ce("gql repository null", tests, g(`{"data":{"repository":null}}`))
	ce("gql no data", tests, g(`{}`))
	ce("gql data string", tests, g(`{"data":"x"}`))
	ce("gql pr null", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":null}}}`))
	ce("gql nodes missing", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","closingIssuesReferences":{"totalCount":1}}}}}`))
	ce("gql merge commit string", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":"x","closingIssuesReferences":{"totalCount":0,"nodes":[]}}}}}`))
	ce("gql two answers", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")+gql("true", "MERGED", hMerge, 1, "o/r#41")))
	ce("gql answer then number", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")+" 5"))
	ce("gql answer then garbage", tests, g(gql("true", "MERGED", hMerge, 1, "o/r#41")+" garbage"))
	ce("gql fractional numbers", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"`+hMerge+`"},"closingIssuesReferences":{"totalCount":4,"nodes":[{"number":0,"repository":{"nameWithOwner":"o/r"}},{"number":1.5,"repository":{"nameWithOwner":"o/r"}},{"number":"7","repository":{"nameWithOwner":"o/r"}},{"number":3,"repository":{"nameWithOwner":"o/r"}}]}}}}}`))
	ce("gql null repo node", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"`+hMerge+`"},"closingIssuesReferences":{"totalCount":2,"nodes":[{"number":5,"repository":{"nameWithOwner":null}},{"number":1,"repository":{"nameWithOwner":"o/r"}}]}}}}}`))
	ce("gql string node", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"`+hMerge+`"},"closingIssuesReferences":{"totalCount":2,"nodes":[{"number":9,"repository":{"nameWithOwner":"o/r"}},"x",{"number":1,"repository":{"nameWithOwner":"o/r"}}]}}}}}`))
	ce("gql unsorted dup", tests, g(gql("true", "MERGED", hMerge, 4, "o/r#100", "o/r#9", "o/r#100", "o/r#42")))
	ce("gql total float", tests, g(`{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"`+hMerge+`"},"closingIssuesReferences":{"totalCount":51.5,"nodes":[{"number":1,"repository":{"nameWithOwner":"o/r"}}]}}}}}`))
	gok := g(gql("true", "MERGED", hMerge, 2, "o/r#41", "o/r#42"))
	ce("no test file", w.file(filesWithStatus("modified:research-sdd/toolbelt/foo.sh", "modified:docs/x.md", "added:research-sdd/toolbelt/tests/fixtures/f.test.sh.txt")+"\n"), gok)
	ce("test on page 2", w.file(filesWithStatus("modified:docs/x.md")+"\n"+filesWithStatus("added:"+ceTestA)+"\n"), gok)
	var many, ten []string
	for i := 1; i <= 12; i++ {
		many = append(many, fmt.Sprintf("added:research-sdd/toolbelt/tests/t%02d.test.sh", i))
		if i <= 10 {
			ten = append(ten, many[len(many)-1])
		}
	}
	ce("twelve tests", w.file(filesWithStatus(many...)+"\n"), gok)
	ce("ten tests", w.file(filesWithStatus(ten...)+"\n"), gok)
	ce("tests unsorted dup", w.file(filesWithStatus("added:research-sdd/toolbelt/tests/b.test.sh", "added:research-sdd/install/tests/a.test.sh", "added:research-sdd/toolbelt/tests/b.test.sh")+"\n"), gok)
	ce("test path grammar", w.file(filesWithStatus("added:research-sdd/tests/a.test.sh", "added:research-sdd/a/b/tests/c.test.sh", "added:research-sdd/toolbelt/tests/x/a.test.sh", "added:research-sdd/toolbelt/tests/a.test.sh.x", "added:xresearch-sdd/toolbelt/tests/a.test.sh", "added:research-sdd/toolbelt/tests/.test.sh")+"\n"), gok)
	ce("files status missing", w.file(`[{"filename":"`+ceTestA+`"}]`+"\n"), gok)
	ce("files null", w.file("[null]\n"), gok)
	ce("files entry string", w.file(`["x"]`+"\n"), gok)
	ce("files not array", w.file(`{"a":1}`+"\n"), gok)
	ce("files malformed", w.file("{nope\n"), gok)
	ce("files empty", w.file(""), gok)
	ce("files fail", tests, gok, "STUB_FILES_FAIL=1")
	ce("comment fails", tests, gok, "STUB_COMMENT_RC=1")
	ce("opt-out", tests, gok, "STUB_NOOP=1")
	r.add(r.mg("closure opt-out flag", "repo", p, with(argsMerge, "--no-closure-evidence"), "MERGE_GATE_REQUIRED_CHECKS=", "STUB_CHECKS_JSON="+ckCE, "STUB_FILES_JSON="+tests, "STUB_GQL_JSON="+gok))
	r.add(r.mg("closure after failed merge", "repo", p, argsMerge, "MERGE_GATE_REQUIRED_CHECKS=", "STUB_MERGE_RC=1", "STUB_CHECKS_JSON="+ckCE, "STUB_FILES_JSON="+tests, "STUB_GQL_JSON="+gok))
	r.add(r.mg("closure --pr only", "repo", p, with(argsPlain, "--pr", "7"), "STUB_FILES_JSON="+tests, "STUB_GQL_JSON="+gok))
	r.add(r.mg("closure default run", "repo", p, argsPlain, "STUB_FILES_JSON="+tests, "STUB_GQL_JSON="+gok))
}
