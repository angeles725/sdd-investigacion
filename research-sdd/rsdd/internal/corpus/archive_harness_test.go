package corpus

// Test harness of `rsdd corpus archive` (kit issue #2459).
//
// The command WRITES into its target, so no comparison ever touches a real corpus (kit CLAUDE.md section 8).
// Each case builds a fixture under a scratch root, snapshots the case directory (cp -a), then runs the frozen legacy
// script and the Go command one after the other on a fresh restored copy at the SAME path, and compares stdout, stderr,
// the exit code and the resulting tree (relative path, type, mode, bytes, symlink target) of the whole case directory.
// `.git` directories are listed but their contents are not compared (git rewrites index stat data).

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// archiveLegacyRunner and archiveLegacyInstall are set by archive_legacy_test.go, which is built only without the
// nodiff tag. Under -tags nodiff they stay nil: no case runs the frozen bash script and only the Go side is replayed
// against the goldens (archive_golden_nodiff_test.go).
var (
	archiveLegacyRunner  func(t testing.TB, tb, cwd string, args, env []string) (string, string, int)
	archiveLegacyInstall func(t testing.TB, tb string)
	// archiveTestBin is archiveRsddBin, set by archive_shim_test.go (also built only without nodiff): the binary every
	// run gets as RSDD_BIN. Under -tags nodiff it stays nil and archiveBaseEnv adds no RSDD_BIN.
	archiveTestBin func(t testing.TB) string
)

const archiveGoldenDir = "testdata/archive/golden"

// archiveKitRel is the research-sdd directory (absolute, via kitroot) despite the historical name.
var archiveKitRel = kitroot.Must()

var archiveClock = time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)

type archiveRes struct {
	out, err string
	code     int
	tree     string
}

// archiveCase is one fixture case. Expectations (want) replicate the grep/exit predicates of the retired bash suite
// case named by legacy; they are checked on BOTH sides.
type archiveCase struct {
	name   string
	legacy string // case numbers of the retired suite
	build  func(f *archiveFx) string
	args   func(f *archiveFx, d string) []string // default: the target only
	cwd    func(f *archiveFx, d string) string   // default: the scratch root
	env    func(f *archiveFx) []string           // extra env for both sides
	lenv   func(f *archiveFx) []string           // extra env for the legacy side only (a PATH stub the Go seam replaces)
	seam   func(f *archiveFx, h *archiveHooks)   // Go-side replacement of lenv / farm stubs
	farm   func(f *archiveFx, tb string)         // edits the toolbelt copy (stubs, removals)
	arm    func(f *archiveFx, d string)          // after each restore, before the run (chmod 000 ...)
	disarm func(f *archiveFx, d string)          // after the run, before the tree is read
	twice  bool                                  // run the command twice on the same tree, output concatenated
	skip   func(f *archiveFx) string             // non-empty: skip with this reason
	want   archiveWant
}

type archiveWant struct {
	rc                         int
	has, lacks, errHas, errNot []string
	files, noFiles             []string    // relative to the target
	fileHas                    [][2]string // {file relative to the target, regexp its content must match}
}

// archiveFx is the fixture builder (the mk* helpers of the retired suite).
type archiveFx struct {
	t    testing.TB
	root string // scratch root of the case run
	cdir string // case directory (snapshotted)
	tb   string // toolbelt copy: symlinks to the real toolbelt plus the frozen legacy script
}

func archiveReal(t testing.TB, rel string) string {
	t.Helper()
	p, err := filepath.Abs(rel)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func (f *archiveFx) path(rel string) string { return filepath.Join(f.cdir, rel) }

func (f *archiveFx) write(p, content string) {
	f.t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *archiveFx) read(p string) string {
	f.t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *archiveFx) mkdir(p string) {
	f.t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		f.t.Fatal(err)
	}
}

func (f *archiveFx) chtimes(p, day string) {
	f.t.Helper()
	tm, err := time.Parse("2006-01-02", day)
	if err != nil {
		f.t.Fatal(err)
	}
	if err := os.Chtimes(p, tm, tm); err != nil {
		f.t.Fatal(err)
	}
}

