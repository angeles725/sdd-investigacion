package commands

import (
	"os"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/lazyre"
)

// compiledAtStart is how many lazy patterns had compiled when the test binary started, i.e. during package
// initialisation of everything the rsdd binary links. Captured before any test runs.
var registeredAtStart, compiledAtStart = -1, -1

func TestMain(m *testing.M) {
	registeredAtStart, compiledAtStart = lazyre.Stats()
	os.Exit(m.Run())
}

// A pattern compiled during init is startup cost paid by every command, which is what lazyre exists to avoid.
func TestNoLazyPatternCompilesAtInit(t *testing.T) {
	if registeredAtStart <= 0 {
		t.Fatalf("empty-input: %d lazy patterns registered at start; the package-level patterns are not built through lazyre", registeredAtStart)
	}
	if compiledAtStart != 0 {
		t.Fatalf("%d of %d lazy patterns compiled during package init, want 0 (start-up cost on every rsdd command)", compiledAtStart, registeredAtStart)
	}
}

// Lazy compilation moves a bad pattern's panic from init to first use; this is the init-time check it gave up.
func TestEveryLazyPatternCompiles(t *testing.T) {
	n, err := lazyre.CompileAll()
	if n <= 0 {
		t.Fatalf("empty-input: CompileAll saw %d patterns", n)
	}
	if err != nil {
		t.Fatalf("a lazy pattern does not compile (%d checked): %v", n, err)
	}
}
