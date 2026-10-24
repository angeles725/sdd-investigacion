package grammar

import "testing"

func TestMarkerLine(t *testing.T) {
	a, b := "<!-- review-status: a -->", "<!-- review-status: b -->"
	for src, want := range map[string]string{
		"# T\n\n" + a + "\n":                a,
		"```\n" + a + "\n```\n" + b + "\n":  b,
		"~~~\n```\n~~~\n" + b + "\n":        b,
		"````\n```\n" + a + "\n````\n" + b:  b,
		"```\n" + a + "\n" + b + "\n":       a,
		"```\n```\n~~~\n" + b + "\n" + a:    b,
		"    " + a + "\n":                   "",
		"   " + a + "\n":                    "   " + a,
		"\t" + a + "\n":                     "",
		"text " + a + "\n":                  "",
		"```\r\nx\r\n``` \r\n" + a + "\r\n": a + "\r",
		"\t```\n" + a + "\n":                a,
		"```a`b\n" + b + "\n":               b,
		bom + a + "\n":                      a,
		"```\nno marker\n":                  "",
		"<!-- REVIEW-STATUS:x -->\n":        "<!-- REVIEW-STATUS:x -->",
		"``\n" + a:                          a,
	} {
		if got := markerLine(Parse("r.md", src)); got != want {
			t.Errorf("markerLine(%q) = %q, want %q", src, got, want)
		}
	}
}

func TestMarkerOutOfScope(t *testing.T) {
	a := "<!-- review-status: a -->"
	for src, want := range map[string]bool{
		"# T\n## H\n" + a + "\n": true, a + "\n": false, "prose\n": false, "```\n" + a + "\n": true,
		"```\n" + a + "\n```\n": false, "---\ntitle: x\n---\n" + a + "\n": true, "": false,
	} {
		if got := MarkerOutOfScope(Parse("r.md", src)); got != want {
			t.Errorf("MarkerOutOfScope(%q) = %v, want %v", src, got, want)
		}
	}
}
