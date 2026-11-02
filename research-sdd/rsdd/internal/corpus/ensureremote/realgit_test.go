package ensureremote

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The real git behind the injected runner: the history walk against genuine repositories (the argv of the walk is
// what the production code sends, so a wrong flag shows up here and not on a user's corpus). No network: gh is
// still the fake world's, and only git runs.

func needGit(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not on PATH")
	}
	return p
}

// gitEnv isolates git from the host's configuration.
func gitEnv(home string) []string {
	return []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t"}
}

type repo struct {
	t   *testing.T
	dir string
	env []string
}

func newRepo(t *testing.T) *repo {
	t.Helper()
	needGit(t)
	root := t.TempDir()
	r := &repo{t: t, dir: filepath.Join(root, "target"), env: gitEnv(root)}
	os.MkdirAll(r.dir, 0o755)
	r.git("init", "-q", "-b", "main")
	return r
}

func (r *repo) git(args ...string) string {
	r.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", r.dir}, args...)...)
	cmd.Env = r.env
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, out.String())
	}
	return out.String()
}

func (r *repo) commit(rel string, b []byte) {
	r.t.Helper()
	p := filepath.Join(r.dir, rel)
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, b, 0o644); err != nil {
		r.t.Fatal(err)
	}
	r.git("add", "--", rel)
	r.git("commit", "-q", "-m", "c "+rel)
}

// exec runs the command with real git and the fake gh/scanner; it returns the exit code and both streams.
func (r *repo) exec(t *testing.T, conf string, tracked ...string) (int, string, string, []string) {
	t.Helper()
	w := newWorld(t)
	w.target = r.dir
	if conf != "" {
		os.MkdirAll(filepath.Join(r.dir, ".research-sdd"), 0o755)
		os.WriteFile(filepath.Join(r.dir, allowRel), []byte(conf), 0o644)
		r.git("add", "--", ".research-sdd") // the working tree must be clean: the list is committed
		r.git("commit", "-q", "-m", "allow list")
	}
	var calls []string
	d := w.deps()
	d.run = func(c Cmd) Out {
		calls = append(calls, strings.Join(c.Argv, " "))
		if c.Argv[0] == "bash" {
			return Out{}
		}
		if len(c.Argv) > 3 && (c.Argv[3] == "ls-files" && c.Argv[4] == "-z") { // the tracked list is scripted: pathspecs are git's business
			var sb strings.Builder
			for _, p := range tracked {
				sb.WriteString(p + "\x00")
			}
			return Out{Stdout: []byte(sb.String())}
		}
		if len(c.Argv) > 3 && c.Argv[3] == "push" {
			return Out{}
		}
		return procRun(Cmd{Argv: c.Argv, Env: r.env, Timeout: c.Timeout})
	}
	s := w.stdio()
	s.Environ = func() []string { return r.env }
	rc := execute([]string{"--toolbelt", w.toolbelt, r.dir, "--yes"}, s, d)
	return rc, w.out(), w.err(), calls
}

func TestRealGitMergedAwayPrivateKeyIsFound(t *testing.T) { // case 42
	r := newRepo(t)
	r.commit("k.pem", fixture(t, "pempub"))
	r.git("checkout", "-q", "-b", "side")
	r.commit("k.pem", fixture(t, "pempriv"))
	r.git("checkout", "-q", "main")
	r.commit("other.txt", fixture(t, "licence"))
	r.git("merge", "-q", "-s", "ours", "side", "-m", "merge")
	r.git("branch", "-q", "-D", "side")
	rc, out, errs, _ := r.exec(t, "allow k.pem\n", "k.pem")
	if rc != 5 || strings.Contains(out, "ALLOWED: ") || !strings.Contains(errs, "k.pem") {
		t.Errorf("rc=%d out=%q err=%q", rc, out, errs)
	}
}

