package pcap

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// The front half both commands share: refuse privileged execution, validate the capture and the output path,
// stage a private copy of the capture, find bwrap and the analyzers, build the sandbox and ask tshark for its
// version. The back half (which analyzers run, what the evidence holds) is each command's own.

// session is one command run in progress. stage is the directory this run created and still owns: it is
// removed on any failure and cleared once published.
type session struct {
	tool        string // error-message prefix
	s           cli.Stdio
	stage       string
	destination string
	source      fsx.Record
	staged      fsx.Record
	bwrap       fsx.Record
	tshark      fsx.Record
	capinfos    fsx.Record // only for the evidence command
	bwrapPath   string
	tsharkPath  string
	capinfosExe string
	run         *runner
	version     string
	manifestCLI string
}

// sessionOptions are what the two commands differ in.
type sessionOptions struct {
	needCapinfos bool
}

func (c *session) fail(err error) int {
	fmt.Fprintf(c.s.Err, "%s: %s\n", c.tool, errText(err))
	return cli.ExitUsage
}

// cleanup removes a stage that was never published.
func (c *session) cleanup() {
	if c.stage != "" {
		_ = os.RemoveAll(c.stage)
	}
}

// errText renders an error the way the legacy handlers printed it: a refusal as is, an OS error as Python's
// "[Errno N] strerror: 'file'".
func errText(err error) string {
	var ae *adapter.Error
	var he *helpers.Error
	var fe *fsx.Error
	switch {
	case errors.As(err, &ae):
		return ae.Msg
	case errors.As(err, &he):
		return he.Msg
	case errors.As(err, &fe):
		return fe.Error()
	}
	if msg, ok := pathError(err); ok {
		return msg
	}
	return err.Error()
}

func refusal(format string, a ...any) error { return &adapter.Error{Msg: fmt.Sprintf(format, a...)} }

// checkMagic opens the capture without following links and requires the libpcap or pcapng magic.
func checkMagic(cwd, input string) error {
	fd, _, err := fsx.OpenRO(absolute(cwd, input))
	if err != nil {
		if errors.Is(err, fsx.ErrNotRegular) {
			if fi, serr := os.Stat(absolute(cwd, input)); serr == nil && fi.IsDir() {
				return errors.New(osErrorText(syscall.EISDIR, ""))
			}
			return refusal("not a pcap/pcapng file (magic: )")
		}
		return refusal("not a pcap/pcapng file: %s", norm(input))
	}
	f := os.NewFile(uintptr(fd), input)
	defer f.Close()
	buf := make([]byte, 4)
	n, rerr := f.Read(buf)
	if rerr != nil && n == 0 && !errors.Is(rerr, os.ErrClosed) {
		if en, ok := errnoOf(rerr); ok && en != syscall.EAGAIN {
			return errors.New(osErrorText(en, ""))
		}
	}
	magic := buf[:n]
	for _, m := range helpers.PcapMagic {
		if bytes.Equal(magic, m) {
			return nil
		}
	}
	if bytes.Equal(magic, helpers.PcapngMagic) {
		return nil
	}
	return refusal("not a pcap/pcapng file (magic: %s)", hex.EncodeToString(magic))
}

// positive is the "caps must be positive" test on a parsed integer.
func positive(n *big.Int) bool { return n.Sign() > 0 }

// envLookup is os.environ.get(key): nil when the variable is not set at all.
func envLookup(s cli.Stdio, key string) *string {
	prefix := key + "="
	for _, kv := range s.Environ() {
		if len(kv) >= len(prefix) && kv[:len(prefix)] == prefix {
			v := kv[len(prefix):]
			return &v
		}
	}
	return nil
}

// open runs the shared front half. On error the caller prints it, calls cleanup and exits 2.
func (c *session) open(a parsedArgs, o sessionOptions) error {
	s := c.s
	if err := adapter.RefusePrivilegedExecution(currentCreds()); err != nil {
		return err
	}
	if !positive(a.num["timeout_seconds"]) || !positive(a.num["max_bytes"]) {
		return refusal("caps must be positive")
	}
	input, output := a.str["input"], a.str["output"]
	if err := checkMagic(s.Cwd, input); err != nil {
		return err
	}
	id, err := fsx.Identity(absolute(s.Cwd, input), fsx.NoLimit)
	if err != nil {
		return err
	}
	parentArg, name := parentAndName(output)
	parent, err := resolveStrict(s.Cwd, parentArg)
	if err != nil {
		return err
	}
	mountinfo, err := adapter.HostMountinfo()
	if err != nil {
		return err
	}
	if err := adapter.RequirePrivate(parent, mountinfo); err != nil {
		return err
	}
	c.destination = join(parent, name)
	if _, err := os.Lstat(c.destination); err == nil || id.Resolved == c.destination {
		return refusal("output must be a new non-colliding path")
	}

	stage := join(parent, "."+name+".stage")
	if err := os.Mkdir(stage, 0o700); err != nil {
		return err // a stage that already exists belongs to someone else and is left alone
	}
	c.stage = stage
	for _, d := range []string{"input", "engine"} {
		if err := os.Mkdir(filepath.Join(stage, d), 0o777); err != nil {
			return err
		}
	}
	if c.source, c.staged, err = fsx.StageFile(absolute(s.Cwd, input), filepath.Join(stage, "input", "capture.pcap"), "input/capture.pcap", 0o400, fsx.NoLimit); err != nil {
		return err
	}

	host := adapter.DefaultHost(os.Getuid(), s.Cwd)
	search := ""
	if p := envLookup(s, "PATH"); p != nil {
		search = *p
	}
	resolve := func(name, override string) (string, fsx.Record, error) {
		return adapter.Executable(host, name, envLookup(s, override), search)
	}
	bwrap, bwrapRec, err := resolve("bwrap", "RSDD_BWRAP")
	if err != nil {
		return err
	}
	c.bwrap, c.bwrapPath = bwrapRec, bwrap
	if o.needCapinfos {
		exe, rec, err := resolve("capinfos", "RSDD_CAPINFOS")
		if err != nil {
			return err
		}
		c.capinfos, c.capinfosExe = rec, exe
	}
	tshark, tsharkRec, err := resolve("tshark", "RSDD_TSHARK")
	if err != nil {
		return err
	}
	c.tshark, c.tsharkPath = tsharkRec, tshark
	prefix, err := adapter.Sandbox(host, bwrap, sandboxEnv, nil)
	if err != nil {
		return err
	}
	c.run = &runner{
		prefix: prefix, stage: stage,
		timeout:  clampSeconds(int64Clamp(a.num["timeout_seconds"])),
		maxBytes: clampInt(int64Clamp(a.num["max_bytes"])),
		now:      s.Clock,
	}
	c.version, err = c.run.probeVersion(tshark)
	return err
}

// int64Clamp is n limited to what an int64 holds (the caps are only ever compared against real sizes).
func int64Clamp(n *big.Int) int64 {
	if !n.IsInt64() {
		return math.MaxInt64
	}
	return n.Int64()
}
