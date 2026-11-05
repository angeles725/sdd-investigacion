package writercheck

import "fmt"

// pristineFiles is the miniature kit of the fixture repository (the twin of the pristine repo of
// tests/kit-writer-check.test.sh): fake suites that name the scripts they exercise, scripts that name each other, the
// impact manifests, and the waiver list.
func pristineFiles() map[string]string {
	f := map[string]string{}
	fake := func(path, word string) {
		f[path] = fmt.Sprintf("#!/usr/bin/env bash\n: '%s'   # SUT named on a code line\nif [ \"${1:-}\" = \"--prove-teeth\" ]; then echo \"-- teeth --\"; fi\necho \"== 3 passed · 0 failed ==\"\n", word)
	}
	fake(ts+"/a.test.sh", `SUT="$HERE/../alpha.sh"`)
	fake(ts+"/b.test.sh", `"$TOOLBELT/beta.sh"`)
	fake(ts+"/c.test.sh", `"$TB/gamma.sh"`)
	fake(ts+"/multi.test.sh", `"$TB/alpha.sh" "$TB/beta.sh" "$TB/gamma.sh"`)
	fake(ts+"/lint-always.test.sh", "whole tree")
	fake(ts+"/evalish.test.sh", `eval "$cmd"`)
	fake(ts+"/m.test.sh", `"$TB/mid.sh"`)
	fake(ts+"/t.test.sh", `"$TB/top.sh"`)
	fake("research-sdd/install/tests/a.test.sh", "nothing in particular")
	f[ts+"/pi.test.mjs"] = "import x from \"../adv.mjs\";\n"
	f[ts+"/impact-always.txt"] = "# fixture\nlint-always whole-tree lint\n"
	f[ts+"/impact-blindspot.txt"] = "# fixture\nevalish builds a command and evals it\n"
	for _, n := range []string{"lib/mutant.sh", "run-all.sh", "shard-join.sh", "teeth-helper-waivers.txt", "suite-impact.sh"} {
		f[ts+"/"+n] = ":\n"
	}
	for _, n := range []string{"alpha", "beta", "gamma", "leaf"} {
		f[tb+"/"+n+".sh"] = "echo " + n + "\n"
	}
	f[tb+"/mid.sh"] = "\"$TB/leaf.sh\"\n"
	f[tb+"/top.sh"] = "\"$TB/mid.sh\"\n"
	f[tb+"/adv.mjs"] = "export default 1;\n"
	f[tb+"/solo.sh"] = "echo nobody tests me\n"
	f[tb+"/notes.md"] = "# notes\n"
	f[tb+"/lib/gl.sh"] = "echo lib\n"
	f[tb+"/old.sh"] = "# pre-existing, mentions pkill -f oldthing\n"
	f[ts+"/old.test.sh"] = "\"$TB/old.sh\"\n"
	f[ts+"/writer-check-waivers.txt"] = "# fixture waivers: <repo-relative suite> <reason>\n" +
		"research-sdd/toolbelt/tests/t.test.sh smoke suite with no mutation controls (fixture)\n"
	return f
}
