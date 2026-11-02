package hook

// The states hook_stop_wiring_state_var can report.
const (
	WiringWired          = "wired"
	WiringWiredOffRoot   = "wired-off-root"
	WiringUnwired        = "unwired"
	WiringAbsentSettings = "absent-settings"
	WiringUnreadable     = "unreadable"
)

// The states hook_stop_script_state_var can report.
const (
	ScriptPresent      = "present"
	ScriptMissing      = "missing"
	ScriptUnverifiable = "unverifiable"
	ScriptNoEntry      = "no-entry"
	ScriptDegraded     = "degraded"
)
