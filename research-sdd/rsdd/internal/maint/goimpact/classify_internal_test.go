package goimpact

import "testing"

func TestClassifyPlacesEveryMention(t *testing.T) {
	cases := []struct {
		name     string
		words    []string
		j, w0    int
		inDouble bool
		execDoc  bool
		want     string
	}{
		{"assignment", []string{"A=$RSDD_BIN"}, 0, -1, false, false, ClassA},
		{"assignment beats a test", []string{"[", "A=$RSDD_BIN"}, 1, 0, false, false, ClassA},
		{"[ operand", []string{"[", "$RSDD_BIN"}, 1, 0, false, false, ClassB},
		{"[[ operand", []string{"[[", "$RSDD_BIN"}, 1, 0, false, false, ClassB},
		{"test operand", []string{"test", "$RSDD_BIN"}, 1, 0, false, false, ClassB},
		{"test by path", []string{"/usr/bin/test", "$RSDD_BIN"}, 1, 0, false, false, ClassB},
		{"inside [[ ]]", []string{"x", "$RSDD_BIN"}, 1, 0, true, false, ClassB},
		{"export", []string{"export", "$RSDD_BIN"}, 1, 0, false, false, ClassA},
		{"unset", []string{"unset", "$RSDD_BIN"}, 1, 0, false, false, ClassA},
		{"not a declaration word", []string{"exports", "$RSDD_BIN"}, 1, 0, false, false, ClassD},
		{"eval", []string{"eval", "$RSDD_BIN"}, 1, 0, false, false, ClassUnplaceable},
		{"bash -c", []string{"bash", "-c", "$RSDD_BIN"}, 2, 0, false, false, ClassUnplaceable},
		{"bash script", []string{"bash", "$RSDD_BIN"}, 1, 0, false, false, ClassD},
		{"flag after the mention", []string{"bash", "$RSDD_BIN", "-c"}, 1, 0, false, false, ClassD},
		{"not a shell", []string{"bashx", "-c", "$RSDD_BIN"}, 2, 0, false, false, ClassD},
		{"executed here-doc", []string{"$RSDD_BIN"}, 0, 0, false, true, ClassUnplaceable},
		{"command position", []string{"$RSDD_BIN", "g"}, 0, 0, false, false, ClassC},
		{"no command word", []string{"$RSDD_BIN"}, 0, -1, false, false, ClassD},
		{"argument", []string{"echo", "$RSDD_BIN"}, 1, 0, false, false, ClassD},
	}
	for _, c := range cases {
		if got := classify(c.words, c.j, c.w0, c.inDouble, c.execDoc); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

func TestDashC(t *testing.T) {
	cases := []struct {
		args []string
		upto int
		want bool
	}{
		{[]string{"-c", "x"}, 1, true}, {[]string{"-lc", "x"}, 1, true}, {[]string{`"-c"`, "x"}, 1, true},
		{[]string{"-x", "x"}, 1, false}, {[]string{"--rcfile", "x"}, 1, false}, {[]string{"c", "x"}, 1, false},
		{[]string{"-"}, 1, false}, {[]string{"-c"}, 0, false}, {[]string{"a", "-c"}, 1, false},
		{[]string{"a", "-c"}, 2, true}, {[]string{"-c"}, 5, true}, {[]string{"-c"}, -1, false},
	}
	for _, c := range cases {
		if got := dashC(c.args, c.upto); got != c.want {
			t.Errorf("dashC(%q, %d) = %v, want %v", c.args, c.upto, got, c.want)
		}
	}
}

func TestLiteralForms(t *testing.T) {
	cases := []struct {
		in, form string
		skip     int
	}{
		{"rsdd_exec", "rsdd_exec", 0}, {"rsdd_exec_hook", "rsdd_exec_hook", 1}, {"rsdd", "rsdd", 0},
		{"/a/bin/rsdd", "rsdd", 0}, {"RSDD_BIN=/x/bin/rsdd", "", 0}, {"a=rsdd", "", 0}, {"rsdd2", "", 0},
		{"bin/rsdd", "", 0}, {"x/rsdd", "", 0}, {"rsdd_exec2", "", 0},
	}
	for _, c := range cases {
		if f, s := literalForm(c.in); f != c.form || s != c.skip {
			t.Errorf("literalForm(%q) = %q, %d; want %q, %d", c.in, f, s, c.form, c.skip)
		}
	}
}

func TestNamesAnyNeedsAWholeName(t *testing.T) {
	cases := []struct {
		text string
		want bool
	}{
		{"run a.sh now", true}, {"a.sh", true}, {"/a.sh", true}, {`"a.sh"`, true}, {"(a.sh)", true}, {"a.sh:", true},
		{"éa.sh", true}, {"a.shé", true}, {"xa.sh", false}, {"a.shx", false}, {"-a.sh", false}, {"a.sh-", false},
		{"_a.sh", false}, {"a.sh_", false}, {".a.sh", false}, {"a.sh.", false}, {"0a.sh", false}, {"a.sh9", false},
		{"Aa.sh", false}, {"a.shZ", false}, {"za.sh", false}, {"a.sh/", true}, {"a.sh@", true}, {"", false},
	}
	for _, c := range cases {
		if got := namesAny(c.text, []string{"b.sh", "a.sh"}, "self.sh"); got != c.want {
			t.Errorf("namesAny(%q) = %v, want %v", c.text, got, c.want)
		}
	}
	if namesAny("a.sh", []string{"a.sh"}, "a.sh") {
		t.Error("a file's own name is not a shim it reaches")
	}
}

func TestPathClasses(t *testing.T) {
	for in, want := range map[string]string{
		"research-sdd/rsdd/x.go": "x.go", "./research-sdd/rsdd/x.go": "x.go", "research-sdd/rsdd/a/../x.go": "x.go",
		"/research-sdd/rsdd/x.go": "", "research-sdd/rsdd/../x": "", "research-sdd/rsdd": "", "research-sdd/rsdd/": "",
		"../research-sdd/rsdd/x.go": "", "research-sdd/rsddx/y": "", "x.go": "",
	} {
		if rel, why := moduleRel(in); rel != want || (rel == "") != (why != "") {
			t.Errorf("moduleRel(%q) = %q, %q; want %q", in, rel, why, want)
		}
	}
	for in, want := range map[string]bool{
		"a_test.go": true, "a/testdata/x": true, "testdata": true, "a/testdatax/y.go": false, "b_test.go.txt": false,
		"x_test_go": false, "a/b.go": false,
	} {
		if isTestPath(in) != want {
			t.Errorf("isTestPath(%q) = %v", in, !want)
		}
	}
	for in, want := range map[string]bool{
		"go.mod": true, "go.sum": true, "Makefile": true, "teeth-debt.txt": true, "go.modx": false, "Makefile2": false,
		"cmd/x": true, "cmdx": false, "internal/cli/x.go": true, "internal/clix/x.go": false,
		"internal/commands/c.go": true, "internal/commandsx/c.go": false, "internal/a/a.go": false,
	} {
		if (typedFull(in) != "") != want {
			t.Errorf("typedFull(%q) = %q", in, typedFull(in))
		}
	}
}
