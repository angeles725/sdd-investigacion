package serial

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// `rsdd serial console` is registered in this domain's table, keeps the legacy exit-3 stderr (PlainExit3) and is
// reachable through the same dispatch the binary uses.
func TestConsoleIsRegisteredInTheSerialDomain(t *testing.T) {
	var found *cli.Command
	for i := range Commands {
		if Commands[i].Group == "serial" && Commands[i].Name == "console" {
			found = &Commands[i]
		}
	}
	if found == nil {
		t.Fatal("serial console is not in Commands")
	}
	if !found.PlainExit3 || found.Run == nil || found.Summary == "" {
		t.Errorf("entry %+v: want PlainExit3, a Run and a Summary", *found)
	}
	if err := cli.Validate(Commands); err != nil {
		t.Fatal(err)
	}
	s, out, errb := testStdio(t.TempDir())
	if rc := cli.Run(Commands, []string{"serial", "console"}, s); rc != cli.ExitUsage ||
		!strings.HasPrefix(errb.String(), "usage:\n  serial-console.sh list\n") || out.Len() != 0 {
		t.Errorf("rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
	}
}
