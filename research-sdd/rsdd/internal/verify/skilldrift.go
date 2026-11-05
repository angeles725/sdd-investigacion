package verify

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Port of research-sdd/toolbelt/verify-skill-drift.sh and verify-skill-drift-hook.sh: is a deployed
// SKILL.md the kit's source, byte for byte?
//
//	rsdd verify skill-drift [--all | --harness <h>] [--home <dir>] [--profile <name>]
//	rsdd verify skill-drift --hook [<toolbelt-dir>]        (the SessionStart hook, skilldrifthook.go)
//
// The shims pass the kit themselves, as the first argument pair: `--kit <kit-root>` for the check and `--hook
// <toolbelt-dir>` for the hook. Both are internal: given anywhere else, `--kit` and `--hook` are unknown
// arguments, exactly as for the script. Without `--kit` the kit is resolved like the portable hooks do.
//
// Exit codes, stdout (always empty, except --help) and every stderr line are the script's. Declared
// differences, each pinned by a test:
//
//   - The adapter table (install/adapters.sh: which harnesses exist, their config roots, skill sources and
//     default profiles, the pi GENTLE_PI_AGENT_HOME / PI_CODING_AGENT_DIR override) is compiled in, not sourced
//     from the kit's adapters.sh, which stays bash for the installer. A test compares the table with the real
//     file. A kit fixture with its own adapters.sh (two skill sources, or no profile support) no longer changes
//     the behaviour, and adapters.sh is only checked for existence ("install dir not found" / "adapters.sh not
//     found" keep their exit 2).
//   - --help prints a copy of the script header (skillDriftHelp), pinned against the frozen script.
//   - render-profile.sh is still the bash renderer, run through core/proc with a 60 s bound the script lacks.
//     A renderer that cannot be started (not executable) is reported with Go's error text instead of the
//     shell's "Permission denied" text. Its stdout and stderr are joined stdout first, not interleaved.
//   - A throwaway render dir is created under $TMPDIR (else /tmp) like mktemp -d, and removed on every exit path.
//
// Kept on purpose, although they read as defects: a pi override that is not an absolute path makes every
// rsdd_field call of the script fail, so --all counts pi as absent (after two rsdd_field messages) instead of
// could-not-run. Reported in issue #2365's port notes; fixing it is a behaviour change for its own unit.

// skillHarness is one row of the adapter table, the part verify-skill-drift reads.
type skillHarness struct {
	name           string
	configRel      string // config root, relative to the home
	skillSrcRelkit string
	defaultProfile string
}

// skillHarnesses is RESEARCH_SDD_HARNESSES in registration order, with the _RSDD_* tables of adapters.sh.
var skillHarnesses = []skillHarness{
	{"claude", ".claude", "skills/research-sdd/SKILL.md", "claude"},
	{"pi", ".pi/agent", "skills/research-sdd/SKILL.md", "general"},
	{"gentle-shell", ".gentle-shell/agent", "skills/research-sdd/SKILL.md", "general"},
}

func findSkillHarness(name string) (skillHarness, bool) {
	for _, h := range skillHarnesses {
		if h.name == name {
			return h, true
		}
	}
	return skillHarness{}, false
}

const (
	// renderTimeout bounds one render-profile.sh run; the script has no bound at all.
	renderTimeout  = 60 * time.Second
	renderMaxBytes = 1 << 20
	skillDriftName = "verify-skill-drift"
)

var reProfileName = regexp.MustCompile(`^[a-z0-9_-]+$`)

// RunSkillDrift is the `verify skill-drift` command (and, with a leading --hook, its SessionStart hook).
func RunSkillDrift(args []string, s cli.Stdio) int {
	if len(args) > 0 && args[0] == "--hook" {
		return runSkillDriftHook(args[1:], s)
	}
	kitRoot := ""
	if len(args) > 0 && args[0] == "--kit" {
		if len(args) < 2 || args[1] == "" {
			fmt.Fprintf(s.Err, "%s: --kit requires a non-empty value\n", skillDriftName)
			return cli.ExitUsage
		}
		kitRoot, args = args[1], args[2:]
	}
	root, ok := resolveSkillDriftKit(kitRoot, s)
	if !ok {
		return cli.ExitUsage
	}
	return skillDriftCheck(root, args, s, s.Out, s.Err)
}

