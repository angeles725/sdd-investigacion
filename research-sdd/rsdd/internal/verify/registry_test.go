package verify

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Guard-to-test table for `verify registry` (each guard of verify-registry.sh and the test that pins it; a
// mutant that removes the guard must turn that test red):
//
//	usage error on an unknown argument ................ TestRegistryUsage
//	TARGETS.md missing -> exit 1 ...................... TestRegistryOperational/targets-missing
//	no usable path: exit 0, --json exit 1 ............. TestRegistryOperational/no-paths, no-paths-json
//	every directory absent: exit 1, --json envelope ... TestRegistryOperational/all-absent, all-absent-json
//	drift beyond tolerance only; tol override ......... TestRegistryDrift
//	absent rows: dedup by row number, three names ..... TestRegistryAbsent
//	companion non-path token is not an absent row ..... TestRegistryAbsent/companion-token
//	truncated path -> PARTIAL ......................... TestRegistryTruncated
//	maturity schema, first/middle/last/single token ... TestRegistryMaturity
//	nc rows (count, no count, drift, contradiction) ... TestRegistryNC
//	registered-path marker check ...................... TestRegistryMarkers
//	corpus not resolvable ............................. TestRegistryMarkers/unresolvable
//	retro count drift, excluded retro, unreadable ..... TestRegistryRetros
//	CATALOG authority (5 states) ...................... TestRegistryCatalog
//	unclassifiable block files ........................ TestRegistryUnclassifiable
//	no-retros INFO and its substituted wording ........ TestRegistryNoRetros
//	row hygiene and the kit self-registration gate .... TestRegistryRowHygiene, TestRegistryKitSelf
//	--json envelope ................................... TestRegistryJSON
//	hook claims, wired-exec, session budget ........... TestRegistryHookSections
//	skipped hook checks are reported .................. TestRegistryUnportedHooks

func want(t *testing.T, got string, subs ...string) {
	t.Helper()
	for _, s := range subs {
		if !strings.Contains(got, s) {
			t.Errorf("missing %q in:\n%s", s, got)
		}
	}
}

func wantNot(t *testing.T, got string, subs ...string) {
	t.Helper()
	for _, s := range subs {
		if strings.Contains(got, s) {
			t.Errorf("unexpected %q in:\n%s", s, got)
		}
	}
}

func rcIs(t *testing.T, r vrResult, rc int) {
	t.Helper()
	if r.rc != rc {
		t.Errorf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", r.rc, rc, r.stdout, r.stderr)
	}
}

func TestRegistryUsage(t *testing.T) {
	k := newVRKit(t)
	k.targets(vrTable())
	r := k.run(nil, "--bogus")
	rcIs(t, r, 2)
	if r.stdout != "" || r.stderr != "verify-registry: unknown argument: --bogus\nusage: verify-registry.sh [--json]\n" {
		t.Errorf("usage output: stdout=%q stderr=%q", r.stdout, r.stderr)
	}
	r = k.run(nil, "--json", "extra")
	rcIs(t, r, 2)
	want(t, r.stderr, "unknown argument: extra")
}

func TestRegistryOperational(t *testing.T) {
	t.Run("targets-missing", func(t *testing.T) {
		k := newVRKit(t)
		r := k.run(nil)
		rcIs(t, r, 1)
		want(t, r.stderr, "verify-registry: cannot find "+k.targetsMD+"\n")
		if r.stdout != "" {
			t.Errorf("stdout %q", r.stdout)
		}
	})
	t.Run("no-paths", func(t *testing.T) {
		k := newVRKit(t)
		k.targets("| # | Name |\n|---|---|\n| 1 | prose only |\n")
		r := k.run(nil)
		rcIs(t, r, 0)
		want(t, r.stderr, "verify-registry: ERROR — no usable target paths in "+k.targetsMD+"\n",
			"verify-registry: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n")
	})
	t.Run("no-paths-json", func(t *testing.T) {
		k := newVRKit(t)
		k.targets("")
		r := k.run(nil, "--json")
		rcIs(t, r, 1)
		if r.stdout != "" {
			t.Errorf("a machine caller must not read a clean envelope: %q", r.stdout)
		}
	})
	t.Run("all-absent", func(t *testing.T) {
		k := newVRKit(t)
		k.targets("| 1 | gone | `@H@/nowhere` | (1 md) | x | en |\n")
		r := k.run(nil)
		rcIs(t, r, 1)
		want(t, r.stderr, "verify-registry: ERROR — no registered corpus path exists as a directory on disk.\n",
			"Check RESEARCH_HOME ("+k.home+") and that corpora exist at the registered paths.\n")
		if r.stdout != "" {
			t.Errorf("stdout %q", r.stdout)
		}
	})
	t.Run("all-absent-json", func(t *testing.T) {
		k := newVRKit(t)
		k.targets("| 1 | gone | `@H@/nowhere` | (1 md) | x | en |\n")
		r := k.run(map[string]string{"RESEARCH_HOME": ""}, "--json")
		rcIs(t, r, 0)
		want(t, r.stdout, `"state": "absent-input"`, `"reason": "every registered target directory is absent on disk"`, `"items": []`, `"targets_absent": 1`)
		want(t, r.stderr, "Check RESEARCH_HOME ((unset))")
	})
}

func TestRegistryDrift(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 5)
	k.put("alpha/retros/r1.md", "x\n")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(8 md)")))
	r := k.run(nil)
	rcIs(t, r, 0)
	want(t, r.stdout, "WARN  alpha — TARGETS.md row claims 8 md but the corpus has 5 real block file(s) (drift 3 > tol 2) — refresh the row (propose-never-apply; not auto-edited).\n",
		"Summary: reconciled 2 target(s) · 0 absent target(s) · 1 count drift(s) · 0 retro drift(s) · 0 unresolvable · 0 oversized row(s) · 0 attention.\n",
		"For each count drift: recount the corpus and refresh that target's 'N md' in $KIT/TARGETS.md by hand (WARN-only; never auto-edited).\n")
	wantNot(t, r.stdout, "Registry consistent")

	// a drift equal to the tolerance is quiet, one above warns
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(7 md)")))
	r = k.run(nil)
	wantNot(t, r.stdout, "claims", "WARN")
	want(t, r.stdout, "Registry consistent with reality (within tolerance 2).\n")

	// RSDD_REGISTRY_TOL moves the boundary
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(40 md)")))
	r = k.run(map[string]string{"RSDD_REGISTRY_TOL": "50"})
	want(t, r.stdout, "Registry consistent with reality (within tolerance 50).\n")
	r = k.run(map[string]string{"RSDD_REGISTRY_TOL": "30"})
	want(t, r.stdout, "(drift 35 > tol 30)")

	// a leading-zero claim is decimal, never octal
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(08 md)")))
	r = k.run(nil)
	want(t, r.stdout, "claims 08 md but the corpus has 5 real block file(s) (drift 3 > tol 2)")

	// no claimed count
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 focus)")))
	r = k.run(nil)
	want(t, r.stdout, "WARN  alpha — no claimed '<N> md' count in its TARGETS.md row (real: 5 blocks); add the count so it can be reconciled.\n", "1 unresolvable")
}

