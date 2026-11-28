package issuesdue

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// defaultListLimit is RECONCILE_ISSUES_LIST_LIMIT's default: GitHub search's practical ceiling (kit issue #1369 c).
const defaultListLimit = 1000

// ListLimit is RECONCILE_ISSUES_LIST_LIMIT: the text handed to gh --limit, its value, and the degraded line when
// it is not a positive integer. Unset or empty is the default.
func ListLimit(get func(string) string) (text string, n int, bad string) {
	text = get("RECONCILE_ISSUES_LIST_LIMIT")
	if text == "" {
		return strconv.Itoa(defaultListLimit), defaultListLimit, ""
	}
	n, err := strconv.Atoi(text)
	if strings.Trim(text, "0123456789") != "" || text == "0" {
		return text, 0, fmt.Sprintf("degraded: RECONCILE_ISSUES_LIST_LIMIT must be a positive integer (got '%s')", text)
	}
	if err != nil { // more digits than an int holds: larger than any cap that can be filled
		n = int(^uint(0) >> 1)
	}
	return text, n, ""
}

// KitRoot is the legacy KIT_ROOT: two directories above the toolbelt, resolved physically (kit issue #993). An
// empty toolbelt is the kit resolution of toolbelt/reconcile-issues.sh; a relative one resolves against cwd.
// errf receives the stderr lines of a resolution that fails (false).
func KitRoot(cwd string, env func(string) string, toolbelt string, errf func(string, ...any)) (string, bool) {
	if toolbelt == "" {
		p, warns, err := kit.ResolveKitScript("toolbelt/reconcile-issues.sh", env)
		for _, w := range warns {
			errf("%s", w)
		}
		if err != nil {
			errf("reconcile-issues: cannot find the kit toolbelt: %v", err)
			return "", false
		}
		toolbelt = filepath.Dir(p)
	}
	if !filepath.IsAbs(toolbelt) {
		toolbelt = filepath.Join(cwd, toolbelt)
	}
	if r, err := filepath.EvalSymlinks(toolbelt); err == nil {
		toolbelt = r
	}
	return filepath.Dir(filepath.Dir(toolbelt)), true
}

// ResolveTarget is the single-retro branch of the legacy main dispatch up to the audit: validate the path
// (absent-input), derive the target NAME exactly as stage-retro-issues.sh does (kit issue #1287). It answers the
// absolute retro path and the target name for Read; false means the stop is already given to sink.
func ResolveTarget(kitRoot, cwd, retro string, env func(string) string, sink Sink) (path, name string, ok bool) {
	if abs := absPath(cwd, retro); !isRegular(abs) {
		sink.Fail("absent-input: retro not found: %s", retro)
		return "", "", false
	}
	dir := filepath.Dir(retro)
	retro = filepath.Join(absPath(cwd, dir), filepath.Base(retro))
	targetDir := filepath.Dir(filepath.Dir(retro))
	targetsMD := filepath.Join(kitRoot, "research-sdd", "TARGETS.md")
	res, err := kit.NameForRetro(targetsMD, retro, cwd, env)
	for _, w := range res.Warnings {
		sink.Note("%s", w)
	}
	name = res.Name
	switch {
	case err == nil && name != "":
	case err != nil && kit.RC(err) == 1:
		sink.Note("%s", err.Error())
		sink.Fail("reconcile-issues: cannot resolve target for '%s' — operational failure reading %s (see message above)", retro, targetsMD)
		return "", "", false
	default:
		// No registered ancestor: a flat layout keeps the WARN + basename fallback; a structural directory is
		// refused (the writer refuses it too, so no issue can exist).
		name = filepath.Base(targetDir)
		if name == "corpus" || name == "retros" {
			sink.Fail("reconcile-issues: cannot resolve target for '%s' — no ancestor directory is registered in %s (basename '%s' is a structural directory, not a target)", retro, targetsMD, name)
			return "", "", false
		}
		sink.Note("WARN: target directory '%s' not found in %s — using basename '%s'", targetDir, targetsMD, name)
	}
	return retro, name, true
}

func absPath(cwd, p string) string {
	if !filepath.IsAbs(p) {
		p = filepath.Join(cwd, p)
	}
	return filepath.Clean(p)
}

func isRegular(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}