// resolveSkillDriftKit is the kit root: the flag, else the portable-hook resolution, made absolute.
func resolveSkillDriftKit(flag string, s cli.Stdio) (string, bool) {
	root := flag
	if root == "" {
		p, warns, err := kit.ResolveKitScript("toolbelt/verify-skill-drift.sh", s.Env)
		for _, w := range warns {
			fmt.Fprintln(s.Err, w)
		}
		if err != nil {
			fmt.Fprintf(s.Err, "%s: ERROR: cannot resolve the kit: %v\n", skillDriftName, err)
			return "", false
		}
		root = filepath.Dir(filepath.Dir(p))
	}
	if !filepath.IsAbs(root) {
		root = filepath.Join(s.Cwd, root)
	}
	return root, true
}

// physicalDir is `cd -P p && pwd -P`: the symlink-free path of an existing directory. p must be absolute (every
// caller joins a relative path to Stdio.Cwd first), so the result is absolute without consulting the process cwd.
func physicalDir(p string) (string, bool) {
	r, err := filepath.EvalSymlinks(p)
	if err != nil || !isDirOS(r) {
		return "", false
	}
	return r, true
}

type skillDrift struct {
	s       cli.Stdio
	errw    io.Writer
	kit     string // physical kit root: the parent of the physical install dir
	tmpDirs []string
}

func (d *skillDrift) eprintf(format string, a ...any) { fmt.Fprintf(d.errw, format, a...) }

// configRoot is rsdd_field <h> config_root <home>: <home>/<rel>, except for pi, where (only when home is the
// invoking user's own $HOME) GENTLE_PI_AGENT_HOME, then PI_CODING_AGENT_DIR, replaces it. Every rsdd_field
// field passes through this check first, so an invalid override fails them all; it prints its message
// unless quiet (the script silences it in single-harness mode: `>/dev/null 2>&1`).
func (d *skillDrift) configRoot(h skillHarness, home string, quiet bool) (string, bool) {
	root := home + "/" + h.configRel
	if h.name != "pi" || home != d.s.Env("HOME") {
		return root, true
	}
	src, override := "", ""
	if v := d.s.Env("GENTLE_PI_AGENT_HOME"); v != "" {
		src, override = "GENTLE_PI_AGENT_HOME", v
	} else if v := d.s.Env("PI_CODING_AGENT_DIR"); v != "" {
		src, override = "PI_CODING_AGENT_DIR", v
	}
	if src == "" {
		return root, true
	}
	trimmed := strings.TrimRight(override, "/")
	if len(trimmed) >= 2 && trimmed[0] == '/' {
		return trimmed, true
	}
	if !quiet {
		d.eprintf("rsdd_field: %s must be an absolute path other than / (got '%s')\n", src, override)
	}
	return "", false
}

// skillPath is rsdd_field <h> skill_path <home> ("" after a failed rsdd_field).
func (d *skillDrift) skillPath(h skillHarness, home string) string {
	root, ok := d.configRoot(h, home, false)
	if !ok {
		return ""
	}
	return root + "/skills/research-sdd/SKILL.md"
}

// skillSrcRelkit is rsdd_field <h> skill_src_relkit <home> ("" after a failed rsdd_field).
func (d *skillDrift) skillSrcRelkit(h skillHarness, home string) string {
	if _, ok := d.configRoot(h, home, false); !ok {
		return ""
	}
	return h.skillSrcRelkit
}

// resolveProfile is rsdd_resolve_profile: flag, else $RESEARCH_SDD_PROFILE, else the harness default; the
// "<profile>:<source>" pair is cut at its first colon, as `${pair%%:*}` does.
func (d *skillDrift) resolveProfile(h skillHarness, flag string) string {
	pair := ""
	switch {
	case flag != "":
		pair = flag + ":flag"
	case d.s.Env("RESEARCH_SDD_PROFILE") != "":
		pair = d.s.Env("RESEARCH_SDD_PROFILE") + ":env"
	default:
		def := ""
		if _, ok := d.configRoot(h, d.s.Env("HOME"), false); ok { // rsdd_field <h> prompt_profile, home defaulting to $HOME
			def = h.defaultProfile
		}
		pair = def + ":default"
	}
	profile, _, _ := strings.Cut(pair, ":")
	return profile
}