func (f *archiveFx) gitEnv(date string) []string {
	e := append(os.Environ(), "GIT_AUTHOR_NAME=tester", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=tester",
		"GIT_COMMITTER_EMAIL=t@example.com", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	if date != "" {
		e = append(e, "GIT_AUTHOR_DATE="+date, "GIT_COMMITTER_DATE="+date)
	}
	return e
}

// git runs `git -C d args` with a fixed identity; date pins author and committer dates.
func (f *archiveFx) gitAt(d, date string, args ...string) {
	f.t.Helper()
	c := exec.Command("git", append([]string{"-C", d}, args...)...)
	c.Env = f.gitEnv(date)
	if out, err := c.CombinedOutput(); err != nil {
		f.t.Fatalf("git %v: %v: %s", args, err, out)
	}
}

func (f *archiveFx) git(d string, args ...string) {
	f.t.Helper()
	f.gitAt(d, "2026-06-01T00:00:00", args...)
}

func (f *archiveFx) gitInit(d string) {
	f.t.Helper()
	f.mkdir(d)
	f.git(d, "init", "-q", "-b", "main")
	f.git(d, "config", "user.email", "t@example.com")
	f.git(d, "config", "user.name", "tester")
}

func (f *archiveFx) commit(d, date, msg string) {
	f.t.Helper()
	f.gitAt(d, date, "commit", "-q", "-m", msg)
}

// sync is `research-sdd-status.sh <d> --sync-state [--focus f]`, the real sibling, to seed the state envelope.
func (f *archiveFx) sync(d string, focus ...string) {
	f.t.Helper()
	args := []string{filepath.Join(f.tb, "research-sdd-status.sh"), d, "--sync-state"}
	if len(focus) > 0 {
		args = append(args, "--focus", focus[0])
	}
	c := exec.Command("bash", args...)
	c.Env = append(os.Environ(), "LC_ALL=C", "TZ=UTC")
	_ = c.Run() // the retired suite discarded the status too (>/dev/null 2>&1)
}

func (f *archiveFx) replaceIn(p, old, new string) {
	f.t.Helper()
	f.write(p, strings.ReplaceAll(f.read(p), old, new))
}

// setUF is the awk rewrite of every `undocumented_findings:` line.
func (f *archiveFx) setUF(p string, n int) {
	f.t.Helper()
	lines := strings.Split(f.read(p), "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "undocumented_findings:") {
			lines[i] = fmt.Sprintf("undocumented_findings: %d", n)
		}
	}
	f.write(p, strings.Join(lines, "\n"))
}

func (f *archiveFx) dropUF(p string) {
	f.t.Helper()
	var keep []string
	for _, l := range strings.Split(f.read(p), "\n") {
		if !strings.HasPrefix(l, "undocumented_findings:") {
			keep = append(keep, l)
		}
	}
	f.write(p, strings.Join(keep, "\n"))
}

func (f *archiveFx) closeRetro(c string) {
	f.t.Helper()
	p := filepath.Join(c, "retros", "2099-01-01-close.md")
	f.write(p, "<!-- review-status: pending -->\n# Close retro — test fixture\n")
	f.chtimes(p, "2099-01-01")
}

// ---- toolbelt copy -------------------------------------------------------------------------------------------

// archiveFarm builds <root>/tb: a symlink to every real toolbelt entry (so each sibling resolves its own libraries),
// the frozen legacy script as a real file, and <root>/templates etc. as symlinks (the kit generator lives at
// ../templates). Edits are applied by the case's farm hook; a lib/ edit replaces the lib symlink by a symlink farm.
func archiveFarm(t testing.TB, root string) string {
	t.Helper()
	tb := filepath.Join(root, "tb")
	if err := os.MkdirAll(tb, 0o755); err != nil {
		t.Fatal(err)
	}
	real := archiveReal(t, archiveKitRel+"/toolbelt")
	kit := archiveReal(t, archiveKitRel)
	ents, err := os.ReadDir(real)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if e.Name() == "research-sdd-archive.sh" {
			continue
		}
		if err := os.Symlink(filepath.Join(real, e.Name()), filepath.Join(tb, e.Name())); err != nil {
			t.Fatal(err)
		}
	}
	if archiveLegacyInstall != nil {
		archiveLegacyInstall(t, tb)
	}
	kents, err := os.ReadDir(kit)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range kents {
		switch e.Name() {
		case "toolbelt", "rsdd", "bin":
			continue
		}
		if err := os.Symlink(filepath.Join(kit, e.Name()), filepath.Join(root, e.Name())); err != nil {
			t.Fatal(err)
		}
	}
	return tb
}

// archiveFarmLib turns tb/lib into a real directory of symlinks so one library file can be replaced.
func archiveFarmLib(t testing.TB, tb string) {
	t.Helper()
	lib := filepath.Join(tb, "lib")
	target, err := os.Readlink(lib)
	if err != nil {
		return // already a directory
	}
	if err := os.Remove(lib); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(lib, 0o755); err != nil {
		t.Fatal(err)
	}
	ents, _ := os.ReadDir(target)
	for _, e := range ents {
		if err := os.Symlink(filepath.Join(target, e.Name()), filepath.Join(lib, e.Name())); err != nil {
			t.Fatal(err)
		}
	}
}

