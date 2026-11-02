package capa

// Running capa: the bounded sandbox run (adapter_core.run_bounded) and the host-side version probe.

import (
	"errors"
	"io/fs"
	"math/big"
	"os"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// maxOutputBytes caps the combined stdout+stderr of the capa run (its JSON carries verbose match trees).
const maxOutputBytes = 16 * 1024 * 1024

// versionTimeout bounds the host-side `capa --version` probe.
const versionTimeout = 15 * time.Second

// clampTimeout converts the wall-clock seconds to a Duration, saturating instead of overflowing.
func clampTimeout(seconds *big.Int) time.Duration {
	const maxSeconds = int64(1<<63-1) / int64(time.Second)
	if !seconds.IsInt64() || seconds.Int64() > maxSeconds {
		return time.Duration(maxSeconds) * time.Second
	}
	return time.Duration(seconds.Int64()) * time.Second
}

// isoformat is datetime.isoformat() for a UTC time with "+00:00" replaced by "Z".
func isoformat(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05") + "Z"
	}
	return t.Format("2006-01-02T15:04:05.000000") + "Z"
}

// spawnFailure renders a program that could not be started as Python's OSError text about argv[0].
func spawnFailure(argv0 string, err error) error {
	var se *proc.SpawnError
	if errors.As(err, &se) {
		err = se.Err
	}
	var errno syscall.Errno
	switch {
	case errors.As(err, &errno):
	case errors.Is(err, fs.ErrPermission):
		errno = syscall.EACCES
	default:
		errno = syscall.ENOENT
	}
	return &fail{osErrorText(errno, argv0)}
}

// runBounded runs cmd with dir as its working directory under a wall-clock timeout and a joint output cap
// and writes dir/engine/stdout.txt and dir/engine/stderr.txt. It returns the run record and the error list
// ("timeout", "output-cap", "analyzer-exit:<code>"). When a cap fired both files are truncated jointly to
// maxBytes, stdout first.
func runBounded(cmd []string, dir string, env []string, timeout *big.Int, maxBytes int, now func() time.Time) (map[string]any, []string, error) {
	outPath, errPath := dir+"/engine/stdout.txt", dir+"/engine/stderr.txt"
	for _, p := range []string{outPath, errPath} {
		f, err := os.Create(p)
		if err != nil {
			return nil, nil, &fail{osErrorText(err, p)}
		}
		_ = f.Close()
	}
	res, err := proc.Run(proc.Spec{Argv: cmd, Dir: dir, Env: env, Timeout: clampTimeout(timeout), MaxBytes: maxBytes, Now: now})
	if err != nil {
		var se *proc.SpawnError
		if errors.As(err, &se) {
			return nil, nil, spawnFailure(cmd[0], err)
		}
		return nil, nil, &fail{err.Error()}
	}
	stdout, stderr := res.Stdout, res.Stderr
	if res.Reason != "" {
		budget := maxBytes
		stdout = stdout[:min(len(stdout), budget)]
		budget -= len(stdout)
		stderr = stderr[:min(len(stderr), budget)]
	}
	if err := os.WriteFile(outPath, stdout, 0o666); err != nil {
		return nil, nil, &fail{osErrorText(err, outPath)}
	}
	if err := os.WriteFile(errPath, stderr, 0o666); err != nil {
		return nil, nil, &fail{osErrorText(err, errPath)}
	}
	record := map[string]any{
		"started_at": isoformat(res.Started), "ended_at": isoformat(res.Ended),
		"duration_ms": int(res.Duration / time.Millisecond), "exit_code": nil, "signal": nil,
	}
	if res.ReturnCode >= 0 {
		record["exit_code"] = res.ReturnCode
	} else {
		record["signal"] = -res.ReturnCode
	}
	return record, res.Errors(), nil
}

// pySplitFirstLine is str.splitlines()[0] of a non-empty string.
func pySplitFirstLine(s string) string {
	for i, r := range s {
		switch r {
		case '\n', '\r', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			return s[:i]
		}
	}
	return s
}

func pyStrip(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) })
}

// capaVersion is the host-side `capa --version` probe: the first line of stdout (else stderr), or
// "unknown" when the probe cannot run, times out or prints undecodable text.
func capaVersion(exe string, environ []string, cwd string, now func() time.Time) string {
	res, err := proc.Run(proc.Spec{Argv: []string{exe, "--version"}, Dir: cwd, Env: environ, Timeout: versionTimeout, MaxBytes: maxOutputBytes, Now: now})
	if err != nil || res.Reason == proc.ReasonTimeout {
		return "unknown"
	}
	if !utf8.Valid(res.Stdout) || !utf8.Valid(res.Stderr) {
		return "unknown"
	}
	text := func(b []byte) string { // universal newlines, then strip
		s := strings.ReplaceAll(string(b), "\r\n", "\n")
		return pyStrip(strings.ReplaceAll(s, "\r", "\n"))
	}
	line := text(res.Stdout)
	if line == "" {
		line = text(res.Stderr)
	}
	if line == "" {
		return "unknown"
	}
	return pySplitFirstLine(line)
}
