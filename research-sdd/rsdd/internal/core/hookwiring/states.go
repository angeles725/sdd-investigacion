package hookwiring

// The states hook_stop_wiring_state_var can report.
const (
	WiringWired          = "wired"
	WiringWiredOffRoot   = "wired-off-root"
	WiringUnwired        = "unwired"
	WiringAbsentSettings = "absent-settings"
	WiringUnreadable     = "unreadable"
)

// The states hook_stop_launch_state_var can report (kit issue #2357). Unknown is "the instrument could not look":
// it makes no claim in either direction and never reads as no-sessions.
const (
	LaunchLaunched   = "launched"
	LaunchNoSessions = "no-sessions"
	LaunchUnknown    = "unknown"
)

// The states hook_stop_script_state_var can report.
const (
	ScriptPresent      = "present"
	ScriptMissing      = "missing"
	ScriptUnverifiable = "unverifiable"
	ScriptNoEntry      = "no-entry"
	ScriptDegraded     = "degraded"
)
