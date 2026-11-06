package cleancheck

import "time"

// Options is everything one run needs. The environment, the working directory and the clock arrive here, so a caller
// (the command, or internal/status/show) decides them; a field left at its zero value means "not given", exactly as
// the flag absent from `clean-check --target X`.
//
// What a run reads from the process, and when: the owner uid through os.Getuid, only when neither UID, the
// CLEAN_CHECK_UID variable of Env nor Self supplies one; the file system (the target, the tmp directory, the
// scratchpad) and the git children it starts, which receive Env (without the repository selectors, with
// GIT_OPTIONAL_LOCKS=0) as their whole environment; and the real clock for the
// deadline of the context. It never reads the process environment or working directory.
type Options struct {
	Target     string // --target; empty means Cwd
	Tmp        string // --tmp; empty means TMPDIR of Env, else /tmp
	Scratchpad string // --scratchpad; empty means CLEAN_CHECK_SCRATCHPAD of Env, else not configured
	Base       string // --base REF; empty means origin/HEAD, then main, then master
	Evidence   string // --evidence DIR; empty means every _evidence directory below the target
	StaleHours Age    // --stale-hours; unset means DefaultStaleHours, AgeOf(0) makes every owned tmp.* entry stale
	BackupDays Age    // --backup-days; unset means DefaultBackupDays, AgeOf(0) makes every matching backup stale
	UID        string // the owner uid of the tmp.* filter; empty means CLEAN_CHECK_UID of Env, else the current user

	Env  []string         // KEY=VALUE: the environment of git, and TMPDIR, CLEAN_CHECK_SCRATCHPAD and CLEAN_CHECK_UID; PATH decides whether git exists
	Cwd  string           // required, absolute: what a relative path is relative to
	Now  func() time.Time // required: the clock of every age
	Self func() int       // the uid of the current user; nil means the process uid
}
