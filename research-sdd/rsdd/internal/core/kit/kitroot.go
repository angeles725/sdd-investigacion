package kit

import "fmt"

// ErrKitNoToolbelt: at least one candidate exists as a directory and none of them holds a toolbelt/ directory. It
// is an ErrKitUnresolved too, so a caller that tests for that keeps working.
var ErrKitNoToolbelt = &msgError{"kit: no toolbelt directory", ErrKitUnresolved}

// kitNotFoundText is the error text when no candidate exists as a directory.
const kitNotFoundText = "research-sdd kit not found (set RESEARCH_SDD_KIT)"

// ResolveKitRoot returns the kit root, as written by its source, without naming a script: the first candidate of
// kitCandidates that holds a toolbelt/ directory. warns carries the typed stderr line the bash prints before
// falling through (a set RESEARCH_SDD_KIT without a toolbelt/ directory). The failures are told apart: no
// candidate is a directory (ErrKitUnresolved with kitNotFoundText), or some are and none holds toolbelt/
// (ErrKitNoToolbelt, naming the first such directory).
func ResolveKitRoot(getenv Getenv) (root string, warns []string, err error) {
	if k := getenv("RESEARCH_SDD_KIT"); k != "" && !IsDirOS(k+"/toolbelt") {
		warns = append(warns, "kit-run: DEGRADED: RESEARCH_SDD_KIT="+k+" invalid (no toolbelt/ directory); trying the launcher files and the default checkout")
	}
	bare := ""
	for _, c := range kitCandidates(getenv) {
		if IsDirOS(c + "/toolbelt") {
			return c, warns, nil
		}
		if bare == "" && IsDirOS(c) {
			bare = c
		}
	}
	if bare != "" {
		return "", warns, &msgError{fmt.Sprintf("research-sdd kit has no toolbelt/ directory: %s (set RESEARCH_SDD_KIT)", bare), ErrKitNoToolbelt}
	}
	return "", warns, &msgError{kitNotFoundText, ErrKitUnresolved}
}