func TestRegistryAbsent(t *testing.T) {
	t.Run("rows", func(t *testing.T) {
		k := newVRKit(t)
		k.blocks("here", 1)
		k.targets(vrTable(
			vrRow("1", "here", "here", "(1 md)"),
			vrRow("2", "g1", "g1", "(1 md)"), vrRow("3", "g2", "g2", "(1 md)"),
			vrRow("4", "g3", "g3", "(1 md)"), vrRow("5", "g4", "g4", "(1 md)"),
			"| 6 | two | `@H@/g5` `@H@/g5b` | (1 md) | x | en |"))
		r := k.run(nil)
		rcIs(t, r, 0)
		want(t, r.stdout, "· 5 absent target(s) ·",
			"INFO: 5 registered target(s) absent on disk — NOT checked: `$RESEARCH_HOME/g1`, `$RESEARCH_HOME/g2`, `$RESEARCH_HOME/g3` ...and 2 more. Verify RESEARCH_HOME ("+k.home+") and that corpora exist at the registered paths.\n")
	})
	t.Run("companion-token", func(t *testing.T) {
		k := newVRKit(t)
		k.blocks("three", 1)
		k.targets(vrTable("| 1 | three | `/mrdoob/three.js` `@H@/three` | (1 md) | x | en |"))
		r := k.run(nil)
		want(t, r.stdout, "· 0 absent target(s) ·")
		wantNot(t, r.stdout, "INFO: ")
	})
}

func TestRegistryTruncated(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)"), "| 2 | cut | `@H@/long/path/...` | (1 md) | x | en |"))
	r := k.run(nil)
	rcIs(t, r, 0)
	want(t, r.stdout, "WARN: 1 target(s) skipped — truncated/unresolvable path in TARGETS.md; this reconcile is PARTIAL: ...\n")
	wantNot(t, r.stdout, "Registry consistent")
}

