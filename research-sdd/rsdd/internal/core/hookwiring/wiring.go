package hookwiring

import (
	"errors"
	"io/fs"
	"os"
	"strings"
	"syscall"
)

// settingsOf is <target>/.claude/settings.json, built by plain concatenation
// like the bash library (the target is not normalised); a relative result is anchored at Env.Cwd.
func settingsOf(e Env, target string) string {
	p := target + "/.claude/settings.json"
	if !strings.HasPrefix(p, "/") { // the bash library relies on the process cwd; Env.Cwd is that cwd, made explicit
		p = e.Cwd + "/" + p
	}
	return p
}

// readSettings reads the settings file the way the awk scan sees it. A
// directory reads as no record at all (gawk skips it with a warning).
func readSettings(e Env, path string) (data string, err error) {
	b, err := e.readFile(path)
	if err != nil {
		if errors.Is(err, syscall.EISDIR) {
			return "", nil
		}
		return "", err
	}
	return string(b), nil
}

// readable is `[ -r path ]` for a path already known to exist.
func readable(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return !errors.Is(err, fs.ErrPermission)
	}
	_ = f.Close()
	return true
}

// WiringState is the port of hook_stop_wiring_state_var: it classifies the
// Stop hook registration of <target>/.claude/settings.json.
//
//	absent-settings  the file does not exist (a dangling symlink counts)
//	unreadable       it exists but cannot be read
//	wired            its top-level "Stop" value registers a command containing "retro-gate"
//	wired-off-root   wired, but the target is not its own git root (structural fact only)
//	unwired          readable, with no such Stop-scoped entry (a failed read lands here too,
//	                 as an awk failure did)
func WiringState(e Env, target string) string {
	settings := settingsOf(e, target)
	if _, err := os.Stat(settings); err != nil {
		return WiringAbsentSettings
	}
	if !readable(settings) {
		return WiringUnreadable
	}
	data, err := readSettings(e, settings)
	if err != nil {
		return WiringUnwired
	}
	found := false
	walkStop(data, func(_ string, i int) int { found = true; return i })
	if !found {
		return WiringUnwired
	}
	// SESSION-ROOT CHECK (kit issue #1135): only an already-wired result is downgraded.
	norm := AbsPath(e.Cwd, target)
	root, isRoot := FindGitRoot(e, target)
	if !isRoot && root != "" && root != norm {
		return WiringWiredOffRoot
	}
	return WiringWired
}
