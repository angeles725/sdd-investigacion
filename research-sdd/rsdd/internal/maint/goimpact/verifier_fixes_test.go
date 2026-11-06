package goimpact_test

import (
	"strings"
	"testing"
)

// An aggregator file that lists another package's command (`[]cli.Command{sub.Command}`) maps to that
// command: dropping or wrapping the entry changes what the binary registers (verifier B1).
func TestAggregatorReferenceMapsToTheReferencedCommand(t *testing.T) {
	root := repo(t, map[string]string{
		mod + "internal/agg/sub/sub.go": cliImp + "var Command = cli.Command{Name: \"s\", Group: \"agg\"}\n",
		mod + "internal/agg/commands.go": "package agg\n\nimport (\n\t\"example.test/rsdd/internal/agg/sub\"\n\t\"example.test/rsdd/internal/cli\"\n)\n\n" +
			"var Commands = []cli.Command{sub.Command}\n",
		"research-sdd/toolbelt/agg.sh": "#!/usr/bin/env bash\nrsdd_exec agg s\n",
	})
	f := mod + "internal/agg/commands.go"
	r := run("--repo", root, f)
	if !has(r.lines(), "SHIM\t"+f+"\tresearch-sdd/toolbelt/agg.sh\tagg s") || r.rc != 0 {
		t.Errorf("aggregator does not reach its referenced command:\n%s%s", r.out, r.err)
	}
}

// An element the parser cannot attribute (a call, an unknown selector) fails closed.
func TestAggregatorUnknownElementIsFull(t *testing.T) {
	for name, elem := range map[string]string{"call": "mk()", "unknown package": "nope.Command"} {
		root := repo(t, map[string]string{
			mod + "internal/agg/commands.go": cliImp + "func mk() cli.Command { return cli.Command{Name: \"m\", Group: \"agg\"} }\n\nvar Commands = []cli.Command{" + elem + "}\n",
		})
		r := run("--repo", root, mod+"internal/alpha/alpha.go")
		if !strings.Contains(r.out, "FULL\t"+mod+"internal/alpha/alpha.go\tunresolved command literal at internal/agg/commands.go:") {
			t.Errorf("%s: element %s not FULL:\n%s", name, elem, r.out)
		}
	}
}

// A variable assigned from the binary and then used is a call the classifier cannot follow: the file is an
// alias blind spot (s1 ruling L6 condition 3), whether the alias runs in command or in argument position.
func TestAliasOfTheBinaryIsABlindSpot(t *testing.T) {
	f := mod + "internal/alpha/alpha.go"
	for name, body := range map[string]string{
		"command position":  "r=\"$RSDD_BIN\"\n\"$r\" g one\n",
		"argument position": "RSDD=\"${RSDD_BIN:-x}\"\npython3 run.py \"$RSDD\"\n",
		"local, braces":     "f() {\n\tlocal real=\"$RSDD_REAL_BIN\"\n\t${real} b mid\n}\n",
	} {
		r := run("--repo", repo(t, map[string]string{"research-sdd/toolbelt/al.sh": "#!/usr/bin/env bash\n" + body}), f)
		if !has(r.lines(), "BLIND\t"+f+"\tresearch-sdd/toolbelt/al.sh\talias") || !strings.Contains(r.summary(), "\talias=1\t") {
			t.Errorf("%s: no alias blind spot:\n%s", name, r.out)
		}
	}
	// an alias that is never used, and an assignment of the binary variable itself, are not aliases
	for name, body := range map[string]string{
		"unused alias":    "r=\"$RSDD_BIN\"\n",
		"binary itself":   "RSDD_BIN=\"$ROOT/bin/rsdd\"\nexport RSDD_BIN\nbash a.sh\n",
		"real bin itself": "export RSDD_REAL_BIN=\"$RSDD_BIN\"\nbash a.sh\n",
	} {
		r := run("--repo", repo(t, map[string]string{"research-sdd/toolbelt/al.sh": "#!/usr/bin/env bash\n" + body}), f)
		if strings.Contains(r.out, "al.sh\talias") {
			t.Errorf("%s: wrongly an alias:\n%s", name, r.out)
		}
	}
}

// A tree with no bash file to scan is not a measured zero (verifier B3, kit §7).
func TestNoBashFilesIsDegraded(t *testing.T) {
	var drop []string
	for p := range synth() {
		if strings.HasPrefix(p, "research-sdd/toolbelt/") {
			drop = append(drop, p)
		}
	}
	r := run("--repo", repo(t, nil, drop...), mod+"internal/alpha/alpha.go")
	if r.rc != 2 || !strings.Contains(r.err, "degraded: go-impact: no bash file found under research-sdd") || r.out != "" {
		t.Errorf("rc=%d out=%q err=%q", r.rc, r.out, r.err)
	}
}