func TestRegistryMaturity(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	ok := "(1 md @2026-01-02, ACTIVE / 2 focuses / 3 runs / 4 retros + 1 corpus §18 / 2-of-5 gaps / git yes / remote no / hook anything here / unregistered / registered-no-sessions)"
	k.targets(vrTable(vrRow("1", "alpha", "alpha", ok)))
	r := k.run(nil)
	wantNot(t, r.stdout, "not in schema")
	for name, cell := range map[string]string{
		"first":          "(1 md-x / 2 runs)",
		"middle":         "(1 md / bogus here / 2 runs)",
		"last":           "(1 md / 2 runs / 3 retrograde motion)",
		"single":         "(whatever)",
		"date":           "(1 md @2026-1-2)",
		"empty-token-ok": "(1 md /  / 2 runs)",
	} {
		k.targets(vrTable(vrRow("1", "alpha", "alpha", cell)))
		r := k.run(nil)
		if name == "empty-token-ok" {
			wantNot(t, r.stdout, "not in schema")
			continue
		}
		want(t, r.stdout, "maturity field not in schema: '")
		want(t, r.stdout, "check the legend for valid forms or update the legend (propose-never-apply).")
		if name == "last" {
			want(t, r.stdout, "'3 retrograde motion'")
		}
		if name == "single" {
			want(t, r.stdout, "'whatever'")
		}
	}
}

func TestRegistryNC(t *testing.T) {
	k := newVRKit(t)
	k.put("tool/a.md", "x\n")
	k.put("tool/b.md", "x\n")
	k.put("tool/sub/c.md", "x\n")
	k.targets(vrTable(vrRow("1", "tool", "tool", "(2 md / nc)")))
	r := k.run(nil)
	wantNot(t, r.stdout, "WARN")
	want(t, r.stdout, "reconciled 2 target(s)")

	// the nc count is root-level .md only: claiming 9 against 2 drifts
	k.targets(vrTable(vrRow("1", "tool", "tool", "(9 md / nc)")))
	r = k.run(nil)
	want(t, r.stdout, "WARN  tool — TARGETS.md row claims 9 md but the non-corpus target has 2 real .md file(s) at root (drift 7 > tol 2) — refresh the row.\n")

	k.targets(vrTable(vrRow("1", "tool", "tool", "(1 run / nc)")))
	r = k.run(nil)
	want(t, r.stdout, "WARN  tool — non-corpus (nc) target has no claimed 'N md' count in TARGETS.md row (real root-level: 2); add the count.\n")

	k.put("tool/RESEARCH-STATE.md", "s\n")
	k.targets(vrTable(vrRow("1", "tool", "tool", "(2 md / nc)")))
	r = k.run(nil)
	want(t, r.stdout, "WARN  tool — row carries the nc flag but a RESEARCH-STATE.md was found at "+k.home+"/tool/RESEARCH-STATE.md; remove nc if this is a real corpus target.\n")
}

func TestRegistryMarkers(t *testing.T) {
	t.Run("no-marker", func(t *testing.T) {
		k := newVRKit(t)
		k.put("deep/research/RESEARCH-STATE.md", "s\n")
		k.put("deep/research/p-block1.md", "b\n")
		k.targets(vrTable(vrRow("1", "deep", "deep", "(1 md)")))
		r := k.run(nil)
		want(t, r.stdout, "WARN  deep — registered path has no corpus marker (no INDEX.md/CATALOG.md/RESEARCH-STATE*.md at "+k.home+"/deep or "+k.home+"/deep/corpus); the row may be pointing at a container directory rather than the corpus root — verify against research-sdd-init.sh's --wire marker check (propose-never-apply).\n",
			"1 attention.")
		wantNot(t, r.stdout, "claims")
	})
	t.Run("nested-corpus", func(t *testing.T) {
		k := newVRKit(t)
		k.put("nest/corpus/RESEARCH-STATE.md", "s\n")
		k.put("nest/corpus/p-block1.md", "b\n")
		k.targets(vrTable(vrRow("1", "nest", "nest", "(1 md)")))
		r := k.run(nil)
		wantNot(t, r.stdout, "WARN")
	})
	t.Run("unresolvable", func(t *testing.T) {
		k := newVRKit(t)
		k.put("bare/INDEX.md", "i\n")
		k.targets(vrTable(vrRow("1", "bare", "bare", "(1 md)")))
		r := k.run(nil)
		want(t, r.stdout, "WARN  "+k.home+"/bare — corpus layout not resolvable (no RESEARCH-STATE*.md under target); cannot recount blocks.\n", "1 unresolvable")
	})
}

