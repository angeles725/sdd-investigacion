package kitwait

import (
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// Knobs are the numeric environment settings of kit-wait-merge. The bash fed them straight to `[ -lt ]` and `$(( ))`:
// a non-number printed a shell error and either ended the poll early or crashed the run (`unbound variable`).
var Knobs = []string{"KIT_POLL_MAX", "KIT_POLL_SLEEP", "KIT_MERGE_TRIES", "KIT_MERGE_SLEEP", "KIT_RETRY_SLEEP"}

// BadKnob names the first knob set to something other than digits ("" when all are fine or unset). Callers turn it
// into a usage error before anything runs.
func BadKnob(getenv func(string) string) string {
	for _, k := range Knobs {
		if v := getenv(k); v != "" && !kitmaint.AllDigits(v) {
			return k
		}
	}
	return ""
}

// MergeGateMissing is the up-front `[ -f "$mg" ]` of kit-wait-merge.sh: "" when the merge gate can run, else what to
// print after `merge-gate.sh not found: `. A relative script is looked up from base (the directory the tool runs in).
// With no script the gate is the rsdd binary self, which must be known and exist.
func MergeGateMissing(script, self, base string) string {
	if script != "" {
		if !isFile(kitmaint.Abs(base, script)) {
			return script
		}
		return ""
	}
	if self == "" {
		return "the rsdd binary (the default merge gate) cannot be located"
	}
	if !isFile(self) {
		return self
	}
	return ""
}

// isFile is `[ -f p ]`.
func isFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}
