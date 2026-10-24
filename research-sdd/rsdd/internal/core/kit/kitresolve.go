package kit

import (
	"errors"
	"strings"
)

// Port of the kit resolution of templates/hook-kit-run.sh (kit #2175): which research-sdd checkout a portable hook
// runs, resolved at run time.

// ErrKitUnresolved: no kit, a script path that would escape the kit, or a missing script. The error text is the
// `<why>` of the bash `kit-run: DEGRADED: <why>; <rel> did NOT run` line, a typed visible failure (never an allow).
var ErrKitUnresolved = errors.New("kit: kit unresolved")

// ResolveKitScript resolves the kit-relative script rel to "<kit>/<rel>". warns carries the typed stderr lines the
// bash prints before falling through (a set-but-invalid RESEARCH_SDD_KIT). An empty rel is ErrUsage ("no script
// given"); an absolute rel or one with a `..` segment, no kit, and a missing script are ErrKitUnresolved, checked
// in that order.
func ResolveKitScript(rel string, getenv Getenv) (path string, warns []string, err error) {
	if rel == "" {
		return "", nil, &msgError{"no script given", ErrUsage}
	}
	if strings.HasPrefix(rel, "/") || strings.Contains("/"+rel+"/", "/../") {
		return "", nil, &msgError{"script path '" + rel + "' must be kit-relative without '..'", ErrKitUnresolved}
	}
	if k := getenv("RESEARCH_SDD_KIT"); k != "" && !IsDirOS(k+"/toolbelt") {
		warns = append(warns, "kit-run: DEGRADED: RESEARCH_SDD_KIT="+k+" invalid (no toolbelt/ directory); trying the launcher files and the default checkout")
	}
	kit := ""
	for _, c := range kitCandidates(getenv) {
		if IsDirOS(c + "/toolbelt") {
			kit = c
			break
		}
	}
	if kit == "" {
		return "", warns, &msgError{"research-sdd kit not found (set RESEARCH_SDD_KIT)", ErrKitUnresolved}
	}
	if !isRegularOS(kit + "/" + rel) {
		return "", warns, &msgError{kit + "/" + rel + " is missing", ErrKitUnresolved}
	}
	return kit + "/" + rel, warns, nil
}

// kitCandidates is the resolution order: $RESEARCH_SDD_KIT; the `Kit checkout:` then `Kit path:` value of each
// launcher file that is a regular file (AGENTS.md under $GENTLE_PI_AGENT_HOME, $PI_CODING_AGENT_DIR,
// ~/.gentle-shell/agent and ~/.pi/agent, then ~/.claude/CLAUDE.md); the default checkout. Empty entries are
// dropped; the caller takes the first one holding a toolbelt/ directory.
func kitCandidates(getenv Getenv) []string {
	home := getenv("HOME")
	var files, out []string
	for _, d := range []string{getenv("GENTLE_PI_AGENT_HOME"), getenv("PI_CODING_AGENT_DIR")} {
		if d != "" {
			files = append(files, d+"/AGENTS.md")
		}
	}
	files = append(files, home+"/.gentle-shell/agent/AGENTS.md", home+"/.pi/agent/AGENTS.md", home+"/.claude/CLAUDE.md")
	if k := getenv("RESEARCH_SDD_KIT"); k != "" {
		out = append(out, k)
	}
	for _, f := range files {
		src, _ := readRegular(f) // absent or unreadable reads as "", as `[ -f ]` and `sed … 2>/dev/null || line=""` do
		for _, key := range []string{"Kit checkout", "Kit path"} {
			if v := launcherValue(src, key); v != "" {
				if rest, ok := strings.CutPrefix(v, "~"); ok { // ${line/#\~/$HOME}: "~x" becomes "$HOME"+"x"
					v = home + rest
				}
				out = append(out, v)
			}
		}
	}
	return append(out, home+"/investigacion/sdd-investigacion/research-sdd")
}

// launcherValue is the sed of hook-kit-run.sh: only the FIRST line that starts with "<key>:" is read; its value
// is trimmed of blanks ([[:space:]], C locale) and stripped of every backtick.
func launcherValue(src, key string) string {
	for _, line := range strings.Split(src, "\n") {
		if v, ok := strings.CutPrefix(line, key+":"); ok {
			return strings.ReplaceAll(strings.Trim(v, cSpace), "`", "")
		}
	}
	return ""
}
