package bacnet

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const (
	tool         = "corroborate-bacnet"
	evidenceName = "bacnet-evidence.v1.json"
)

// jsonInt carries an integer of any size into the encoder.
func jsonInt(n *big.Int) json.Number { return json.Number(n.String()) }

// intFlag is argparse's type=int: Python int() syntax, any magnitude.
type intFlag struct{ v *big.Int }

func (f *intFlag) String() string {
	if f == nil || f.v == nil {
		return ""
	}
	return f.v.String()
}

func (f *intFlag) Set(s string) error {
	n, ok := parsePyInt(s)
	if !ok {
		return fmt.Errorf("invalid int value: %s", pyRepr(s))
	}
	f.v = n
	return nil
}

// floatFlag is argparse's type=float: Python float() syntax.
type floatFlag struct{ v float64 }

func (f *floatFlag) String() string {
	if f == nil {
		return ""
	}
	return fmt.Sprint(f.v)
}

func (f *floatFlag) Set(s string) error {
	v, ok := parsePyFloat(s)
	if !ok {
		return fmt.Errorf("invalid float value: %s", pyRepr(s))
	}
	f.v = v
	return nil
}

// CorroborateBACnet is `rsdd bacnet corroborate-bacnet`: the read-only BACnet/IP reachability and BBMD probe
// (bacnet-evidence.v1).
func CorroborateBACnet(args []string, s cli.Stdio) int {
	var host, output, localBcast, bbmd string
	port := &intFlag{v: big.NewInt(defaultPort)}
	srcPort := &intFlag{v: big.NewInt(0)}
	timeout := &floatFlag{v: 3.0}
	var live, asJSON bool
	fs := flag.NewFlagSet(tool, flag.ContinueOnError)
	fs.SetOutput(s.Err)
	fs.StringVar(&host, "host", "", "target BACnet/IP host (field device or BBMD IP)")
	fs.StringVar(&output, "output", "", "output directory; bacnet-evidence.v1.json is written here")
	fs.Var(port, "port", "BACnet/IP UDP port (default 47808)")
	fs.Var(srcPort, "src-port", "local UDP bind port (default 0 = ephemeral)")
	fs.StringVar(&localBcast, "local-bcast", "", "broadcast address of this interface; required for the broadcast Who-Is test")
	fs.StringVar(&bbmd, "bbmd", "", "additional IP to probe as BBMD; --host is always probed")
	fs.Var(timeout, "timeout", "per-probe listen window in seconds (default 3.0)")
	fs.BoolVar(&live, "allow-live-probe", false, "send real BACnet/IP UDP frames; absent: exit 3 (plan-only)")
	fs.BoolVar(&asJSON, "json", false, "also write evidence to stdout as JSON")
	usage := "usage: rsdd bacnet corroborate-bacnet --host HOST --output DIR [--port N] [--src-port N] [--local-bcast IP] [--bbmd IP] [--timeout SECONDS] [--allow-live-probe] [--json]"
	fs.Usage = func() { fmt.Fprintln(s.Err, usage) }
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return cli.ExitOK
		}
		return cli.ExitUsage
	}
	usageErr := func(msg string) int {
		fmt.Fprintln(s.Err, usage)
		fmt.Fprintf(s.Err, "%s: error: %s\n", tool, msg)
		return cli.ExitUsage
	}
	if fs.NArg() > 0 {
		return usageErr("unrecognized arguments: " + strings.Join(fs.Args(), " "))
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	var missing []string
	for _, n := range []string{"host", "output"} {
		if !set[n] {
			missing = append(missing, "--"+n)
		}
	}
	if len(missing) > 0 {
		return usageErr("the following arguments are required: " + strings.Join(missing, ", "))
	}

	fail := func(err error) int {
		var pe *pyError
		if errors.As(err, &pe) && pe.kind == "ValueError" {
			fmt.Fprintf(s.Err, "%s: ERROR — ValueError: %s\n", tool, pe.msg)
			return cli.ExitOperational
		}
		fmt.Fprintf(s.Err, "%s: ERROR — %s\n", tool, err.Error())
		return cli.ExitUsage
	}
	emit := func(doc map[string]any) error {
		b, err := jsonout.Indented(doc)
		if err != nil {
			return err
		}
		if err := writeEvidence(s, output, b); err != nil {
			return err
		}
		if asJSON {
			_, _ = s.Out.Write(b)
		}
		return nil
	}

	if !live {
		err := emit(map[string]any{
			"schema": "bacnet-evidence.v1", "status": "plan-only",
			"host": host, "port": jsonInt(port.v),
			"guard": "live probe requires --allow-live-probe; no frames sent",
			"plan": map[string]any{
				"protocol":  "ANSI/ASHRAE 135 BACnet/IP",
				"read_only": true,
				"probes":    []string{"unicast-who-is", "broadcast-who-is", "read-bdt", "read-fdt"},
				"note":      "broadcast-who-is requires --local-bcast",
			},
		})
		if err != nil {
			return fail(err)
		}
		fmt.Fprintln(s.Err, "DEGRADED: plan-only - live probe requires --allow-live-probe; no frames sent")
		return cli.ExitDegraded
	}

	l, err := openLinkFn(srcPort.v)
	if err != nil {
		return fail(err)
	}
	defer l.close()
	if err := checkTimeout(timeout.v); err != nil {
		return fail(err)
	}
	doc, code, err := probeLive(l, s.Clock, probeConfig{
		host: host, bbmd: bbmd, localBcast: localBcast, port: port.v,
		timeout: time.Duration(timeout.v * float64(time.Second)),
	})
	if err != nil {
		return fail(err)
	}
	if err := emit(doc); err != nil {
		return fail(err)
	}
	return code
}

// writeEvidence is _write: make the directory (existing is fine), then write the file in place.
func writeEvidence(s cli.Stdio, dir string, content []byte) error {
	abs := func(p string) string { return pyPathJoin(s.Cwd, p) }
	if e := pyMakedirs(dir, abs); e != nil {
		return e
	}
	path := pyJoin(dir, evidenceName)
	if err := os.WriteFile(abs(path), content, 0o666); err != nil {
		return &pyError{kind: "OSError", msg: fmt.Sprintf("cannot write %s: %s", path, osErrorText(err, path))}
	}
	return nil
}

// pyPathJoin joins an injected working directory and a relative path without cleaning it, so the names in
// error messages stay as the caller wrote them. An absolute path is returned unchanged.
func pyPathJoin(cwd, p string) string {
	if strings.HasPrefix(p, "/") || cwd == "" {
		return p
	}
	return strings.TrimRight(cwd, "/") + "/" + p
}
