package cleancheck

import "time"

// Defaults of the two ages, as the script had them.
const (
	DefaultStaleHours = 24
	DefaultBackupDays = 14
)

// Options is everything one run needs. Nothing is read from the process: the environment, the working directory
// and the clock arrive here, so a caller (the command, or internal/status/show) decides them.
type Options struct {
	Target     string // --target; empty means Cwd
	Tmp        string // --tmp; empty means the TMPDIR of Env, else /tmp
	Scratchpad string // --scratchpad, or $CLEAN_CHECK_SCRATCHPAD when the flag is absent; empty means not configured
	Base       string // --base REF; empty means origin/HEAD, then main, then master
	Evidence   string // --evidence DIR; empty means every _evidence directory below the target
	StaleHours int    // --stale-hours; 0 makes every owned tmp.* entry stale (the caller applies DefaultStaleHours)
	BackupDays int    // --backup-days; 0 makes every matching backup stale (the caller applies DefaultBackupDays)
	UID        string // $CLEAN_CHECK_UID, the owner uid of the tmp.* filter; empty means the current user

	Env  []string         // the environment of git and of the TMPDIR lookup (KEY=VALUE); PATH decides whether git exists
	Cwd  string           // what a relative path is relative to
	Now  func() time.Time // the clock of every age
	Self func() int       // the uid of the current user; nil means the process uid
}
