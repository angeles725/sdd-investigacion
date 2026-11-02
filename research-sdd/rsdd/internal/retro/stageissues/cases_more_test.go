package stageissues

import (
	"strings"
	"testing"
)

// casesJSON: the hand-written JSON reader of the `gh issue list` replies (the bash used awk): every escape, a
// truncated or unbalanced reply, and a title that needs escaping to be searched.
func casesJSON() []dcase {
	title := "first delta of the retro"
	one := doc(pending, row("1", title, "CLAUDE.md", "B1", "fix", "LOW"))
	var out []dcase
	add := func(name, occ string) {
		out = append(out, applyCase("json/"+name, one).seed(map[string]string{"occ": occ}))
	}
	pre := `[{"number":55,"state":"OPEN","title":"`
	post := `"}]` + "\n"
	add("every-escape", pre+`a\nb\rc\td\be\ff\u0041\u00b7\u1234\"q\\z`+post)
	add("matching-title-then-escapes", `[{"number":55,"state":"OPEN","title":"`+title+`"},{"number":56,"state":"OPEN","title":"x\n\u0041"}]`+"\n")
	add("backslash-at-end", `[{"number":55,"state":"OPEN","title":"x\`)
	add("short-hex", pre+`\u12`+post)
	add("bad-hex", pre+`\uZZZZ`+post)
	add("unknown-escape", pre+`a\/b\qc`+post)
	add("unbalanced-close", `[{"number":55,"state":"OPEN","title":"x"}]]`+"\n")
	add("unbalanced-open", `[{"number":55,"state":"OPEN","title":"x"}`+"\n")
	add("empty-object", `[{}]`+"\n")
	add("not-an-object", `[1,2,3]`+"\n")
	add("nested-object-values", `[{"number":55,"state":"OPEN","labels":[{"name":"a"}],"meta":{"k":"v"},"title":"`+title+`"}]`+"\n")
	add("number-after-title", `[{"title":"`+title+`","state":"OPEN","number":55}]`+"\n")
	add("missing-number", `[{"state":"OPEN","title":"`+title+`"}]`+"\n")
	add("missing-state", `[{"number":55,"title":"`+title+`"}]`+"\n")
	add("closed-state-lowercase", `[{"number":55,"state":"closed","title":"`+title+`"}]`+"\n")
	add("number-with-spaces", "[{ \"number\" : 55 , \"state\" : \"OPEN\" , \"title\" : \""+title+"\" }]\n")
	add("title-null", `[{"number":55,"state":"OPEN","title":null}]`+"\n")
	add("whitespace-only", "  \n")
	add("object-not-array", `{"number":55}`+"\n")
	add("unicode-in-title", pre+`caf\u00e9 \u0041 \u00b7 \u0000`+post)
	// a delta whose title needs JSON escaping in the occurrence search, matched by the escaped form in the reply
	for name, text := range map[string]string{
		"quote":      `say "hello" to the world`,
		"backslash":  `fix the C:\temp path handling`,
		"tab":        "tab\tseparated delta title",
		"middle-dot": "delta with a middle dot \u00b7 in it",
		"unicode":    "r\u00e9sum\u00e9 handling delta title",
	} {
		c := doc(pending, row("1", text, "x.md", "B1", "fix", "LOW"))
		esc := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\t", `\t`).Replace(text)
		out = append(out, applyCase("json/title-"+name, c).seed(map[string]string{"occ": `[{"number":55,"state":"OPEN","title":"` + esc + `"}]` + "\n"}))
	}
	return out
}

// casesScrubMore: the credential-assignment forms of the privacy scrub (quoted, unterminated, empty, already
// redacted) and token boundaries.
func casesScrubMore() []dcase {
	var out []dcase
	for name, text := range map[string]string{
		"dq-value":             `set password="hunter two" in the config`,
		"sq-value":             `set token='abc def' in the config`,
		"bt-value":             "set secret=`abc def` in the config",
		"unterminated-dq":      `set password="abcdefgh in the config`,
		"empty-dq":             `set password="" in the config please`,
		"empty-value":          `set password= in the config please do`,
		"already-redacted":     `set password=<redacted> in the config`,
		"already-redacted-q":   `set password="<redacted>" in the config`,
		"not-a-credential-key": `set name=value in the config please`,
		"two-assignments":      `password=one api_key=two token=three here`,
		"upper-key":            `PASSWORD=hunter2 and Secret=abc in config`,
		"key-with-dots":        `db.password=hunter2 in the config file`,
		"sk-inside-word":       `xsk-abcdefghij1234567890 not a token here`,
		"sk-after-dash":        `a-sk-abcdefghij1234567890 and more text`,
		"akia-inside-word":     `XAKIAABCDEFGHIJKLMNOP not a key here`,
		"email-boundary":       `mail:bob@example.com,alice@example.org; done`,
		"path-boundaries":      `see (/home/bob/a.txt) and "/Users/bob/b.txt" now`,
		"bearer-lowercase":     `authorization: bearer abcdef0123456789 here`,
		"bearer-short":         `Authorization: Bearer abc is too short here`,
		"ghs-token":            `token ghs_abcdefghijklmnopqrstuvwxyz0123456789 here`,
		"url-userinfo":         `clone https://bob:hunter2@example.com/repo.git now`,
		"long-value-cut":       `password=` + strings.Repeat("a", 200) + ` trailing`,
	} {
		out = append(out, dry("scrub2/"+name, doc(pending, row("1", text, "x.md", "B1", "fix", "LOW"))))
	}
	return out
}

// TestRangeTooLargeIsATypedDegraded: a shipped range the grammar refuses to expand. The bash looped over it without a
// bound, so there is no legacy behaviour to compare: a declared divergence, pinned here.
func TestRangeTooLargeIsATypedDegraded(t *testing.T) {
	c := dcase{name: "range", retro: "<!-- review-status: applied · abc123 · PARTIAL — shipped: 1-999999999 -->\n" + doc("", row("1", "first delta of the retro", "x.md", "B1", "fix", "LOW")), args: []string{"--apply"}}
	c = c.resolve(t)
	b := mkBox(t, c)
	r := runGo(t, b, c)
	if r.RC != 1 || !strings.Contains(r.Stderr, "degraded: the review-status marker of r.md lists a shipped: range too large to expand (") {
		t.Fatalf("rc=%d stderr=%q", r.RC, r.Stderr)
	}
	if strings.Contains(r.GHLog, "issue create") {
		t.Errorf("nothing may be created: %s", r.GHLog)
	}
}
