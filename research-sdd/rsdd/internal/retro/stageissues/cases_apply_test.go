package stageissues

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// applyCase is a --apply case; kv are env pairs (STUB_MODE, STUB_LABEL, ...).
func applyCase(name, retro string, kv ...string) dcase {
	c := dcase{name: "apply/" + name, retro: retro, args: []string{"--apply"}}
	return c.withEnv(kv...)
}

// seed makes the stub's state files (name -> content; empty content is an empty file).
func (c dcase) seed(files map[string]string) dcase {
	c.stub = func(dir string) {
		for n, v := range files {
			if err := os.WriteFile(filepath.Join(dir, n), []byte(v), 0o644); err != nil {
				panic(err)
			}
		}
	}
	return c
}

func occList(titles ...string) string {
	var parts []string
	for i, t := range titles {
		parts = append(parts, `{"number":`+string(rune('5'))+string(rune('5'+i))+`,"state":"OPEN","title":"`+t+`"}`)
	}
	return "[" + strings.Join(parts, ",") + "]\n"
}

// casesApply: --apply against the fake gh (old suite 8-10, 16, 75-76, 81, 84, 87).
func casesApply() []dcase {
	rows := threeRows()
	two := doc(pending, rows[0], rows[1])
	one := doc(pending, rows[0])
	var out []dcase
	for _, m := range []string{"nomatch", "match", "matchclosed", "listfail", "listempty", "createfail", "createnourl", "createfailcreated",
		"createfailrelistfail", "createfailsecond", "fuzzyother", "fuzzyotherclosed", "fuzzylongid", "fuzzyplusexact", "crlfsig",
		"sigonly", "nullbody", "badjson", "page2"} {
		out = append(out, applyCase("mode-"+m, two, "STUB_MODE", m))
	}
	for _, v := range []string{"ok", "nosig", "empty", "fail"} {
		out = append(out, applyCase("view-"+v, two, "STUB_VIEW", v))
	}
	for _, l := range []string{"exists", "existsupper", "missing", "listfail", "listempty", "createfail", "failjson", "racewin", "fuzzyonly"} {
		out = append(out, applyCase("label-"+l, two, "STUB_LABEL", l))
	}
	out = append(out,
		applyCase("noauth", one, "STUB_MODE", "noauth"),
		func() dcase { c := applyCase("no-gh", one); c.path = "nogh"; return c }(),
		applyCase("limit-2-page-full", one, "STUB_MODE", "page2", "STAGE_RETRO_ISSUES_LIST_LIMIT", "2"),
		applyCase("limit-3-page-not-full", one, "STUB_MODE", "page2", "STAGE_RETRO_ISSUES_LIST_LIMIT", "3"),
		applyCase("limit-full-but-exact-hit", one, "STUB_MODE", "fuzzyplusexact", "STAGE_RETRO_ISSUES_LIST_LIMIT", "2"),
		applyCase("limit-zero", one, "STAGE_RETRO_ISSUES_LIST_LIMIT", "0"),
		// one open row whose create fails: failed=1 exactly and exit 2 (old suite 16b, kit issue #949 item 4)
		applyCase("single-createfail", one, "STUB_MODE", "createfail"),
		applyCase("limit-text", one, "STAGE_RETRO_ISSUES_LIST_LIMIT", "ten"),
		applyCase("limit-negative", one, "STAGE_RETRO_ISSUES_LIST_LIMIT", "-5"),
		applyCase("limit-leading-zeros", one, "STAGE_RETRO_ISSUES_LIST_LIMIT", "007"),
		applyCase("limit-00", one, "STAGE_RETRO_ISSUES_LIST_LIMIT", "00"),
		applyCase("limit-huge", one, "STAGE_RETRO_ISSUES_LIST_LIMIT", "99999999999999999999"),
		dry("apply/limit-invalid-in-dry-run", one).withEnv("STAGE_RETRO_ISSUES_LIST_LIMIT", "x1"),
		applyCase("partial-skips-shipped", doc(partialMarker, rows...)),
		applyCase("partial-dismissed", doc("<!-- review-status: applied · a · PARTIAL — shipped: 1; DISMISSED: 2 -->", rows...)),
		applyCase("applied-nothing-to-do", doc(applied, rows...)),
		applyCase("wrong-kit-and-unusable-title", doc(pending, row("1", "wrong kit delta title here", "z-kit:x", "B1", "fix", "LOW"), row("2", "short", "x.md", "B1", "fix", "LOW"), rows[2])),
		applyCase("same-title-twice-in-one-retro", doc(pending, row("1", "identical delta title here", "x.md", "B1", "fix", "LOW"), row("2", "identical delta title here", "x.md", "B1", "fix", "LOW"))),
		applyCase("same-title-create-unknown-then-next", doc(pending, row("1", "identical delta title here", "x.md", "B1", "fix", "LOW"), row("2", "identical delta title here", "x.md", "B1", "fix", "LOW")), "STUB_MODE", "createnourl").seed(map[string]string{"occ2": occList("identical delta title here")}),
		applyCase("many-rows-mixed", doc(pending, append(threeRows(), row("4", "fourth delta of the retro", "y.md", "B4", "bug", "HIGH"))...), "STUB_MODE", "createfailsecond"),
	)
	// registered name != path basename: the legacy `<basename>/retros/...` signature is searched too
	renamed := func(c dcase) dcase {
		c.prep = func(t *testing.T, b *box) {
			write(t, filepath.Join(b.root, "research-sdd", "TARGETS.md"), "| # | Target | Path |\n|---|---|---|\n| 1 | alpha-name | `"+b.root+"/rh/target-foo` |\n")
		}
		return c
	}
	const legacy = "Source retro: target-foo/retros/r.md"
	out = append(out,
		renamed(applyCase("legacy-sig-new-name-nomatch", one)),
		renamed(applyCase("legacy-sig-open", one, "STUB_MODE", "matchsig", "STUB_SIGPAT", legacy)),
		renamed(applyCase("legacy-sig-closed", one, "STUB_MODE", "matchsigclosed", "STUB_SIGPAT", legacy)),
		renamed(applyCase("legacy-sig-lookup-fails", one, "STUB_MODE", "failsig", "STUB_SIGPAT", legacy)),
		renamed(applyCase("legacy-sig-new-name-open", one, "STUB_MODE", "matchsig", "STUB_SIGPAT", "alpha-name/retros")),
		renamed(applyCase("legacy-sig-fuzzy-other", one, "STUB_MODE", "fuzzyother")),
		renamed(applyCase("legacy-sig-page-full", one, "STUB_MODE", "page2", "STAGE_RETRO_ISSUES_LIST_LIMIT", "2")),
		renamed(dry("apply/registered-name-dry", one)),
	)
	// the target label of an unregistered target is never auto-created
	unreg := func(c dcase) dcase {
		c.prep = func(t *testing.T, b *box) {
			write(t, filepath.Join(b.root, "research-sdd", "TARGETS.md"), "| # | Target | Path |\n|---|---|---|\n| 1 | other | `"+b.root+"/rh/other` |\n")
		}
		return c
	}
	out = append(out, unreg(applyCase("unregistered-target", one)), unreg(dry("apply/unregistered-target-dry", one)))
	return out
}