// validProfile is rsdd_valid_profile: "claude", or a safe name with a profiles/<name>.slots.md in the kit.
func (d *skillDrift) validProfile(profile string) bool {
	if profile == "claude" {
		return true
	}
	return reProfileName.MatchString(profile) && isFileOS(filepath.Join(d.kit, "profiles", profile+".slots.md"))
}

// mktemp is `mktemp -d`: a fresh directory under $TMPDIR (else /tmp). Like mktemp, a failure names its cause on
// stderr, so a could-not-run that follows it is never unexplained (the wording is Go's, not mktemp's).
func (d *skillDrift) mktemp() (string, error) {
	base := d.s.Env("TMPDIR")
	if base == "" {
		base = "/tmp"
	}
	t, err := os.MkdirTemp(base, "tmp.")
	if err != nil {
		d.eprintf("%s: cannot create a throwaway render dir: %v\n", skillDriftName, err)
	}
	return t, err
}

func (d *skillDrift) cleanup() {
	for _, t := range d.tmpDirs {
		if t != "" {
			os.RemoveAll(t) //nolint:errcheck
		}
	}
}

// render is `render-profile.sh <profile> <outdir> 2>&1`: ok=false carries the joined output (trailing newlines
// cut, as `$(...)` does).
func (d *skillDrift) render(profile, outdir string) (msg string, ok bool) {
	environ := d.s.Environment()
	res, err := proc.Run(proc.Spec{
		Argv: []string{filepath.Join(d.kit, "toolbelt", "render-profile.sh"), profile, outdir},
		Dir:  d.s.Cwd, Env: environ, Timeout: renderTimeout, MaxBytes: renderMaxBytes, Now: d.s.Clock,
	})
	if err != nil {
		return strings.TrimRight(err.Error(), "\n"), false
	}
	text := strings.TrimRight(string(res.Stdout)+string(res.Stderr), "\n")
	if res.Reason != "" {
		return text, false
	}
	return text, res.ReturnCode == 0
}

// resolveSrc is _vsd_resolve_src: the file to compare the deployed skill against. rc 0 ok, 2 could not run,
// 3 unknown profile. tmp is the render dir to remove (empty when there is none).
func (d *skillDrift) resolveSrc(h skillHarness, home, srcRel, flag string) (src, tmp, profile string, rc int) {
	profile = d.resolveProfile(h, flag)
	if !d.validProfile(profile) {
		return "", "", profile, 3
	}
	if profile == "claude" {
		return filepath.Join(d.kit, srcRel), "", profile, 0
	}
	t, err := d.mktemp()
	if err != nil {
		return "", "", profile, 2
	}
	if msg, ok := d.render(profile, t); !ok {
		d.eprintf("%s: render-profile.sh failed for profile \"%s\": %s\n", skillDriftName, profile, msg)
		os.RemoveAll(t) //nolint:errcheck
		return "", "", profile, 2
	}
	return filepath.Join(t, srcRel), t, profile, 0
}

// sameBytes is `cmp -s a b`: both readable and identical.
func sameBytes(a, b string) bool {
	x, err := os.ReadFile(a)
	if err != nil {
		return false
	}
	y, err := os.ReadFile(b)
	return err == nil && bytes.Equal(x, y)
}

func existsOS(p string) bool { _, err := os.Stat(p); return err == nil }

func isSymlinkOS(p string) bool {
	st, err := os.Lstat(p)
	return err == nil && st.Mode()&os.ModeSymlink != 0
}

// renderState is _vsd_check_render_completeness: whether the persisted render dir of a non-claude profile
// (<configRoot>/research-sdd/profile/<profile>) is still there and intact: ok, missing, diverged (one of its
// three rendered files differs from a fresh render), incomplete (a symlink target is gone) or error.
func (d *skillDrift) renderState(configRoot, profile string) string {
	dir := configRoot + "/research-sdd/profile/" + profile
	if !isDirOS(dir) {
		return "missing"
	}
	tmp, err := d.mktemp()
	if err != nil {
		return "error"
	}
	defer os.RemoveAll(tmp) //nolint:errcheck
	if _, ok := d.render(profile, tmp); !ok {
		return "error"
	}
	for _, rel := range []string{"skills/research-sdd/SKILL.md", "PROMPT-LOOP.md", "METHODOLOGY.md"} {
		if !sameBytes(filepath.Join(tmp, rel), filepath.Join(dir, rel)) {
			return "diverged"
		}
	}
	for _, f := range []string{"toolbelt", "TARGETS.md", "skills/README.md"} {
		if !existsOS(filepath.Join(dir, f)) {
			return "incomplete"
		}
	}
	return "ok"
}

