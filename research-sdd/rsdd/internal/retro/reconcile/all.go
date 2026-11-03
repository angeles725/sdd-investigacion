package reconcile

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// runAll is the --all branch of the legacy dispatch: audit every retro of every target registered in TARGETS.md
// (both layouts of METHODOLOGY §3b, flat <target>/retros and nested <target>/corpus/retros, kit issue #1287),
// then print the fleet summary. A retro that cannot be audited to a verdict counts as degraded and gates the exit
// code; a mispositioned marker is a corpus finding counted apart and never gates it (kit issue #1125 item 3).
func runAll(ctx context.Context, g *ghClient, sess *session, rep *Report, o Options) {
	targetsMD := filepath.Join(o.KitRoot, "research-sdd", "TARGETS.md")
	if !isRegular(targetsMD) {
		rep.fail("absent-input: TARGETS.md not found: %s", targetsMD)
		return
	}
	fleet := &Fleet{}
	rep.Fleet = fleet
	foundAny := false
	var paths []string
	if src, err := kit.ReadTargets(targetsMD); err == nil { // target_paths_all ... 2>/dev/null: a failure lists nothing
		paths = kit.PathsAll(src, o.Env)
	}
	for _, tgtPath := range paths {
		if !kit.IsDirOS(tgtPath) {
			continue
		}
		haveRetrosDir, tgtFound := false, false
		var emptyDirs []string
		for _, retrosDir := range []string{filepath.Join(tgtPath, "retros"), filepath.Join(tgtPath, "corpus", "retros")} {
			if !kit.IsDirOS(retrosDir) {
				continue
			}
			haveRetrosDir = true
			files := retroFiles(retrosDir)
			for _, rfile := range files {
				foundAny = true
				if ctx.Err() != nil || g.err != nil {
					return
				}
				// The name per retro file comes from the SAME helper as the single mode, so a nested registered
				// target's own retros are never labelled with this (outer) target's name.
				res, err := kit.NameForRetro(targetsMD, rfile, o.Cwd, o.Env)
				for _, w := range res.Warnings {
					rep.note("%s", w)
				}
				if msg, ok := nameFailureNote(err); ok {
					rep.note("%s", msg)
				}
				if err != nil || res.Name == "" {
					rep.degrade("degraded: cannot resolve a registered target name for %s (target_name_for_retro rc=%d)", rfile, kit.RC(err))
					fleet.Degraded++
					continue
				}
				auditFleetRetro(ctx, g, sess, rep, fleet, o, rfile, res.Name)
			}
			if len(files) == 0 {
				emptyDirs = append(emptyDirs, retrosDir)
			} else {
				tgtFound = true
			}
		}
		// An empty retros dir only WARNs when the target has no retros in ANY of its layouts: a target keeping
		// them under corpus/retros must not also be reported as "no retro files" for its empty flat sibling.
		if !tgtFound {
			for _, ed := range emptyDirs {
				rep.note("WARN: no retro files (*.md) found in '%s'", ed)
			}
		}
		if !haveRetrosDir {
			rep.note("WARN: no retros/ directory for target '%s'", filepath.Base(tgtPath))
		}
	}
	if !foundAny {
		rep.note("empty-input: no retro files found across all targets")
	}
	sess.shallowNote(rep)
	rep.out("%s", fleet.Line())
}

// nameFailureNote is what target_name_for_retro leaves on stderr: its message for an operational failure (rc 1).
// A retro with no registered ancestor (rc 2) and a clean run say nothing.
func nameFailureNote(err error) (string, bool) {
	if err != nil && kit.RC(err) == 1 {
		return err.Error(), true
	}
	return "", false
}

// retroFiles is `find DIR -maxdepth 1 -name '*.md' -type f | sort`: the regular *.md files of the directory in
// bytewise order (os.ReadDir sorts by name). A directory that cannot be listed has none.
func retroFiles(dir string) []string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".md") && e.Type().IsRegular() {
			out = append(out, filepath.Join(dir, e.Name()))
		}
	}
	return out
}

// auditFleetRetro audits one retro into its own Report and folds it into the run: the output lines and notes in
// emission order, and the fleet totals when the audit reached its end.
func auditFleetRetro(ctx context.Context, g *ghClient, sess *session, rep *Report, fleet *Fleet, o Options, path, name string) {
	sub := &Report{}
	(&audit{ctx: ctx, sess: sess, gh: g, closed: o.ClosedCache, rep: sub, path: path, base: filepath.Base(path), target: name, cache: o.IssuesCache}).run()
	rep.stdout = append(rep.stdout, sub.stdout...)
	rep.Notes = append(rep.Notes, sub.Notes...)
	rep.Untracked = append(rep.Untracked, sub.Untracked...)
	rep.Tracked = append(rep.Tracked, sub.Tracked...)
	rep.Orphaned = append(rep.Orphaned, sub.Orphaned...)
	rep.Shipped = append(rep.Shipped, sub.Shipped...)
	rep.Borderline = append(rep.Borderline, sub.Borderline...)
	rep.Regressed = append(rep.Regressed, sub.Regressed...)
	if rep.Degraded == "" {
		rep.Degraded = sub.Degraded
	}
	if rep.OutOfScopeMarker == "" {
		rep.OutOfScopeMarker = sub.OutOfScopeMarker
	}
	if sub.OutOfScopeMarker != "" {
		fleet.OutOfScope++
	}
	if sub.done {
		fleet.Tracked += len(sub.Tracked)
		fleet.Untracked += len(sub.Untracked)
		fleet.Shipped += len(sub.Shipped)
		fleet.Borderline += len(sub.Borderline)
		fleet.Regressed += len(sub.Regressed)
		fleet.Orphaned += len(sub.Orphaned)
		fleet.Retros++
	}
	if sub.failed() {
		fleet.Degraded++
	}
}