// archiveFarmStub replaces tb/<name> by an executable script.
func archiveFarmStub(t testing.TB, tb, name, content string) {
	t.Helper()
	p := filepath.Join(tb, name)
	_ = os.Remove(p)
	if err := os.WriteFile(p, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}

// ---- running -----------------------------------------------------------------------------------------------

// archiveBaseEnv carries RSDD_BIN: the gates the archive runs (verify-state.sh and the other rsdd shims) must use the
// test's binary, never build one into the kit's bin/ (CI has none, and a case that stubs git makes that build fail,
// so only the Go side reported "verify-state.sh did not run"; kit issue #2477).
func archiveBaseEnv(t testing.TB, root string) []string {
	t.Helper()
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + filepath.Join(root, "home"), "LC_ALL=C", "TZ=UTC",
		"GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "TMPDIR=" + filepath.Join(root, "tmp")}
	if archiveTestBin != nil {
		env = append(env, "RSDD_BIN="+archiveTestBin(t))
	} else if bin := os.Getenv("RSDD_BIN"); bin != "" {
		// Under -tags nodiff (make teeth, run-all) nothing builds a binary here; the caller's RSDD_BIN is the one.
		env = append(env, "RSDD_BIN="+bin)
	}
	return env
}

func archiveEnvLookup(env []string) func(string) string {
	m := map[string]string{}
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[k] = v
		}
	}
	return func(k string) string { return m[k] }
}

func archiveDubiousSkip(f *archiveFx) string {
	d := filepath.Join(f.root, "dubious-probe")
	f.gitInit(d)
	c := exec.Command("git", "-C", d, "rev-parse", "--show-toplevel")
	c.Env = append(os.Environ(), "GIT_TEST_ASSUME_DIFFERENT_OWNER=1")
	out, err := c.CombinedOutput()
	if err == nil || !strings.Contains(strings.ToLower(string(out)), "dubious ownership") {
		return "GIT_TEST_ASSUME_DIFFERENT_OWNER=1 does not reproduce dubious ownership on this host"
	}
	return ""
}

func archiveRunGo(tb, cwd string, args, env []string, hook func(*archiveHooks)) (string, string, int) {
	var o, e bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: archiveEnvLookup(env),
		Environ: func() []string { return append([]string(nil), env...) },
		Clock:   func() time.Time { return archiveClock }, Cwd: cwd}
	code := archiveRunWith(append([]string{"--toolbelt", tb}, args...), s, hook)
	return o.String(), e.String(), code
}

// archiveTree lists the tree under dir: one line per entry, sorted, "<type><mode> <sha256|-> <rel> [-> target]".
func archiveTree(t testing.TB, dir string) string {
	t.Helper()
	var lines []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == dir {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		info, ierr := os.Lstat(p)
		if ierr != nil {
			return ierr
		}
		mode := info.Mode()
		switch {
		case mode&os.ModeSymlink != 0:
			tg, _ := os.Readlink(p)
			lines = append(lines, fmt.Sprintf("l%04o - %s -> %s", mode.Perm(), rel, tg))
		case mode.IsDir():
			lines = append(lines, fmt.Sprintf("d%04o - %s", mode.Perm(), rel))
			if d.Name() == ".git" {
				return fs.SkipDir
			}
		default:
			f, oerr := os.Open(p)
			if oerr != nil {
				return oerr
			}
			h := sha256.New()
			_, cerr := io.Copy(h, f)
			f.Close()
			if cerr != nil {
				return cerr
			}
			lines = append(lines, fmt.Sprintf("f%04o %s %s", mode.Perm(), hex.EncodeToString(h.Sum(nil))[:16], rel))
		}
		return nil
	})
	if err != nil {
		t.Fatalf("tree %s: %v", dir, err)
	}
	sort.Strings(lines)
	return strings.Join(lines, "\n") + "\n"
}

func archiveCopy(t testing.TB, src, dst string) {
	t.Helper()
	if out, err := exec.Command("cp", "-a", "--", src, dst).CombinedOutput(); err != nil {
		t.Fatalf("cp -a: %v: %s", err, out)
	}
}

func archiveWipe(t testing.TB, dir string) {
	t.Helper()
	_ = exec.Command("chmod", "-R", "u+rwX", dir).Run()
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
}

