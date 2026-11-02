package stageissues

import (
	"path/filepath"
	"testing"
)

// trackerRetro is a retro whose delta section the parser cannot classify, so the run proposes ONE tracking issue.
func trackerRetro(name string, args ...string) dcase {
	return dcase{name: name, fixture: "lessons-bullets.md", fixturePrefix: pending + "\n", args: args}
}

func trk(n, state string) string {
	return `{"number":` + n + `,"state":"` + state + `","body":"tracker\n\nUnclassifiable tracker: target-foo/retros/r.md\nUnclassifiable item set: 1"}`
}

// casesTracker: the unclassifiable tracking issue, dry-run and --apply (old siblings stage-retro-issues-unclassifiable).
func casesTracker() []dcase {
	apply := []string{"--apply"}
	var out []dcase
	out = append(out,
		trackerRetro("tracker/dry"),
		trackerRetro("tracker/apply-create", apply...),
		trackerRetro("tracker/apply-createfail", apply...).withEnv("STUB_MODE", "createfail"),
		trackerRetro("tracker/apply-createnourl", apply...).withEnv("STUB_MODE", "createnourl"),
		trackerRetro("tracker/apply-readback-nosig", apply...).withEnv("STUB_VIEW", "nosig"),
		trackerRetro("tracker/apply-readback-fail", apply...).withEnv("STUB_VIEW", "fail"),
		trackerRetro("tracker/apply-createfail-but-created", apply...).withEnv("STUB_MODE", "createfailcreated"),
		trackerRetro("tracker/apply-list-fails", apply...).withEnv("STUB_MODE", "listfail"),
		trackerRetro("tracker/apply-list-badjson", apply...).withEnv("STUB_MODE", "badjson"),
		trackerRetro("tracker/apply-list-filled-limit", apply...).withEnv("STUB_MODE", "page2", "STAGE_RETRO_ISSUES_LIST_LIMIT", "2"),
		trackerRetro("tracker/apply-item-set-open-dup", apply...).withEnv("STUB_MODE", "match"),
		trackerRetro("tracker/apply-item-set-closed-dup", apply...).withEnv("STUB_MODE", "matchclosed"),
		trackerRetro("tracker/apply-label-missing", apply...).withEnv("STUB_LABEL", "missing"),
		trackerRetro("tracker/apply-noauth", apply...).withEnv("STUB_MODE", "noauth"),
	)
	seedTrk := func(c dcase, files map[string]string) dcase { return c.seed(files) }
	out = append(out,
		seedTrk(trackerRetro("tracker/apply-one-open", apply...), map[string]string{"trkset": "[" + trk("50", "OPEN") + "]\n"}),
		seedTrk(trackerRetro("tracker/apply-one-open-comment-fails", apply...), map[string]string{"trkset": "[" + trk("50", "OPEN") + "]\n", "commentfail": ""}),
		seedTrk(trackerRetro("tracker/apply-one-open-already-commented", apply...), map[string]string{"trkset": "[" + trk("50", "OPEN") + "]\n"}),
		seedTrk(trackerRetro("tracker/apply-two-open-newest", apply...), map[string]string{"trkset": "[" + trk("50", "OPEN") + "," + trk("60", "OPEN") + "]\n"}),
		seedTrk(trackerRetro("tracker/apply-two-open-newest-first", apply...), map[string]string{"trkset": "[" + trk("60", "OPEN") + "," + trk("7", "OPEN") + "]\n"}),
		seedTrk(trackerRetro("tracker/apply-closed-only-new-set", apply...), map[string]string{"trkset": "[" + trk("50", "CLOSED") + "]\n"}),
		seedTrk(trackerRetro("tracker/apply-open-and-closed", apply...), map[string]string{"trkset": "[" + trk("50", "CLOSED") + "," + trk("51", "OPEN") + "]\n"}),
		seedTrk(trackerRetro("tracker/apply-set-already-tracked", apply...), map[string]string{"trksig": `[{"state":"CLOSED","body":"x\nUnclassifiable item set: 2093460367\ny"}]` + "\n"}),
		seedTrk(trackerRetro("tracker/apply-tracker-lookup-nonjson", apply...), map[string]string{"trkset": "not json\n"}),
	)
	// the signature line of the tracker names the retro file; a file name the scrub redacts breaks it: refuse
	secret := func(c dcase) dcase {
		c.name = c.name + "-scrubbed-name"
		c.files = map[string]string{"rh/target-foo/retros/bob@example.com.md": ""}
		c.raw = append([]string{"@BOX@/rh/target-foo/retros/bob@example.com.md"}, c.args...)
		c.prep = func(t *testing.T, b *box) {
			write(t, filepath.Join(b.root, "rh", "target-foo", "retros", "bob@example.com.md"), c.fixturePrefix+fixture(t, c.fixture))
		}
		return c
	}
	out = append(out, secret(trackerRetro("tracker/dry")), secret(trackerRetro("tracker/apply", apply...)))
	// a delta row whose retro file name is redacted breaks the row's signature line too
	row1 := doc(pending, row("1", "first delta of the retro", "x.md", "B1", "fix", "LOW"))
	named := func(name string, args ...string) dcase {
		c := dcase{name: name, retro: row1, args: args}
		c.raw = append([]string{"@BOX@/rh/target-foo/retros/bob@example.com.md"}, args...)
		c.prep = func(t *testing.T, b *box) {
			write(t, filepath.Join(b.root, "rh", "target-foo", "retros", "bob@example.com.md"), row1)
		}
		return c
	}
	out = append(out, named("scrub/row-signature-altered-dry"), named("scrub/row-signature-altered-apply", apply...))
	return out
}

// casesScrub: every class the privacy scrub redacts, as it lands in a planned title and body.
func casesScrub() []dcase {
	var out []dcase
	for name, text := range map[string]string{
		"email":             "mail alice@example.com about the delta",
		"home-path":         "see /home/alice/notes.txt for the delta",
		"users-path":        "see /Users/alice/notes.txt for the delta",
		"windows-path":      "see C:\\Users\\alice\\notes.txt for the delta",
		"sk-token":          "key sk-abcdefghij1234567890 leaked here",
		"short-sk":          "key sk-abc is too short to redact here",
		"akia":              "key AKIAABCDEFGHIJKLMNOP leaked here",
		"ghp":               "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 here",
		"github-pat":        "token github_pat_abcdefghijklmnopqrstuvwxyz here",
		"bearer":            "Authorization: Bearer abcdef0123456789 sent",
		"password-assign":   "set password=hunter2secret in the config",
		"api-key-assign":    "export API_KEY=abcd1234efgh5678 before running",
		"secret-colon":      "client_secret: s3cr3tvalue in the file",
		"two-emails":        "a@example.com and b@example.org both leak",
		"nothing":           "a perfectly harmless delta title here",
		"path-in-title-cut": "/home/bob/" + longWord(130) + " is a very long path title",
	} {
		out = append(out, dry("scrub/"+name, doc(pending, row("1", text, "x.md", "B1", "fix", "LOW"))))
	}
	return out
}

func longWord(n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = 'a' + byte(i%26)
	}
	return string(b)
}
