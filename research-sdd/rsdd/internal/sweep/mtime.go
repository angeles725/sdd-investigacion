package sweep

import "os"

// lmtime is `stat -c %Y f`: the file's own mtime in epoch seconds, NOT following a symbolic link. A retro or audit
// reachable through a link is as old as the link, exactly as the bash fallback read it.
func lmtime(f string) (int64, bool) {
	st, err := os.Lstat(f)
	if err != nil {
		return 0, false
	}
	return st.ModTime().Unix(), true
}
