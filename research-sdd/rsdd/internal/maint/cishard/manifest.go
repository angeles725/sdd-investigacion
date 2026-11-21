package cishard

import (
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// manifestArgs is what the manifest command line said.
type manifestArgs struct {
	spec    shardSpec
	rc      int
	planned string
}

// parseManifestArgs reads --shard I/N --exit RC --planned FILE, all three required; the error text is the usage message.
func parseManifestArgs(args []string) (manifestArgs, error) {
	f := flag.NewFlagSet("manifest", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	shard := f.String("shard", "", "")
	exit := f.String("exit", "", "")
	planned := f.String("planned", "", "")
	if err := f.Parse(args); err != nil {
		return manifestArgs{}, err
	}
	if f.NArg() > 0 {
		return manifestArgs{}, fmt.Errorf("unexpected argument %q", f.Arg(0))
	}
	spec, err := parseShard(*shard)
	if err != nil {
		return manifestArgs{}, err
	}
	rc, err := strconv.Atoi(*exit)
	if err != nil || !digits(*exit) || rc > 255 {
		return manifestArgs{}, fmt.Errorf("invalid --exit value %q: need the status of make, an integer 0 to 255", *exit)
	}
	if *planned == "" {
		return manifestArgs{}, fmt.Errorf("--planned FILE is required")
	}
	return manifestArgs{spec: spec, rc: rc, planned: *planned}, nil
}

// runManifest is `rsdd maint ci-shard manifest`: the `go test -json` stream on stdin becomes the manifest on stdout.
// Findings and notes go to stderr; any finding makes the exit 1, and the manifest is still written.
func runManifest(args []string, s cli.Stdio) int {
	a, err := parseManifestArgs(args)
	if err != nil {
		return usage(s, err.Error())
	}
	in, err := readStdin(s)
	if err != nil {
		fmt.Fprintf(s.Err, "ci-shard: absent-input — the go test -json stream on stdin could not be read: %v\n", err)
		return exitFindings
	}
	raw, err := readPath(s, a.planned)
	if err != nil {
		fmt.Fprintf(s.Err, "ci-shard: absent-input — planned list %s could not be read: %v\n", a.planned, err)
		return exitFindings
	}
	planned, issue := parsePackages(raw)
	if issue != nil {
		return refuseList(s, "planned list", issue)
	}
	st := readStream(in)
	m := buildManifest(a.spec, a.rc, planned, st)
	fmt.Fprint(s.Out, m.text)
	for _, f := range m.findings {
		fmt.Fprintf(s.Err, "ci-shard: FINDING — %s\n", f)
	}
	if len(m.raised) > 0 {
		fmt.Fprintf(s.Err, "ci-shard: header exit raised to 1 because of findings: %s\n", strings.Join(m.raised, ", "))
	}
	for _, l := range reportLines(st) {
		fmt.Fprintln(s.Err, l)
	}
	if len(m.findings) > 0 {
		return exitFindings
	}
	return exitOK
}
