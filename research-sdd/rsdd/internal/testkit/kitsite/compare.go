// Package kitsite is the shared harness of the site tests of the commands that find the kit without a flag
// (#2770): it builds a hermetic kit, runs a public command against it and compares stdout, stderr and the exit
// code together. This file holds the pure parts; kit.go, run.go and scenarios.go hold the rest.
package kitsite

import (
	"fmt"
	"path/filepath"
	"strings"
)

// Compare returns the text of the mismatch between what a command produced and what was expected, or "" when the
// stdout, the stderr and the exit code all match. The message names every stream, so one failure shows them all.
func Compare(gotOut, gotErr string, gotRC int, wantOut, wantErr string, wantRC int) string {
	if gotOut == wantOut && gotErr == wantErr && gotRC == wantRC {
		return ""
	}
	return fmt.Sprintf("got rc=%d\nstdout %q\nstderr %q\nwant rc=%d\nstdout %q\nstderr %q",
		gotRC, gotOut, gotErr, wantRC, wantOut, wantErr)
}

// Expand replaces the placeholders of an expected text: "@K@" the kit root, "@T@" its toolbelt directory, "@P@"
// the parent of the kit root and "@H@" the home.
func Expand(text, kitRoot, home string) string {
	return strings.NewReplacer("@T@", kitRoot+"/toolbelt", "@K@", kitRoot, "@P@", filepath.Dir(kitRoot), "@H@", home).Replace(text)
}

// InvalidKitWarning is the stderr line the kit-root resolver prints for a RESEARCH_SDD_KIT directory without
// toolbelt/ (newline included).
func InvalidKitWarning(bare string) string {
	return "kit-run: DEGRADED: RESEARCH_SDD_KIT=" + bare + " invalid (no toolbelt/ directory); trying the launcher files and the default checkout\n"
}
