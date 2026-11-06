package toolcatalog

// The two inputs of the check, beside each other in the toolbelt directory.
const (
	installedFile = "INSTALLED-TOOLS.md"
	registryFile  = "tool-registry.md"
)

// The report of the check, word for word. The lines that name a typed input state (absent-input, empty-input,
// no-match) are written where they are printed, in check.go: the reason-codes registry test finds an emitter by the
// literal at the call.
const (
	warnFmt    = "WARN  installed-but-not-cataloged: '%s' is logged in INSTALLED-TOOLS.md but has no entry in tool-registry.md — add a capability row (Artifact type / Tool / Wrapper, or the '(direct)' pattern for a manual tool) and, if it has a resolvable binary, a row in \"## Tool paths (verified)\" (propose-never-apply; never auto-edited)."
	summaryFmt = "Summary: %d distinct tool(s) logged in INSTALLED-TOOLS.md · %d cataloged · %d not cataloged."
	gapFmt     = "Catalog gap(s) — not cataloged: %s"
	usageLine  = "usage: rsdd verify tool-catalog [<toolbelt-dir>]"
)

// The contexts of the SessionStart hook.
const (
	hookCouldNotRunFmt = "Research-SDD tool catalog check could not run (exit %d — check INSTALLED-TOOLS.md and tool-registry.md):"
	hookNoSummary      = "Research-SDD tool catalog check: missing Summary line — unexpected output from verify-tool-catalog.sh:"
	hookDriftHeader    = "Research-SDD tool catalog drift (installed but not cataloged):"
	hookCleanFmt       = "Research-SDD tool catalog: clean (%s logged tools, 0 uncataloged)."
	hookCollapsedFmt   = "WARN  installed-but-not-cataloged (%d): %s — add a tool-registry.md row each (propose-never-apply)."
	hookFullList       = "Run toolbelt/verify-tool-catalog.sh for the full list."
	hookUsageHeader    = "Research-SDD tool catalog hook could not run (usage error):"
	hookUsageLine      = "usage: rsdd verify tool-catalog-hook [<toolbelt-dir>] [--full]"
	hookRerun          = "rsdd verify tool-catalog" // the command whose own output a capped failure context points at (#2631)
	notCatalogedWarn   = "WARN  installed-but-not-cataloged: '"
	compactWarnBytes   = 160 // `cut -c1-160` counts bytes
)