// skillDriftCheck is verify-skill-drift.sh. errw is where its stderr goes (the hook joins it into a buffer).
func skillDriftCheck(kitRoot string, args []string, s cli.Stdio, out, errw io.Writer) int {
	d := &skillDrift{s: s, errw: errw}
	defer d.cleanup()
	install, ok := physicalDir(filepath.Join(kitRoot, "install"))
	if !ok {
		d.eprintf("%s: ERROR: install dir not found\n", skillDriftName)
		return cli.ExitUsage
	}
	if adapters := filepath.Join(install, "adapters.sh"); !isFileOS(adapters) {
		d.eprintf("%s: ERROR: adapters.sh not found: %s\n", skillDriftName, adapters)
		return cli.ExitUsage
	}

	allMode, harness, harnessSet, home, profileFlag := false, "claude", false, "", ""
	for i := 0; i < len(args); {
		a := args[i]
		value := func() (string, bool) {
			if i+1 >= len(args) || args[i+1] == "" {
				d.eprintf("%s: %s requires a non-empty value\n", skillDriftName, a)
				return "", false
			}
			return args[i+1], true
		}
		switch a {
		case "--all":
			allMode = true
			i++
		case "--harness":
			v, ok := value()
			if !ok {
				return cli.ExitUsage
			}
			harness, harnessSet = v, true
			i += 2
		case "--home":
			v, ok := value()
			if !ok {
				return cli.ExitUsage
			}
			home = v
			i += 2
		case "--profile":
			v, ok := value()
			if !ok {
				return cli.ExitUsage
			}
			profileFlag = v
			i += 2
		case "-h", "--help":
			io.WriteString(out, skillDriftHelp) //nolint:errcheck
			return cli.ExitOK
		default:
			d.eprintf("%s: unknown argument: %s\n", skillDriftName, a)
			return cli.ExitUsage
		}
	}
	if allMode && harnessSet {
		d.eprintf("%s: --all and --harness are mutually exclusive\n", skillDriftName)
		return cli.ExitUsage
	}
	if home == "" {
		home = s.Env("HOME")
	}
	if home == "" {
		d.eprintf("%s: could-not-run: HOME is unset or empty and no --home given\n", skillDriftName)
		return cli.ExitUsage
	}
	d.kit = filepath.Dir(install) // cd -P "$KIT_INSTALL/.."
	if allMode {
		return d.checkAll(home, profileFlag)
	}
	return d.checkOne(harness, home, profileFlag)
}

// checkAll is --all: every registered harness.
func (d *skillDrift) checkAll(home, profileFlag string) int {
	checked, inSync, diverged, absent, errs := 0, 0, 0, 0, 0
	fixShown, maxFixLines := 0, 1 // detailed fix lines are capped (SessionStart output budget)
	also := ""
	for _, h := range skillHarnesses {
		checked++
		srcRel := d.skillSrcRelkit(h, home)
		deployed := d.skillPath(h, home)
		if isSymlinkOS(deployed) && !existsOS(deployed) { // dangling: must precede the absent check
			errs++
			d.eprintf("%s: could-not-run harness=%s (dangling symlink: %s)\n", skillDriftName, h.name, deployed)
			continue
		}
		if !existsOS(deployed) { // absent is normal
			absent++
			continue
		}
		if !isFileOS(deployed) || !readableOS(deployed) {
			errs++
			d.eprintf("%s: could-not-run harness=%s (deployed not a readable file: %s)\n", skillDriftName, h.name, deployed)
			continue
		}
		src, tmp, profile, rc := d.resolveSrc(h, home, srcRel, profileFlag)
		if tmp != "" {
			d.tmpDirs = append(d.tmpDirs, tmp)
		}
		if rc != 0 {
			errs++
			if rc == 3 {
				d.eprintf("%s: could-not-run harness=%s (unknown profile)\n", skillDriftName, h.name)
			} else {
				d.eprintf("%s: could-not-run harness=%s (profile render failed)\n", skillDriftName, h.name)
			}
			continue
		}
		if !isFileOS(src) || !readableOS(src) {
			errs++
			d.eprintf("%s: could-not-run harness=%s (src missing: %s)\n", skillDriftName, h.name, src)
			continue
		}
		// a matching skill is not enough for a non-claude profile: the persisted render dir must be intact
		if profile != "claude" {
			cfg, _ := d.configRoot(h, home, true)
			if state := d.renderState(cfg, profile); state != "ok" && sameBytes(src, deployed) {
				errs++
				d.eprintf("%s: could-not-run harness=%s (render dir %s: %s)\n", skillDriftName, h.name, state, cfg+"/research-sdd/profile/"+profile)
				continue
			}
		}
		if sameBytes(src, deployed) {
			inSync++
			continue
		}
		diverged++
		if fixShown < maxFixLines {
			short := strings.TrimPrefix(deployed, home+"/")
			d.eprintf("%s: fix: research-sdd-install.sh --harness %s --force-skill  # deployed: ~/%s\n", skillDriftName, h.name, short)
			fixShown++
		} else {
			if also != "" {
				also += ", "
			}
			also += h.name
		}
	}
	if also != "" {
		d.eprintf("%s: also diverged: %s (same fix with --harness <name>)\n", skillDriftName, also)
	}
	if diverged > 0 || errs > 0 { // in-sync / all-absent is truly silent
		d.eprintf("%s: all: checked=%d in-sync=%d diverged=%d absent=%d could-not-run=%d\n", skillDriftName, checked, inSync, diverged, absent, errs)
	}
	switch {
	case diverged > 0:
		return cli.ExitOperational
	case errs > 0:
		return cli.ExitUsage
	}
	return cli.ExitOK
}