// archiveRunCase builds the fixture once and returns the legacy result (nil when legacy is off) and the Go result.
func archiveRunCase(t *testing.T, c archiveCase, withLegacy bool) (leg *archiveRes, gor archiveRes, f *archiveFx, d string) {
	t.Helper()
	// a fixed-length name: git messages are cut at 160 bytes, so the root path length must not vary between runs
	var rnd [4]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(os.TempDir(), "arch-"+hex.EncodeToString(rnd[:]))
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { archiveWipe(t, root) })
	for _, d := range []string{"home", "tmp", "work"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f = &archiveFx{t: t, root: root, cdir: filepath.Join(root, "work", "case"), tb: archiveFarm(t, root)}
	if c.skip != nil {
		if why := c.skip(f); why != "" {
			t.Skip(why)
		}
	}
	if err := os.MkdirAll(f.cdir, 0o755); err != nil {
		t.Fatal(err)
	}
	d = c.build(f)
	if c.farm != nil {
		c.farm(f, f.tb)
	}
	pristine := filepath.Join(root, "pristine")
	archiveCopy(t, f.cdir, pristine)
	args := []string{d}
	if c.args != nil {
		args = c.args(f, d)
	}
	cwd := root
	if c.cwd != nil {
		cwd = c.cwd(f, d)
	}
	env := archiveBaseEnv(t, root)
	if c.env != nil {
		env = append(env, c.env(f)...)
	}
	side := func(run func(env []string) (string, string, int)) archiveRes {
		archiveWipe(t, f.cdir)
		archiveCopy(t, pristine, f.cdir)
		if c.arm != nil {
			c.arm(f, d)
		}
		var res archiveRes
		runs := 1
		if c.twice {
			runs = 2
		}
		for i := 0; i < runs; i++ {
			o, e, code := run(env)
			res.out += o
			res.err += e
			res.code = code
		}
		if c.disarm != nil {
			c.disarm(f, d)
		}
		res.tree = archiveTree(t, f.cdir)
		return res
	}
	if withLegacy {
		if archiveLegacyRunner == nil {
			t.Fatal("legacy side requested in a build without the frozen oracle (-tags nodiff)")
		}
		lenv := env
		if c.lenv != nil {
			lenv = append(append([]string(nil), env...), c.lenv(f)...)
		}
		r := side(func([]string) (string, string, int) { return archiveLegacyRunner(t, f.tb, cwd, args, lenv) })
		leg = &r
	}
	var hook func(*archiveHooks)
	if c.seam != nil {
		hook = func(h *archiveHooks) { c.seam(f, h) }
	}
	gor = side(func(e []string) (string, string, int) { return archiveRunGo(f.tb, cwd, args, e, hook) })
	return leg, gor, f, d
}

// archiveRootCut matches a root path that git cut short in a message (messages are limited to 160 bytes).
var archiveRootCut = regexp.MustCompile(`/arch-[0-9a-f]{0,8}\b`)

// archiveGitPathTail matches the rest of a git fatal message that quotes a path under the test root.
// git cuts messages at 160 bytes, so where the cut lands depends on the length of $TMPDIR: a golden
// cannot pin that tail. The legacy-vs-Go comparison in the same run still compares it byte for byte.
var archiveGitPathTail = regexp.MustCompile(`(fatal: (?:detected dubious ownership in repository at '|bad config line [0-9]+ in file ))[^\n]*`)

// archiveCommitList matches a line that lists commits ("commit(s) <sha>..."), and archiveShortSHA a short sha on it.
// Cases that commit without a pinned date get a new sha on every run, so a golden cannot pin it (it passed only in
// the run that recorded it and failed on CI). The legacy-vs-Go comparison in the same run still compares it byte for byte.
var (
	archiveCommitList = regexp.MustCompile(`(?m)^.*commit\(s\) .*$`)
	archiveShortSHA   = regexp.MustCompile(`\b[0-9a-f]*[0-9][0-9a-f]*\b`)
)

func archiveScrubSHAs(line string) string {
	return archiveShortSHA.ReplaceAllStringFunc(line, func(tok string) string {
		if len(tok) < 7 || len(tok) > 40 {
			return tok
		}
		return "@SHA@"
	})
}

func archiveNorm(s, root string) string {
	s = strings.ReplaceAll(s, root, "@ROOT@")
	s = archiveCommitList.ReplaceAllStringFunc(s, archiveScrubSHAs)
	s = archiveGitPathTail.ReplaceAllString(s, "${1}@PATH-CUT@")
	// a root cut at 160 bytes keeps only part of its random suffix: collapse what is left of it too
	return archiveRootCut.ReplaceAllString(s, "/arch-@CUT@")
}
