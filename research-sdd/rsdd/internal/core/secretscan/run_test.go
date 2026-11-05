package secretscan

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// listBytes is the --files-from list of a case: NUL-terminated absolute paths of the entries.
func (w *world) listBytes() []byte {
	if w.c.rawList != nil {
		return []byte(strings.ReplaceAll(*w.c.rawList, "{{T}}", w.phys()))
	}
	var b bytes.Buffer
	for _, e := range w.c.list {
		if rest, ok := strings.CutPrefix(e, "!"); ok {
			b.WriteString(rest)
		} else {
			b.WriteString(w.phys() + "/" + e)
		}
		b.WriteByte(0)
	}
	return b.Bytes()
}

// phys is the physical path of the corpus.
func (w *world) phys() string {
	p, err := filepath.EvalSymlinks(w.corpus)
	if err != nil {
		return w.corpus
	}
	return p
}

// target is the target argument as the caller writes it.
func (w *world) target() string {
	if w.c.target != "" {
		return w.c.target
	}
	return w.corpus
}

// listArg is the --files-from operand: a list file, "-" for stdin, or a deliberately bad path.
func (w *world) listArg() string {
	switch {
	case w.c.stdin:
		return "-"
	case w.c.listFile == "absent":
		return filepath.Join(w.scratch, "no-such-list")
	case w.c.listFile == "dir":
		return w.scratch
	}
	p := filepath.Join(w.scratch, "list.bin")
	if err := os.WriteFile(p, w.listBytes(), 0o644); err != nil {
		w.t.Fatal(err)
	}
	return p
}

// argv is the legacy command line of the case.
func (w *world) argv() []string {
	switch w.c.mode {
	case "ff":
		return []string{"--files-from", w.listArg(), w.target()}
	case "committed":
		return []string{"--committed", w.target()}
	}
	return []string{w.target()}
}

// request is the Go engine's equivalent of argv.
func (w *world) request(stdin *bytes.Reader) Request {
	r := Request{Target: w.target(), Cwd: w.scratch, Env: w.env, KitDir: w.scratch}
	switch w.c.mode {
	case "ff":
		r.FilesFrom = w.listArg()
		if w.c.stdin {
			r.Stdin = stdin
		}
	case "committed":
		r.Committed = true
	}
	return r
}

func (w *world) runGo(t testing.TB) obs {
	t.Helper()
	var out, errb bytes.Buffer
	stdin := bytes.NewReader(nil)
	if w.c.stdin {
		stdin = bytes.NewReader(w.listBytes())
	}
	req := w.request(stdin)
	code := Run(req, &out, &errb)
	return obs{w.norm(out.String()), w.norm(errb.String()), code}
}

func ptr(s string) *string { return &s }