// exitAbsent is the single-harness code for "no deployed skill found".
const exitAbsent = 3

// checkOne is single-harness mode.
func (d *skillDrift) checkOne(harness, home, profileFlag string) int {
	h, known := findSkillHarness(harness)
	if known {
		_, known = d.configRoot(h, home, true) // rsdd_field <h> config_root >/dev/null 2>&1
	}
	if !known {
		d.eprintf("%s: ERROR: unknown harness \"%s\"\n", skillDriftName, harness)
		return cli.ExitUsage
	}
	srcRel := d.skillSrcRelkit(h, home)
	deployed := d.skillPath(h, home)
	src, tmp, profile, rc := d.resolveSrc(h, home, srcRel, profileFlag)
	if tmp != "" {
		d.tmpDirs = append(d.tmpDirs, tmp)
	}
	if rc != 0 {
		if rc == 3 {
			d.eprintf("%s: ERROR: unknown profile for harness \"%s\"\n", skillDriftName, harness)
		} else {
			d.eprintf("%s: ERROR: could not render profile for harness \"%s\"\n", skillDriftName, harness)
		}
		return cli.ExitUsage
	}
	if !isFileOS(src) {
		d.eprintf("%s: ERROR: kit source not found: %s\n", skillDriftName, src)
		return cli.ExitUsage
	}
	if !readableOS(src) {
		d.eprintf("%s: ERROR: kit source not readable: %s\n", skillDriftName, src)
		return cli.ExitUsage
	}
	if isSymlinkOS(deployed) && !existsOS(deployed) { // dangling: must precede the absent check
		d.eprintf("%s: could-not-run harness=%s (dangling symlink: %s)\n", skillDriftName, harness, deployed)
		return cli.ExitUsage
	}
	if !existsOS(deployed) {
		d.eprintf("%s: absent harness=%s deployed=%s\n", skillDriftName, harness, deployed)
		return exitAbsent
	}
	if !isFileOS(deployed) {
		d.eprintf("%s: ERROR: deployed path exists but is not a regular file: %s\n", skillDriftName, deployed)
		return cli.ExitUsage
	}
	if !readableOS(deployed) {
		d.eprintf("%s: ERROR: deployed skill not readable: %s\n", skillDriftName, deployed)
		return cli.ExitUsage
	}
	if sameBytes(src, deployed) {
		if profile != "claude" {
			cfg, _ := d.configRoot(h, home, true)
			if state := d.renderState(cfg, profile); state != "ok" {
				d.eprintf("%s: could-not-run harness=%s (render dir %s: %s)\n", skillDriftName, harness, state, cfg+"/research-sdd/profile/"+profile)
				return cli.ExitUsage
			}
		}
		return cli.ExitOK // in sync: silent
	}
	d.eprintf("%s: diverged harness=%s deployed=%s\n", skillDriftName, harness, deployed)
	return cli.ExitOperational
}
