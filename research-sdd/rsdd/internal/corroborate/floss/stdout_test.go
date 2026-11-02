//go:build unix

package floss

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeFile(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestReadStdoutJSONRefusesALink(t *testing.T) {
	dir := t.TempDir()
	real := writeFile(t, dir, "real.txt", "{}")
	link := filepath.Join(dir, "stdout.txt")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	_, _, err := readStdoutJSON(link)
	if err == nil || err.Error() != "symlink detected at floss output path: "+link {
		t.Fatalf("err = %v", err)
	}
}

func TestReadStdoutJSONRefusesWhatIsNotARegularFile(t *testing.T) {
	dir := t.TempDir()
	_, _, err := readStdoutJSON(dir)
	if err == nil || err.Error() != "floss stdout is not a regular file: "+dir {
		t.Fatalf("directory: %v", err)
	}
	missing := filepath.Join(dir, "nope")
	_, _, err = readStdoutJSON(missing)
	if err == nil || err.Error() != "cannot stat floss stdout: "+missing {
		t.Fatalf("missing: %v", err)
	}
}

func TestReadStdoutJSONEmptyFileIsNoOutput(t *testing.T) {
	v, parseErr, err := readStdoutJSON(writeFile(t, t.TempDir(), "e.txt", ""))
	if v != nil || parseErr != "" || err != nil {
		t.Fatalf("got (%v, %q, %v)", v, parseErr, err)
	}
}

func TestReadStdoutJSONMalformedIsAnExplicitError(t *testing.T) {
	v, parseErr, err := readStdoutJSON(writeFile(t, t.TempDir(), "m.txt", "not json at all {{{{"))
	want := "malformed JSON in floss stdout: Expecting value: line 1 column 1 (char 0)"
	if v != nil || parseErr != want || err != nil {
		t.Fatalf("got (%v, %q, %v), want %q", v, parseErr, err, want)
	}
}

func TestReadStdoutJSONParsesAnObject(t *testing.T) {
	v, parseErr, err := readStdoutJSON(writeFile(t, t.TempDir(), "ok.txt", `{"strings":{}}`))
	m, ok := v.(map[string]any)
	if err != nil || parseErr != "" || !ok || len(m) != 1 {
		t.Fatalf("got (%v, %q, %v)", v, parseErr, err)
	}
}

func TestReadStdoutJSONDetectsAChangeWhileReading(t *testing.T) {
	p := writeFile(t, t.TempDir(), "t.txt", `{"a":1}`)
	afterRead = func() {
		afterRead = nil
		_ = os.WriteFile(p, []byte(`{"a":2}`), 0o644)
		_ = os.Chtimes(p, time.Now(), time.Now().Add(time.Hour))
	}
	t.Cleanup(func() { afterRead = nil })
	_, _, err := readStdoutJSON(p)
	if err == nil || err.Error() != "floss stdout changed while reading (TOCTOU)" {
		t.Fatalf("err = %v", err)
	}
}

func TestReadStdoutJSONUnsupportedEncodingIsRefusedNotMalformed(t *testing.T) {
	_, parseErr, err := readStdoutJSON(writeFile(t, t.TempDir(), "u.txt", "{\"a\":\"\xff\"}"))
	if parseErr != "" || err == nil {
		t.Fatalf("got (%q, %v)", parseErr, err)
	}
}
