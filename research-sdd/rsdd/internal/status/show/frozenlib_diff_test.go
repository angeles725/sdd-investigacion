//go:build unix && !nodiff

package show

import (
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
)

// The frozen sourced libraries: byte copies of research-sdd/toolbelt/lib at origin/main 31bb4be5 (the blob of
// research-sdd-status.sh the testdata/legacy excerpts come from, 7e734c53). The script sources state-files.sh,
// focus-prefix.sh, block-files.sh, hook-wiring.sh, blocked-rows.sh, retro-status.sh and gh-visibility.sh, and
// hook-wiring.sh sources rsdd-exec.sh. The differential stages THESE copies as the toolbelt's lib/, so editing,
// moving or deleting the live library never changes what the oracle does. Each sha256 is checked before the
// first scenario runs; the directory holds exactly these files.
const frozenLibDir = "testdata/legacy/lib"

var frozenLibSHA = map[string]string{
	"block-files.sh":   "b5980b1e9e8c5e490e2a2f9dffe584ddec8add7a7e260adb4f1fe150abc869e3",
	"blocked-rows.sh":  "51a54c6faedb923f68efb978fb93a0abd28e1fafd2ef9d13aec44695a9e8884d",
	"focus-prefix.sh":  "8f245f002a0a6ff2f75caf2ab314bb95b8651baa9aec3a41255a4c52eac284b5",
	"gh-visibility.sh": "76ee7c2fe15a49602379633c9e54f5fe2ac9ecfd5a5ee1ba2784d49e20af64c3",
	"hook-wiring.sh":   "95cab69c221726149112c8580046c0fce00f50f59330ddee14dacc75b5489e94",
	"retro-status.sh":  "d5c1cccdffdd9944ad3b8ab55fd509b8b1b7914ef07b59dda3da48219857cf40",
	"rsdd-exec.sh":     "aad3ec30dc32fb0d863d9ac5d31bcdc4d5105f034b4651d8d55c91b91ca6abb4",
	"state-files.sh":   "fe8e1798b6b8e6de81152baa854d008c6e7cf841918bd7f55c3f95924ae32989",
}

var (
	frozenLibOnce sync.Once
	frozenLibPath string
	frozenLibErr  string
)

// frozenLibAbs returns the absolute path of the frozen lib directory after checking its contents against the pin.
func frozenLibAbs(t testing.TB) (string, error) {
	t.Helper()
	frozenLibOnce.Do(func() {
		abs, err := filepath.Abs(frozenLibDir)
		if err != nil {
			frozenLibErr = err.Error()
			return
		}
		ents, err := os.ReadDir(abs)
		if err != nil {
			frozenLibErr = err.Error()
			return
		}
		var have []string
		for _, e := range ents {
			have = append(have, e.Name())
		}
		sort.Strings(have)
		var want []string
		for n := range frozenLibSHA {
			want = append(want, n)
		}
		sort.Strings(want)
		if len(have) != len(want) {
			frozenLibErr = "frozen lib directory holds " + join(have) + ", the pin lists " + join(want)
			return
		}
		for i, n := range want {
			if have[i] != n {
				frozenLibErr = "frozen lib directory holds " + join(have) + ", the pin lists " + join(want)
				return
			}
			b, err := os.ReadFile(filepath.Join(abs, n))
			if err != nil {
				frozenLibErr = err.Error()
				return
			}
			if got := sha(b); got != frozenLibSHA[n] {
				frozenLibErr = "frozen lib/" + n + " changed: sha256 " + got + ", the pin records " + frozenLibSHA[n]
				return
			}
		}
		frozenLibPath = abs
	})
	if frozenLibErr != "" {
		t.Fatalf("%s", frozenLibErr)
	}
	return frozenLibPath, nil
}

func join(s []string) string {
	out := ""
	for i, x := range s {
		if i > 0 {
			out += " "
		}
		out += x
	}
	return out
}
