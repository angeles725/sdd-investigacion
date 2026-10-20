package kit

import (
	"errors"
	"os"
	"strings"
)

// KitFS is the filesystem seen by kit resolution. Inject it; OSKitFS is the process edge.
type KitFS struct {
	IsDir    func(path string) bool
	IsFile   func(path string) bool            // `[ -f ]`: a regular file, symlinks followed
	ReadFile func(path string) ([]byte, error) // a missing or unreadable file returns an error
}

// OSKitFS reads the real filesystem.
var OSKitFS = KitFS{
	IsDir: func(p string) bool { st, err := os.Stat(p); return err == nil && st.IsDir() },
	IsFile: func(p string) bool {
		st, err := os.Stat(p)
		return err == nil && st.Mode().IsRegular()
	},
	ReadFile: os.ReadFile,
}

// ErrKitDegraded is the typed `kit-run: DEGRADED` failure: the kit or the script could not be resolved, which is
// a visible failure and never a silent allow.
var ErrKitDegraded = errors.New("kit: degraded")

// KitResult is a resolved kit. Notes are the typed stderr lines emitted on the way (an invalid RESEARCH_SDD_KIT).
type KitResult struct {
	Path   string
	Source string // "env", "launcher:<file>", "default"
	Notes  []string
}

func degraded(why string) error { return &msgError{"kit-run: DEGRADED: " + why, ErrKitDegraded} }

// launcherValue is the first `<key>:` line of the file, trimmed, backticks removed, a leading ~ expanded.
// A first matching line without a value ends the scan of that key (sed's `q`).
func launcherValue(body, key, home string) string {
	for _, l := range strings.Split(body, "\n") {
		v, ok := strings.CutPrefix(l, key+":")
		if !ok {
			continue
		}
		v = strings.Trim(v, " \t\n\v\f\r")
		v = strings.ReplaceAll(v, "`", "")
		if rest, ok := strings.CutPrefix(v, "~"); ok {
			v = home + rest
		}
		return v
	}
	return ""
}

// ResolveKit is kit_resolve of hook-kit-run.sh. First candidate with a toolbelt/ directory wins:
//  1. $RESEARCH_SDD_KIT (a set-but-invalid value is reported in Notes, never silently skipped)
//  2. the `Kit checkout:` then `Kit path:` line of AGENTS.md under $GENTLE_PI_AGENT_HOME, $PI_CODING_AGENT_DIR,
//     ~/.gentle-shell/agent, ~/.pi/agent, then ~/.claude/CLAUDE.md
//  3. $HOME/investigacion/sdd-investigacion/research-sdd
//
// Nothing resolving is a typed ErrKitDegraded.
func ResolveKit(getenv Getenv, fs KitFS) (KitResult, error) {
	home := getenv("HOME")
	var res KitResult
	type cand struct{ path, source string }
	var cands []cand
	if k := getenv("RESEARCH_SDD_KIT"); k != "" {
		cands = append(cands, cand{k, "env"})
		if !fs.IsDir(k + "/toolbelt") {
			res.Notes = append(res.Notes, "kit-run: DEGRADED: RESEARCH_SDD_KIT="+k+" invalid (no toolbelt/ directory); trying the launcher files and the default checkout")
		}
	}
	var files []string
	for _, d := range []string{getenv("GENTLE_PI_AGENT_HOME"), getenv("PI_CODING_AGENT_DIR")} {
		if d != "" {
			files = append(files, d+"/AGENTS.md")
		}
	}
	files = append(files, home+"/.gentle-shell/agent/AGENTS.md", home+"/.pi/agent/AGENTS.md", home+"/.claude/CLAUDE.md")
	for _, f := range files {
		if !fs.IsFile(f) {
			continue
		}
		b, err := fs.ReadFile(f)
		if err != nil {
			continue
		}
		for _, key := range []string{"Kit checkout", "Kit path"} {
			if v := launcherValue(string(b), key, home); v != "" {
				cands = append(cands, cand{v, "launcher:" + f})
			}
		}
	}
	cands = append(cands, cand{home + "/investigacion/sdd-investigacion/research-sdd", "default"})
	for _, c := range cands {
		if c.path != "" && fs.IsDir(c.path+"/toolbelt") {
			res.Path, res.Source = c.path, c.source
			return res, nil
		}
	}
	return res, degraded("research-sdd kit not found (set RESEARCH_SDD_KIT)")
}

// ResolveKitScript is the whole front half of hook-kit-run.sh: validate the kit-relative script, resolve the kit,
// require the script file. The error text is the stderr line. (The PreToolUse pkill guard's fail-closed `ask`
// answer is the caller's: see DEFERRED.md.)
func ResolveKitScript(rel string, getenv Getenv, fs KitFS) (KitResult, error) {
	if rel == "" {
		return KitResult{}, degraded("no script given")
	}
	fail := func(why string) error { return degraded(why + "; " + rel + " did NOT run") }
	if strings.HasPrefix(rel, "/") || strings.Contains("/"+rel+"/", "/../") {
		return KitResult{}, fail("script path '" + rel + "' must be kit-relative without '..'")
	}
	res, err := ResolveKit(getenv, fs)
	if err != nil {
		return res, fail("research-sdd kit not found (set RESEARCH_SDD_KIT)")
	}
	if !fs.IsFile(res.Path + "/" + rel) {
		return res, fail(res.Path + "/" + rel + " is missing")
	}
	return res, nil
}
