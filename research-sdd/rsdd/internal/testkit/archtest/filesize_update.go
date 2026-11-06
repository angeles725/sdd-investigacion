package archtest

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// UpdateEnv is the environment variable that turns the real-tree test into an
// updater. Only the exact value "1" requests an update.
const UpdateEnv = "RSDD_MODULARITY_UPDATE"

// UpdateDebtIfRequested runs UpdateDebt only when request, the value of
// UpdateEnv read by the caller, is "1"; otherwise it reads and writes nothing.
func UpdateDebtIfRequested(request, root, debtPath string) (bool, error) {
	if request != "1" {
		return false, nil
	}
	return UpdateDebt(root, debtPath)
}

// UpdateDebt rewrites the debt file at debtPath so it only ever goes down: it
// lowers a recorded count to the current count when the file shrank and is
// still over SoftLimit, and deletes the line of a file at SoftLimit or less or
// that is not a production file. It never raises a count and never adds an
// entry; comments, blank lines and order are kept. It reports whether the file
// was rewritten, and writes nothing when nothing changes.
func UpdateDebt(root, debtPath string) (bool, error) {
	files, _, err := scanProduction(root)
	if err != nil {
		return false, err
	}
	data, err := os.ReadFile(debtPath)
	if err != nil {
		return false, fmt.Errorf("archtest: cannot read debt file: %w", err)
	}
	lines := strings.Split(string(data), "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		e, isEntry, problem := parseLine(line)
		if !isEntry || problem != "" {
			out = append(out, line)
			continue
		}
		n, isProd := files[e.Path]
		switch {
		case !isProd || n <= SoftLimit:
			// drop the line
		case n < e.Lines:
			out = append(out, fmt.Sprintf("%s %d %s %s", e.Path, n, e.Kind, e.Reason))
		default:
			out = append(out, line)
		}
	}
	next := []byte(strings.Join(out, "\n"))
	if bytes.Equal(next, data) {
		return false, nil
	}
	return true, writeAtomic(debtPath, next)
}

// writeAtomic replaces path via a temp file in the same directory, keeping
// the original mode.
func writeAtomic(path string, data []byte) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".modularity-debt-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	fail := func(e error) error {
		tmp.Close()
		os.Remove(name)
		return errors.Join(errors.New("archtest: cannot write debt file"), e)
	}
	if _, err := tmp.Write(data); err != nil {
		return fail(err)
	}
	if err := tmp.Chmod(info.Mode().Perm()); err != nil {
		return fail(err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}
