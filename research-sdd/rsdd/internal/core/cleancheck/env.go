package cleancheck

// The variables of the script's own contract that Options.Env feeds when the explicit field is empty (TMPDIR is
// read by resolveTmp).
const (
	envScratchpad = "CLEAN_CHECK_SCRATCHPAD"
	envUID        = "CLEAN_CHECK_UID"
)

// applyEnv fills the scratchpad and the owner uid from Options.Env when the explicit field is empty, so the command
// and an in-process caller read the same inputs from the same place. An empty variable is "not given", as in the
// script's `${VAR:-}`.
func (r *run) applyEnv() {
	if r.o.Scratchpad == "" {
		r.o.Scratchpad, _ = envValue(r.o.Env, envScratchpad)
	}
	if r.o.UID == "" {
		r.o.UID, _ = envValue(r.o.Env, envUID)
	}
}
