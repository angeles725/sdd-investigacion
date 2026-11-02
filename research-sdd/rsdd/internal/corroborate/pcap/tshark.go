package pcap

import (
	"fmt"
	"math"
	"os"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The one way both commands run an analyzer: capinfos or tshark inside the network-denied Bubblewrap prefix,
// under a wall-clock timeout and a joint output cap, with the output kept in engine/stdout.txt and
// engine/stderr.txt of the stage (each run replaces the files, so the last run is the one the manifest hashes).

// sandboxEnv is the fixed environment of every analyzer, in the order the sandbox sets it.
var sandboxEnv = []adapter.EnvVar{
	{Key: "HOME", Value: "/tmp/rsdd/home"}, {Key: "LANG", Value: "C.UTF-8"}, {Key: "LC_ALL", Value: "C.UTF-8"},
	{Key: "PATH", Value: "/usr/bin:/usr/sbin:/bin:/sbin"}, {Key: "TMPDIR", Value: "/tmp/rsdd"}, {Key: "TZ", Value: "UTC"},
	{Key: "XDG_CACHE_HOME", Value: "/tmp/rsdd/cache"}, {Key: "XDG_CONFIG_HOME", Value: "/tmp/rsdd/config"},
	{Key: "XDG_DATA_HOME", Value: "/tmp/rsdd/data"},
}

// executablePath is the running binary, which serves the rlimit re-exec helper; a test replaces it.
var executablePath = os.Executable

// versionProbeTimeout bounds `tshark -v`.
const versionProbeTimeout = 10 * time.Second

// maxProbeBytes is far above any version banner; the legacy probe was unbounded.
const maxProbeBytes = 64 << 20

func environMap() map[string]string {
	m := make(map[string]string, len(sandboxEnv))
	for _, e := range sandboxEnv {
		m[e.Key] = e.Value
	}
	return m
}

func environList() []string {
	l := make([]string, len(sandboxEnv))
	for i, e := range sandboxEnv {
		l[i] = e.Key + "=" + e.Value
	}
	return l
}

// runner runs analyzers in one stage.
type runner struct {
	prefix   []string // the Bubblewrap argv, ending in "--"
	stage    string
	timeout  time.Duration
	maxBytes int
	now      func() time.Time
}

// toolRun is one analyzer run: the manifest's run record, the error list and the decoded stdout.
type toolRun struct {
	record map[string]any
	errors []string
	stdout string
}

// clampSeconds keeps a caller's huge timeout inside what a time.Duration holds.
func clampSeconds(n int64) time.Duration {
	const limit = 1 << 31
	if n > limit {
		n = limit
	}
	return time.Duration(n) * time.Second
}

func clampInt(n int64) int {
	if n > math.MaxInt64/2 {
		return math.MaxInt64 / 2
	}
	return int(n)
}

// isoZ is datetime.isoformat() of a UTC time with "+00:00" written as "Z": no fraction when it is zero.
func isoZ(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05") + "Z"
	}
	return t.Format("2006-01-02T15:04:05.000000") + "Z"
}

// run runs argv (the analyzer, after the sandbox prefix) and stores its output in the stage.
func (r *runner) run(analyzer ...string) (toolRun, error) {
	argv := append(append([]string(nil), r.prefix...), analyzer...)
	helper, err := executablePath()
	if err != nil {
		return toolRun{}, err
	}
	res, err := proc.Run(proc.Spec{
		Argv: argv, Dir: r.stage, Env: environList(),
		Timeout: r.timeout, MaxBytes: r.maxBytes, Now: r.now,
		// The legacy runner capped RLIMIT_FSIZE at the output cap; the helper binary lowers it in the child.
		Limits: []proc.Limit{{Resource: "fsize", Value: uint64(r.maxBytes)}}, Helper: helper,
	})
	if err != nil {
		return toolRun{}, runError(err)
	}
	for _, f := range []struct {
		name string
		body []byte
	}{{"stdout.txt", res.Stdout}, {"stderr.txt", res.Stderr}} {
		if err := os.WriteFile(r.stage+"/engine/"+f.name, f.body, 0o666); err != nil {
			return toolRun{}, err
		}
	}
	rec := map[string]any{
		"started_at": isoZ(res.Started), "ended_at": isoZ(res.Ended),
		"duration_ms": res.Duration.Milliseconds(), "exit_code": nil, "signal": nil,
	}
	if res.ReturnCode >= 0 {
		rec["exit_code"] = res.ReturnCode
	} else {
		rec["signal"] = -res.ReturnCode
	}
	return toolRun{record: rec, errors: res.Errors(), stdout: decodeReplace(res.Stdout)}, nil
}

// runError is what the legacy code raised for a failed launch: the OSError of a program that cannot be
// started, which the commands report as an operational refusal.
func runError(err error) error {
	if se, ok := err.(*proc.SpawnError); ok {
		if en, ok := errnoOf(se.Err); ok {
			return fmt.Errorf("%s", osErrorText(en, se.Path))
		}
	}
	return err
}

// probeVersion runs `tshark -v` in the sandbox and returns its first line, "unknown" when it printed nothing.
func (r *runner) probeVersion(tshark string) (string, error) {
	argv := append(append([]string(nil), r.prefix...), tshark, "-v")
	res, err := proc.Run(proc.Spec{
		Argv: argv, Dir: r.stage, Env: environList(), Timeout: versionProbeTimeout, MaxBytes: maxProbeBytes,
	})
	if err != nil {
		return "", runError(err)
	}
	if res.Reason == proc.ReasonTimeout {
		// subprocess.TimeoutExpired.__str__
		return "", fmt.Errorf("Command '%s' timed out after 10 seconds", pyListRepr(argv))
	}
	out := decodeReplace(res.Stdout)
	if pyStrip(out) == "" {
		return "unknown", nil
	}
	return pySplitlines(out)[0], nil
}