func TestRegistryRetros(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	k.put("alpha/retros/r1.md", "# r\n")
	k.put("alpha/retros/r2.md", "<!-- kit-retro: exclude -->\n# r\n")
	k.put("alpha/retros/INDEX-retros.md", "# idx\n")
	k.put("alpha/research/retros/r3.md", "# deep\n")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / 2 retros)")))
	r := k.run(nil)
	wantNot(t, r.stdout, "WARN") // r1 + r3 counted; r2 excluded; the index file skipped

	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / 5 retros)")))
	r = k.run(nil)
	want(t, r.stdout, "WARN  alpha — row claims 5 retro(s) but 2 non-excluded retro(s) found (maxdepth 4) — refresh the 'N retros' field (propose-never-apply).\n",
		"· 1 retro drift(s) ·",
		"For each retro drift: recount non-excluded retros and refresh the 'N retros' field in $KIT/TARGETS.md by hand (WARN-only; never auto-edited).\n")

	// a BOM before the opt-out marker still opts out; a marker after the leading block does not
	k.put("alpha/retros/r4.md", "\xef\xbb\xbf<!-- kit-retro: exclude -->\n")
	k.put("alpha/retros/r5.md", "<!-- a -->\ntext\n<!-- kit-retro: exclude -->\n")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / 3 retros)")))
	r = k.run(nil)
	wantNot(t, r.stdout, "non-excluded retro(s) found")

	t.Run("unreadable", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("root bypasses directory permissions")
		}
		k := newVRKit(t)
		k.blocks("alpha", 1)
		k.put("alpha/retros/r1.md", "# r\n")
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / 1 retro)")))
		dir := filepath.Join(k.home, "alpha/retros")
		if err := os.Chmod(dir, 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(dir, 0o755) }) //nolint:errcheck
		r := k.run(nil)
		want(t, r.stdout, "WARN  alpha — retros/ at "+dir+" is not accessible (permission error); retro count cannot be verified — check filesystem permissions.\n")
		wantNot(t, r.stdout, "non-excluded retro(s) found")
	})
}

func (k *vrKit) catalog(rel string, header string, rows int) {
	k.t.Helper()
	k.put(rel+"/tools/gen-catalog.py", "#\n")
	var b strings.Builder
	b.WriteString(header + "\n| id | name |\n|---|---|\n")
	for i := 0; i < rows; i++ {
		b.WriteString("| " + string(rune('a'+i%26)) + " | n |\n")
	}
	k.put(rel+"/CATALOG.md", b.String())
}

func TestRegistryCatalog(t *testing.T) {
	cases := []struct {
		name, header string
		rows, blocks int
		claimed      string
		out          []string
		notOut       []string
	}{
		{"fresh", "Total: 6", 6, 5, "6", []string{"· 0 count drift(s)"}, []string{"CATALOG"}},
		{"fresh-drift", "Total: 6", 6, 5, "12", []string{"claims 12 md but the corpus has 6 real block file(s) (CATALOG.md total via local gen-catalog.py; disk-consistent: discriminator=5) (drift 6 > tol 2)"}, nil},
		{"stale-header", "Total: 9", 6, 5, "5", []string{"WARN  alpha — CATALOG.md header total 9 ≠ its own 6 block rows (stale header); using disk discriminator 5 — regenerate CATALOG.md.\n"}, nil},
		{"stale", "Total: 12", 12, 5, "12", []string{"WARN  alpha — CATALOG.md total 12 vs on-disk discriminator 5 (diff 7 > tol 2); CATALOG may be stale — regenerate and recheck before trusting this count.\n"}, nil},
		{"disc-zero", "Total: 12", 12, 0, "12", []string{"WARN  alpha — discriminator found 0 classifiable blocks; CATALOG.md claims 12; possible causes: non-canonical block naming (discriminator requires <prefix>-(block|bloque)<N>.md) or stale CATALOG — verify before trusting this count.\n"}, nil},
		{"unparseable", "no digits here", 6, 5, "5", []string{"WARN  alpha — CATALOG.md present (gen-catalog.py registered) but no parseable total found; freshness undeterminable; using discriminator count (5).\n"}, nil},
		{"blocks-token", "12 bloques", 12, 5, "12", []string{"CATALOG.md total 12 vs on-disk discriminator 5"}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			k := newVRKit(t)
			k.blocks("alpha", c.blocks)
			k.put("alpha/retros/r.md", "x\n")
			k.catalog("alpha", c.header, c.rows)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "("+c.claimed+" md)")))
			r := k.run(nil)
			rcIs(t, r, 0)
			want(t, r.stdout, c.out...)
			wantNot(t, r.stdout, c.notOut...)
		})
	}
}

