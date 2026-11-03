// Package parallelfloor raises the default parallelism of a test binary whose tests wait on subprocesses.
//
// `go test -parallel` defaults to GOMAXPROCS. The kit runs tests with GOMAXPROCS=2 (CLAUDE.md, Go build hygiene), so
// t.Parallel() alone runs at most two subprocess-bound tests at once and buys almost nothing: internal/gate went from
// 213 s to 206 s with t.Parallel() alone and to 72 s with a floor of 8 (kit issue #2665, lesson L69). A package that
// spends its time waiting on bash, git or rsdd children calls Raise from its TestMain:
//
//	func TestMain(m *testing.M) {
//		parallelfloor.Raise(8)
//		os.Exit(m.Run())
//	}
package parallelfloor

import (
	"flag"
	"fmt"
	"strconv"
)

// flagName is the testing package's -parallel flag as the test binary registers it.
const flagName = "test.parallel"

// Raise sets -test.parallel to min when its current value is lower and it was not given on the command line. An
// explicit -parallel always wins, so `go test -parallel 1` still serialises a run. It parses the command line first
// when TestMain has not, and panics when the flag holds a value that is not an integer, which the testing package
// never produces.
func Raise(min int) {
	if !flag.Parsed() {
		flag.Parse()
	}
	if err := raise(flag.CommandLine, min); err != nil {
		panic(err)
	}
}

// raise is Raise over any flag set. A flag set without -test.parallel is left alone.
func raise(fs *flag.FlagSet, min int) error {
	f := fs.Lookup(flagName)
	if f == nil {
		return nil
	}
	explicit := false
	fs.Visit(func(v *flag.Flag) { explicit = explicit || v.Name == flagName })
	if explicit {
		return nil
	}
	cur, err := strconv.Atoi(f.Value.String())
	if err != nil {
		return fmt.Errorf("parallelfloor: -%s is %q, not an integer", flagName, f.Value.String())
	}
	if cur >= min {
		return nil
	}
	return f.Value.Set(strconv.Itoa(min))
}