func TestRealGitOverwrittenAndAssumeUnchanged(t *testing.T) { // cases 39b and 39c
	r := newRepo(t)
	r.commit("k.der", fixture(t, "pkcs8"))
	r.commit("k.der", fixture(t, "cert"))
	if rc, _, _, _ := r.exec(t, "allow k.der\n", "k.der"); rc != 5 {
		t.Errorf("overwritten: rc=%d", rc)
	}
	r2 := newRepo(t)
	r2.commit("k.der", fixture(t, "pkcs8"))
	r2.git("update-index", "--assume-unchanged", "k.der")
	os.WriteFile(filepath.Join(r2.dir, "k.der"), fixture(t, "cert"), 0o644) // the worktree looks public
	if rc, _, _, _ := r2.exec(t, "allow k.der\n", "k.der"); rc != 5 {
		t.Errorf("assume-unchanged: rc=%d", rc)
	}
}

func TestRealGitAllPublicAndNoBlobAndNotARepo(t *testing.T) {
	r := newRepo(t)
	r.commit("k.der", fixture(t, "cert"))
	r.commit("k.der", fixture(t, "spki"))
	rc, out, _, _ := r.exec(t, "allow k.der\n", "k.der")
	if rc != 0 || !strings.Contains(out, "ALLOWED: k.der (.research-sdd/secret-files.conf:1 allow k.der; 2 blob(s) positively public)") {
		t.Errorf("rc=%d out=%q", rc, out)
	}
	// case 41: listed as tracked, no committed blob in the real history
	r = newRepo(t)
	r.commit("other.txt", fixture(t, "licence"))
	if rc, _, errs, _ := r.exec(t, "allow k.der\n", "k.der"); rc != 7 || !strings.Contains(errs, "no committed blob found for 'k.der'") {
		t.Errorf("no blob: rc=%d err=%q", rc, errs)
	}
}

func TestRealGitLiteralPathspecs(t *testing.T) {
	r := newRepo(t)
	r.commit("a.der", fixture(t, "pkcs8"))
	r.commit("b.der", fixture(t, "cert"))
	// a tracked path that looks like a glob must not pull in another file's history
	r.commit("[ab].der", fixture(t, "cert"))
	if rc, out, _, _ := r.exec(t, "allow [ab].der\nallow x\n", "[ab].der"); rc != 2 {
		t.Errorf("brackets are refused in the list: rc=%d out=%q", rc, out)
	}
	rc, out, _, _ := r.exec(t, "allow *.der\n", "[ab].der")
	if rc != 0 || !strings.Contains(out, "ALLOWED: [ab].der (.research-sdd/secret-files.conf:1 allow *.der; 1 blob(s) positively public)") {
		t.Errorf("literal pathspec: rc=%d out=%q", rc, out)
	}
}

// ---- case 40: real certificate and key artefacts, generated with the standard library ------------------------

func TestStdlibGeneratedArtefacts(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "t"}, NotBefore: time.Unix(0, 0), NotAfter: time.Unix(1<<31, 0)}
	certDER, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	p8, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	ec, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemOfDER := func(typ string, der []byte) []byte { return pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}) }
	for _, tt := range []struct {
		name string
		b    []byte
		want class
	}{
		{"cert.pem", pemOfDER("CERTIFICATE", certDER), classPublic},
		{"cert.der", certDER, classPublic},
		{"pub.pem", pemOfDER("PUBLIC KEY", pubDER), classPublic},
		{"pub.der", pubDER, classPublic},
		{"priv8.der", p8, classPrivate},
		{"priv8.pem", pemOfDER("PRIVATE KEY", p8), classPrivate},
		{"ec.key", pemOfDER("EC PRIVATE KEY", ec), classPrivate},
		{"ec.der", ec, classPrivate},
	} {
		if got := classify(tt.b); got != tt.want {
			t.Errorf("%s: %s, want %s", tt.name, classNames[got], classNames[tt.want])
		}
	}
}
