package cleancheck

import (
	"reflect"
	"testing"
)

func denied(p string) findError { return findError{path: p, denied: true, reason: "Permission denied"} }
func broken(p string) findError { return findError{path: p, reason: "No such file or directory"} }

// The classification of the discovery's read errors, independent of the user (a permission error is a value here).
func TestClassifyDiscovery(t *testing.T) {
	const tgt = "/r/target"
	info := func(p string) string {
		return "INFO evidence-discovery skipped unreadable directory (evidence dirs below it, if any, are not scanned): find: '" + p + "': Permission denied"
	}
	for name, c := range map[string]struct {
		errs       []findError
		infos      []string
		unreadable int
		fatal      bool
	}{
		"unreadable outside an evidence dir": {[]findError{denied(tgt + "/other/locked")}, []string{info(tgt + "/other/locked")}, 1, false},
		"two of them":                        {[]findError{denied(tgt + "/a"), denied(tgt + "/b")}, []string{info(tgt + "/a"), info(tgt + "/b")}, 2, false},
		"under an evidence dir":              {[]findError{denied(tgt + "/_evidence/t/locked")}, nil, 0, true},
		"the evidence dir itself":            {[]findError{denied(tgt + "/a/_evidence")}, nil, 0, true},
		"not a permission error":             {[]findError{broken(tgt + "/other")}, nil, 0, true},
		"a dir named Permission denied":      {[]findError{broken(tgt + "/Permission denied")}, nil, 0, true},
		"the target path itself holds it":    {[]findError{denied("/r/_evidence/target/other/locked")}, nil, 0, true},
		"info before a later fatal":          {[]findError{denied(tgt + "/a"), broken(tgt + "/b"), denied(tgt + "/c")}, []string{info(tgt + "/a")}, 1, true},
		"fatal first":                        {[]findError{denied(tgt + "/_evidence/x"), denied(tgt + "/a")}, nil, 0, true},
		"a component that only contains it":  {[]findError{denied(tgt + "/x_evidence/y")}, []string{info(tgt + "/x_evidence/y")}, 1, false},
	} {
		infos, n, fatal := classifyDiscovery(tgt, c.errs)
		if !reflect.DeepEqual(infos, c.infos) || n != c.unreadable || fatal != c.fatal {
			t.Errorf("%s: %q %d %v, want %q %d %v", name, infos, n, fatal, c.infos, c.unreadable, c.fatal)
		}
	}
}

// The target's own path never counts as being under an evidence dir: the path is judged below the target.
func TestAnEvidenceNamedTargetStillSkipsAnUnreadableDir(t *testing.T) {
	infos, n, fatal := classifyDiscovery("/case/_evidence/repo", []findError{denied("/case/_evidence/repo/other/locked")})
	if fatal || n != 1 || len(infos) != 1 {
		t.Errorf("%q %d %v", infos, n, fatal)
	}
}
