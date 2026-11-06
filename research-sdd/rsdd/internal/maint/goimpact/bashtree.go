package goimpact

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// BashFile is one scanned bash file: its repo-relative path, text, the commands it reaches, and the exec
// forms it uses that no recovered command explains.
type BashFile struct {
	Path     string
	Text     string
	Calls    []Call
	Mentions []Mention
	Exempt   string // the reason in exemptBlind when the file's blind spots do not count, else ""
	Empty    bool   // empty-reach: mentions the binary, yet no call and no named shim reaches a command
}

const maxBashBytes = 8 << 20

// ScanBash enumerates the bash files under repo/research-sdd (outside the rsdd/ module: its scripts are frozen
// test fixtures) and reports, per file, the commands it reaches. known says whether a (group, name) pair is a
// recovered command. A directory that cannot be walked or a file that cannot be read is an error, never a
// silently shorter list.
func ScanBash(repo string, known func(Command) bool) ([]BashFile, error) {
	root := filepath.Join(repo, "research-sdd")
	skipModule := filepath.Join(repo, filepath.FromSlash(ModuleDir))
	var out []BashFile
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, werr error) error {
		if werr != nil {
			return werr
		}
		if d.IsDir() {
			if p == skipModule || d.Name() == ".git" || d.Name() == "node_modules" {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		b, ok, rerr := readBash(p, d.Name())
		if rerr != nil || !ok {
			return rerr
		}
		rel, _ := filepath.Rel(repo, p)
		f := BashFile{Path: filepath.ToSlash(rel), Text: string(b)}
		f.Calls, f.Mentions = scanText(f.Text, known)
		f.Exempt = exemptBlind[f.Path]
		out = append(out, f)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("cannot enumerate bash files under research-sdd: %w", err)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	markEmptyReach(out)
	return out, nil
}

// readBash returns the file when it is bash: a *.sh, or an extensionless file with a sh/bash shebang.
func readBash(p, name string) ([]byte, bool, error) {
	ext := filepath.Ext(name)
	if ext != "" && ext != ".sh" {
		return nil, false, nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, false, err
	}
	if len(b) > maxBashBytes {
		return nil, false, fmt.Errorf("%s is larger than %d bytes", p, maxBashBytes)
	}
	if ext == ".sh" {
		return b, true, nil
	}
	first, _, _ := bytes.Cut(b, []byte("\n"))
	return b, bytes.HasPrefix(first, []byte("#!")) && (bytes.Contains(first, []byte("bash")) || strings.HasSuffix(string(first), "sh")), nil
}
