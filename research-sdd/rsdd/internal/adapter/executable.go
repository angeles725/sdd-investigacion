package adapter

import (
	"os"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// Executable is adapter_core.executable: resolve a trusted executable chosen
// by PATH (search) and an optional configured override. configured nil is
// Python's None; an empty string selects the PATH result too. The result is the
// fd-resolved path and its identity record.
func Executable(h Host, name string, configured *string, search string) (string, fsx.Record, error) {
	selected, ok := which(name, search, h.Cwd)
	if !ok {
		return "", fsx.Record{}, &Error{Msg: "PATH-selected " + name + " is missing"}
	}
	pick, shown := selected, "None"
	if configured != nil {
		shown = *configured
		if *configured != "" {
			pick = *configured
		}
	}
	candidate, err := resolveStrict(pick, h.Cwd)
	if err != nil {
		return "", fsx.Record{}, &Error{Msg: "configured " + name + " path does not exist: " + shown, Err: err}
	}
	selectedPath, err := resolveStrict(selected, h.Cwd)
	if err != nil {
		return "", fsx.Record{}, err
	}
	fi, serr := os.Stat(candidate)
	isFile := serr == nil && fi.Mode().IsRegular()
	if !isFile || syscall.Access(candidate, 0x1) != nil {
		return "", fsx.Record{}, mismatch(name)
	}
	a, err := os.Stat(candidate)
	if err != nil {
		return "", fsx.Record{}, err
	}
	b, err := os.Stat(selectedPath)
	if err != nil {
		return "", fsx.Record{}, err
	}
	if !os.SameFile(a, b) {
		return "", fsx.Record{}, mismatch(name)
	}
	id, err := fsx.Identity(candidate, fsx.NoLimit)
	if err != nil {
		return "", fsx.Record{}, wrapFsx(err)
	}
	return id.Resolved, fsx.Record{Path: id.Resolved, Size: id.Size, SHA256: id.SHA256}, nil
}

func mismatch(name string) error {
	return &Error{Msg: "configured " + name + " does not match PATH-selected executable"}
}
