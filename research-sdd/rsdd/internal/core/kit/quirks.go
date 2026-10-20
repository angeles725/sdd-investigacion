package kit

// Quirks names the legacy bash behaviours that are accidents of the shell implementation rather than design.
// They are kept by default (byte parity with the bash libs) but are explicit, documented and individually pinned,
// the way core/gfm exposes Shape and Raw. None has a measured caller dependency (see DEFERRED.md); each is a
// candidate for removal once the bash libs are retired.
type Quirks struct {
	// RowBlanks (F1) is the set of bytes allowed before a row's leading pipe. Legacy bash `^\s*\|` accepts
	// space, tab, \v, \f and \r; core/gfm accepts space and tab only.
	RowBlanks string
	// SplitEscapedPipes (F5): target_name_for_retro splits rows on every pipe (awk -F'|'), so `\|` in a cell
	// shifts the columns. False reads cells with core/gfm, which honours `\|`.
	SplitEscapedPipes bool
	// FindNoTypeFilter (F7): `find -name` without `-type`, so a DIRECTORY named like a state file is listed, and
	// `-not -path '*/.git/*'` tests the whole printed path, so a corpus living under a .git directory is excluded.
	// False lists only non-directories and tests the .git component below the start directory only.
	FindNoTypeFilter bool
}

// LegacyBash reproduces the bash libs exactly (legacy bash behaviour, see F1/F5/F7 in DEFERRED.md).
var LegacyBash = Quirks{RowBlanks: " \t\v\f\r", SplitEscapedPipes: true, FindNoTypeFilter: true}

// GFMShaped is the same behaviour with the three accidents removed.
var GFMShaped = Quirks{RowBlanks: " \t"}

// Behaviour selects the active quirks for the package. Set it once at the process edge, never concurrently.
var Behaviour = LegacyBash