// casesOccurrence: the occurrence comment surface (old suite 88).
func casesOccurrence() []dcase {
	rows := threeRows()
	one := doc(pending, rows[0])
	title := "first delta of the retro"
	const (
		okCommented = "r"
	)
	_ = okCommented
	var out []dcase
	add := func(name string, files map[string]string, kv ...string) {
		out = append(out, applyCase("occ/"+name, one, kv...).seed(files))
	}
	add("one-open-match", map[string]string{"occ": occList(title)})
	add("two-open-matches", map[string]string{"occ": occList(title, title)})
	add("closed-and-near-title", map[string]string{"occ": `[{"number":9,"state":"CLOSED","title":"` + title + `"},{"number":8,"state":"OPEN","title":"` + title + ` x"}]` + "\n"})
	add("no-candidates", nil)
	add("lookup-fails", map[string]string{"occfail": ""})
	add("lookup-truncated", map[string]string{"occnoend": ""})
	add("lookup-empty-reply", map[string]string{"occ": ""})
	add("comment-fails", map[string]string{"occ": occList(title), "commentfail": ""})
	add("comment-fails-one-of-two", map[string]string{"occ": occList(title, title), "commentfail.56": ""})
	add("comment-fails-first-of-two", map[string]string{"occ": occList(title, title), "commentfail.55": ""})
	add("comment-ghost-no-marker", map[string]string{"occ": occList(title), "commentghost": ""})
	add("comment-ghost-second-only", map[string]string{"occ": occList(title, title), "commentghost.56": ""})
	add("comment-no-url", map[string]string{"occ": occList(title), "commentnourl": ""})
	add("comment-failed-but-wrote", map[string]string{"occ": occList(title), "commentfailwrote": ""})
	add("comment-fails-and-reread-fails", map[string]string{"occ": occList(title), "commentfail": "", "viewfailafter": "2"})
	add("pre-view-fails", map[string]string{"occ": occList(title), "viewfail": ""})
	add("readback-view-fails", map[string]string{"occ": occList(title), "viewfailafter": "2"})
	add("already-marked", map[string]string{"occ": occList(title), "comments.55": "<!-- stage-retro-issues:occurrence Source retro: target-foo/retros/r.md · 1 -->\n"})
	add("already-marked-crlf", map[string]string{"occ": occList(title), "comments.55": "<!-- stage-retro-issues:occurrence Source retro: target-foo/retros/r.md · 1 -->\r\n"})
	add("escaped-title", map[string]string{"occ": `[{"number":55,"state":"OPEN","title":"first delta of the retro"}]` + "\n"})
	add("title-with-quotes", map[string]string{"occ": `[{"number":55,"state":"OPEN","title":"say <hi>"}]` + "\n"})
	add("pretty-printed-array", map[string]string{"occ": "[\n  {\n    \"number\": 55,\n    \"state\": \"OPEN\",\n    \"title\": \"" + title + "\"\n  }\n]\n"})
	add("nested-array-in-object", map[string]string{"occ": `[{"labels":[{"name":"x"}],"number":55,"state":"OPEN","title":"` + title + `"}]` + "\n"})
	add("non-numeric-number", map[string]string{"occ": `[{"number":"55","state":"OPEN","title":"` + title + `"}]` + "\n"})
	add("lookup-limit-hit", map[string]string{"occ": occList(title, "b", "c")}, "STAGE_RETRO_ISSUES_LIST_LIMIT", "3")
	add("lookup-limit-below", map[string]string{"occ": occList("b", "c")}, "STAGE_RETRO_ISSUES_LIST_LIMIT", "3")
	out = append(out,
		applyCase("occ/three-rows-lookup-once", doc(pending, rows...)).seed(map[string]string{"occ": occList(title)}),
		applyCase("occ/three-rows-lookup-fails", doc(pending, rows...)).seed(map[string]string{"occfail": ""}),
		applyCase("occ/dry-run-offline", one).withArgs().seed(map[string]string{"occ": occList(title)}),
		applyCase("occ/scrubbed-comment", doc(pending, row("1", "delta mentions /home/bob/secret and bob@example.com", "x.md", "B1", "fix", "LOW"))).seed(map[string]string{"occ": occList("delta mentions <path> and <email>")}),
	)
	return out
}