func TestRegistryUnclassifiable(t *testing.T) {
	k := newVRKit(t)
	k.put("alpha/RESEARCH-STATE.md", "s\n")
	for _, n := range []string{"block1.md", "bloque3.md", "block_07.md", "blocking-issues.md", "block-diagram.md", "bloques-pendientes.md", "roadblock.md", "p-block9.md.bak"} {
		k.put("alpha/"+n, "x\n")
	}
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(0 md)")))
	r := k.run(nil)
	want(t, r.stdout, "WARN  alpha — 3 unclassifiable candidate block file(s): names contain 'block'/'bloque' but do not match the canonical discriminator (<prefix>-(block|bloque)<N>.md); the block counter returns 0 — rename to make them visible to drift and §18 checks.\n",
		"INFO  alpha — 3 candidate block file(s) (unclassifiable) on disk but no retros/*.md reachable under the target (§18 feedback not wired).\n")
}

func TestRegistryNoRetros(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 3)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(3 md)")))
	r := k.run(nil)
	want(t, r.stdout, "INFO  alpha — 3 block(s) on disk but no retros/*.md reachable under the target (§18 feedback not wired).\n")
	want(t, r.stdout, "Registry consistent with reality") // an INFO line is advisory: it neither counts nor clears the summary
}

func TestRegistryRowHygiene(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	long := strings.Repeat("x", 30)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")) + "| 7 | wordy | `@H@/alpha` | (1 md) | " + long + " | en |\n")
	r := k.run(map[string]string{"RSDD_ROW_MAXLEN": "25"})
	want(t, r.stdout, "WARN  TARGETS row wordy master cell is 30 chars (> 25) — collapse to one line; narrative belongs in the detail section.\n")
	r = k.run(nil)
	wantNot(t, r.stdout, "TARGETS row")

	// the last line without a newline is not read (`while read` drops it)
	k.write("kit/TARGETS.md", strings.NewReplacer("@K@", k.kit).Replace(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))+"| 8 | tail | `/x` | (1) | "+long+" | en |")
	r = k.run(map[string]string{"RSDD_ROW_MAXLEN": "25"})
	wantNot(t, r.stdout, "TARGETS row tail")
}

func TestRegistryKitSelf(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	k.write("kit/TARGETS.md", "| 1 | alpha | `"+k.home+"/alpha` | (1 md) | x | en |\n")
	r := k.run(nil)
	want(t, r.stdout, "WARN  kit — kit repo is NOT in its own TARGETS.md; fleet instruments cannot supervise it. Add a row with the kit's path (kit-sup #6 gate).\n", "· 1 attention.")

	// the kit's PARENT registered also counts
	k.write("kit/TARGETS.md", "| 1 | alpha | `"+k.home+"/alpha` | (1 md) | x | en |\n| 2 | root | `"+k.root+"` | (0 md / nc) | x | en |\n")
	r = k.run(nil)
	wantNot(t, r.stdout, "kit repo is NOT")
}

func TestRegistryJSON(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 5)
	k.put("alpha/retros/r.md", "x\n")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(9 md)")))
	r := k.run(nil, "--json")
	rcIs(t, r, 0)
	exp := `{
  "schema": "research-sdd.verify-registry/v1",
  "state": "ok",
  "counts": {
    "targets": 2,
    "targets_absent": 0,
    "targets_skipped": 0,
    "reconciled": 2,
    "count_drift": 1,
    "retro_drift": 0,
    "unresolved": 0,
    "oversized_rows": 0,
    "attention": 0
  },
  "reason": null,
  "items": [
    {
      "kind": "count-drift",
      "severity": "WARN",
      "target": "alpha",
      "message": "alpha — TARGETS.md row claims 9 md but the corpus has 5 real block file(s) (drift 4 > tol 2) — refresh the row (propose-never-apply; not auto-edited)."
    }
  ]
}
`
	if r.stdout != exp {
		t.Errorf("envelope:\n%s\nwant:\n%s", r.stdout, exp)
	}

	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(5 md)")))
	r = k.run(nil, "--json")
	want(t, r.stdout, `"state": "no-match"`, `"reason": "targets reconciled, no findings"`, `"items": []`)
}

func TestRegistryUnportedHooks(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	k.put("alpha/.claude/settings.json", "{}\n")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / hook yes)")))
	r := k.run(nil)
	rcIs(t, r, 0)
	want(t, r.stderr, "verify-registry: degraded: 2 hook-wiring/session-budget check(s) skipped; lib/hook-wiring.sh is not ported to Go yet")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
	r = k.run(nil)
	want(t, r.stderr, "1 hook-wiring/session-budget check(s) skipped") // the wired-exec scan of the .claude directory
}
