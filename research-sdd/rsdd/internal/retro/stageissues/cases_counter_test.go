package stageissues

import "strings"

// casesCounter: the covers_through counter-reset proposal (kit issue #1640): the grammar of the retro line, the state
// files it can name, and every not-proposed state.
func casesCounter() []dcase {
	one := doc(pending, row("1", "first delta of the retro", "CLAUDE.md", "B1", "fix", "LOW"))
	const st = "rh/target-foo/"
	files := func(names ...string) map[string]string {
		m := map[string]string{}
		for _, n := range names {
			m[st+n] = "# state\n"
		}
		return m
	}
	mk := func(name string, lines []string, fs map[string]string, args ...string) dcase {
		c := dcase{name: "counter/" + name, retro: one + "\n" + strings.Join(lines, "\n") + "\n", files: fs, args: args}
		return c
	}
	cov := func(v string) []string { return []string{"covers_through: " + v} }
	var out []dcase
	root, alpha, beta := "RESEARCH-STATE.md", "RESEARCH-STATE-alpha.md", "RESEARCH-STATE-beta.md"
	out = append(out,
		mk("unscoped-root-only", cov("B7"), files(root)),
		mk("unscoped-root-only-apply", cov("B7"), files(root), "--apply"),
		mk("unscoped-no-state", cov("B7"), nil),
		mk("unscoped-lone-slugged", cov("B7"), files(alpha)),
		mk("unscoped-several", cov("B7"), files(root, alpha)),
		mk("focus-alpha", cov("B12 focus=alpha"), files(root, alpha, beta)),
		mk("focus-root", cov("B12 focus=root"), files(root, alpha)),
		mk("focus-no-match", cov("B12 focus=gamma"), files(root, alpha)),
		mk("focus-no-state", cov("B12 focus=alpha"), nil),
		mk("focus-two-matches", cov("B12 focus=alpha"), files(alpha, "sub/"+alpha)),
		mk("focus-with-dots-and-dashes", cov("B3 focus=a.b-c_d"), files("RESEARCH-STATE-a.b-c_d.md")),
		mk("focus-trailing-blanks", []string{"covers_through: B3 focus=alpha \t"}, files(alpha)),
		mk("value-leading-tab", []string{"covers_through:\tB3"}, files(root)),
		mk("value-crlf", []string{"covers_through: B3\r"}, files(root)),
		mk("value-nine-digits", cov("B123456789"), files(root)),
		mk("value-ten-digits", cov("B1234567890"), files(root)),
		mk("value-zero", cov("B0"), files(root)),
		mk("malformed-no-b", cov("7"), files(root)),
		mk("malformed-lowercase-b", cov("b7"), files(root)),
		mk("malformed-trailing-text", cov("B7x"), files(root)),
		mk("malformed-focus-chars", cov("B7 focus=a/b"), files(root)),
		mk("malformed-empty-focus", cov("B7 focus="), files(root)),
		mk("malformed-two-focus", cov("B7 focus=a focus=b"), files(root, alpha)),
		mk("malformed-indented", []string{"  covers_through: B7"}, files(root)),
		mk("malformed-and-valid", []string{"covers_through: B7x", "covers_through: B8"}, files(root)),
		mk("two-valid", []string{"covers_through: B7", "covers_through: B9 focus=alpha"}, files(root, alpha)),
		mk("prose-not-parsed", []string{"coverage through B140", "covers through B140"}, files(root)),
		mk("fenced-backticks", []string{"```", "covers_through: B7", "```"}, files(root)),
		mk("fenced-tildes", []string{"~~~", "covers_through: B7", "~~~"}, files(root)),
		mk("fence-closed-by-other-mark-stays-open", []string{"```", "~~~", "covers_through: B7", "```"}, files(root)),
		mk("fence-open-until-end", []string{"```", "covers_through: B7"}, files(root)),
		mk("fence-then-line-after", []string{"```", "x", "```", "covers_through: B7"}, files(root)),
		mk("fence-indented-is-not-a-fence", []string{"  ```", "covers_through: B7"}, files(root)),
		mk("no-field", nil, files(root)),
		mk("template-ignored", cov("B7"), files("RESEARCH-STATE.template.md")),
		mk("template-and-root", cov("B7"), files(root, "RESEARCH-STATE.template.md")),
		mk("git-dir-ignored", cov("B7"), files(".git/RESEARCH-STATE.md")),
		mk("nested-two-levels", cov("B7 focus=alpha"), files("a/b/"+alpha)),
		mk("nested-too-deep", cov("B7 focus=alpha"), files("a/b/c/d/"+alpha)),
		mk("not-md-ignored", cov("B7"), map[string]string{st + "RESEARCH-STATE.txt": "x"}),
		mk("prefix-only", cov("B7 focus=root"), files("RESEARCH-STATE-.md")),
	)
	return out
}
