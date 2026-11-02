package hookwiring

import (
	"os"
	"strings"
)

// anchor makes a relative path absolute against the Env cwd: the bash library relied on the process cwd for every
// file test, Env.Cwd is that cwd made explicit.
func anchor(e Env, p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	return e.Cwd + "/" + p
}

// maxEncodedName is the longest directory name Claude Code keeps untruncated.
const maxEncodedName = 200

// LaunchState is the port of hook_stop_launch_state_var: has a Claude Code session ever been launched from exactly
// this directory? It looks only at the EXISTENCE of a `*.jsonl` entry in Claude Code's per-project history
// directory, never at a transcript's contents.
//
//	launched     the history directory for target (the absolute, ./..-collapsed path with every character
//	             outside [A-Za-z0-9] replaced by '-') holds at least one non-hidden `*.jsonl` entry. This says
//	             nothing about whether the hook existed at the time.
//	no-sessions  the history root is readable but holds no such entry for target (Claude Code prunes old
//	             transcripts, and another harness leaves none).
//	unknown      the instrument could not look: no root (RSDD_CLAUDE_PROJECTS_DIR, else CLAUDE_CONFIG_DIR/projects,
//	             else HOME/.claude/projects), the root is not a readable directory, the path has a byte outside
//	             space..'~', the encoded name exceeds 200 characters, or a component of the path is a symlink
//	             (Claude Code records the resolved path, which is not computed here). No claim either way.
//
// Deviation from the shell original, which globbed "$root/$enc/*.jsonl": the root is taken literally here, so a
// root containing * ? [ or \ is no longer read as a pattern.
func LaunchState(e Env, target string) string {
	root := e.getenv(envProjectsDir)
	if root == "" {
		if c := e.getenv(envConfigDir); c != "" {
			root = c + "/projects"
		} else if h := e.getenv(envHome); h != "" {
			root = h + "/.claude/projects"
		} else {
			return LaunchUnknown
		}
	}
	rootPath := anchor(e, root)
	if st, err := os.Stat(rootPath); err != nil || !st.IsDir() || !accessOK(rootPath, accR) {
		return LaunchUnknown
	}
	d := AbsPath(e.Cwd, target)
	for i := 0; i < len(d); i++ {
		if d[i] < ' ' || d[i] > '~' { // HOOK-LAUNCH-NONASCII-GUARD: *[!\ -~]*
			return LaunchUnknown
		}
	}
	// SYMLINK GUARD: every prefix of the collapsed path, leaf included.
	for c := d; c != "" && c != "/"; c = c[:strings.LastIndexByte(c, '/')] {
		if st, err := os.Lstat(c); err == nil && st.Mode()&os.ModeSymlink != 0 { // HOOK-LAUNCH-SYMLINK-GUARD
			return LaunchUnknown
		}
	}
	enc := make([]byte, len(d))
	for i := 0; i < len(d); i++ {
		b := d[i]
		if b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' {
			enc[i] = b
		} else {
			enc[i] = '-'
		}
	}
	if len(enc) > maxEncodedName { // HOOK-LAUNCH-LONGNAME-GUARD
		return LaunchUnknown
	}
	if hasTranscript(rootPath + "/" + string(enc)) { // HOOK-LAUNCH-HISTORY-CHECK
		return LaunchLaunched
	}
	return LaunchNoSessions
}

// hasTranscript is the glob `dir/*.jsonl`: any entry, whatever its type, named *.jsonl that is not hidden.
func hasTranscript(dir string) bool {
	f, err := os.Open(dir)
	if err != nil {
		return false
	}
	defer f.Close()
	names, _ := f.Readdirnames(0) // n <= 0 reads every entry; entries read before an error still count, like a partial glob
	for _, n := range names {
		if !strings.HasPrefix(n, ".") && strings.HasSuffix(n, ".jsonl") {
			return true
		}
	}
	return false
}
