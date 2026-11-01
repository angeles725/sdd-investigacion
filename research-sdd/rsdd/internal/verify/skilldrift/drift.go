package skilldrift

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of research-sdd/toolbelt/verify-skill-drift.sh: is the deployed skill of a harness the kit's source?
//
//	rsdd verify skill-drift [--all | --harness <h>] [--home <dir>] [--profile <name>]
//
// Exit codes are the script's: --all gives 0 in-sync or absent (silent), 1 diverged, 2 could not check; a single harness
// gives 0 in-sync (silent), 1 diverged, 2 could not run, 3 absent. Every message goes to stderr; stdout carries only --help.
// Read-only: it never writes to the kit or to the home; profile renders go to a throwaway temp dir removed on every exit path.

// RunDrift is the `verify skill-drift` command.
func RunDrift(args []string, s cli.Stdio) int {
	e := newEnvView(s)
	kp, ok := resolveInstall(e.get(selfDirKey))
	if !ok {
		if e.get(selfDirKey) == "" {
			fmt.Fprintf(s.Err, "verify-skill-drift: ERROR: toolbelt dir unknown (%s unset; run through toolbelt/verify-skill-drift.sh)\n", selfDirKey)
		} else {
			fmt.Fprint(s.Err, "verify-skill-drift: ERROR: install dir not found\n")
		}
		return 2
	}
	adaptersFile := filepath.Join(kp.kitInstall, "adapters.sh")
	if !isFile(adaptersFile) {
		fmt.Fprintf(s.Err, "verify-skill-drift: ERROR: adapters.sh not found: %s\n", adaptersFile)
		return 2
	}
	bash, found := findExe("bash", e.get("PATH"))
	if !found {
		fmt.Fprint(s.Err, "verify-skill-drift: degraded: bash not found; install/adapters.sh cannot be evaluated\n")
		return 2
	}
	ad := adapters{bash: bash, file: adaptersFile, env: e.environ(), dir: s.Cwd}
	ld := ad.load()
	io.WriteString(s.Err, ld.stderr) //nolint:errcheck // diagnostics

	a, rc, done := parseArgs(args, s.Out, s.Err)
	if done {
		return rc
	}
	home := a.home
	if home == "" {
		home = e.get("HOME")
	}
	// SENTINEL-HOME-CHECK
	if home == "" {
		fmt.Fprint(s.Err, "verify-skill-drift: could-not-run: HOME is unset or empty and no --home given\n")
		return 2
	}
	kp.kitRoot()

	d := &driftRun{
		s: s, ad: ad, ld: ld, kit: kp.kit, home: home, flag: a.profile,
		rn: &renderer{script: filepath.Join(kp.kit, "toolbelt", "render-profile.sh"), env: e.environ(), dir: s.Cwd, tmpDir: e.tmpDir()},
	}
	defer d.cleanup()
	if a.all {
		return d.all()
	}
	return d.single(a.harness)
}

// driftRun is one run of the command.
type driftRun struct {
	s    cli.Stdio
	ad   adapters
	ld   loaded
	kit  string
	home string
	flag string
	rn   *renderer
	tmps []string // render dirs to sweep on every exit path
}

func (d *driftRun) errf(format string, a ...any) { fmt.Fprintf(d.s.Err, format, a...) }

func (d *driftRun) cleanup() {
	for _, t := range d.tmps {
		os.RemoveAll(t)
	}
}

// field is `$(rsdd_field h f home)`: a failing field gives the empty string, its stderr passes through.
func (d *driftRun) field(h, f string) string { return d.ad.field(d.s.Err, h, f, d.home).out }

// resolved is what _vsd_resolve_src produces.
type resolved struct {
	src     string
	profile string
}

// resolve is _vsd_resolve_src: the path to compare the deployed skill against. rc is 0 ok, 2 could-not-run (temp dir or render
// failure), 3 unknown profile. Profile "claude", or an adapters.sh without profile support, compares against the kit source
// directly; any other profile is re-rendered into a throwaway temp dir that cleanup removes.
func (d *driftRun) resolve(h, srcRelkit string) (r resolved, rc int) {
	if !d.ld.hasProfile {
		return resolved{filepath.Join(d.kit, srcRelkit), "claude"}, 0
	}
	pair := d.ad.resolveProfile(d.s.Err, h, d.flag).out
	profile, _, _ := strings.Cut(pair, ":")
	if !d.ad.validProfile(profile, d.kit) {
		return resolved{}, 3
	}
	if profile == "claude" {
		return resolved{filepath.Join(d.kit, srcRelkit), profile}, 0
	}
	tmp, err := d.rn.mktemp()
	if err != nil {
		return resolved{}, 2
	}
	if out, ok := d.rn.run(profile, tmp); !ok {
		d.errf("verify-skill-drift: render-profile.sh failed for profile \"%s\": %s\n", profile, out)
		os.RemoveAll(tmp)
		return resolved{}, 2
	}
	d.tmps = append(d.tmps, tmp)
	return resolved{filepath.Join(tmp, srcRelkit), profile}, 0
}

// all is --all mode: every registered harness, in registration order.
func (d *driftRun) all() int {
	var checked, inSync, diverged, absent, bad int
	const maxFixLines = 1 // budget cap: at most this many detailed fix lines
	fixShown := 0
	alsoNames := ""
	if !d.ld.defined {
		d.errf("verify-skill-drift: could-not-run: RESEARCH_SDD_HARNESSES is not defined by adapters.sh\n")
		return 2
	}
	// SENTINEL-ALL-LOOP-FOR
	for _, h := range d.ld.harnesses {
		checked++
		srcRelkit := d.field(h, "skill_src_relkit") // SENTINEL-SRC-RELKIT-LOOKUP
		deployed := d.field(h, "skill_path")

		// SENTINEL-DANGLING-ALL: a dangling symlink is could-not-run, and is told apart from absent first
		if isLink(deployed) && !exists(deployed) {
			bad++
			d.errf("verify-skill-drift: could-not-run harness=%s (dangling symlink: %s)\n", h, deployed)
			continue
		}
		// absent is normal: not installing a harness is not an error
		if !exists(deployed) {
			absent++
			continue
		}
		if !isFile(deployed) || !isReadable(deployed) {
			bad++
			d.errf("verify-skill-drift: could-not-run harness=%s (deployed not a readable file: %s)\n", h, deployed)
			continue
		}

		// the source (or a fresh profile render) is resolved only once the deployed file is known to be comparable: an
		// absent, dangling or unreadable harness never pays for a render (kit issue #993 WU2)
		r, rc := d.resolve(h, srcRelkit)
		if rc != 0 {
			bad++
			if rc == 3 {
				d.errf("verify-skill-drift: could-not-run harness=%s (unknown profile)\n", h)
			} else {
				d.errf("verify-skill-drift: could-not-run harness=%s (profile render failed)\n", h)
			}
			continue
		}
		if !isFile(r.src) || !isReadable(r.src) {
			bad++
			d.errf("verify-skill-drift: could-not-run harness=%s (src missing: %s)\n", h, r.src)
			continue
		}

		// for a non-claude profile a matching deployed skill is not enough: the persisted render dir it depends on at runtime
		// could be missing, hand-edited or incompletely linked (kit issue #1024 review F3)
		if r.profile != "claude" {
			state := d.rn.completeness(d.field(h, "config_root"), r.profile)
			if state != renderOK && sameBytes(r.src, deployed) {
				bad++
				d.errf("verify-skill-drift: could-not-run harness=%s (render dir %s: %s)\n", h, state,
					d.field(h, "config_root")+"/research-sdd/profile/"+r.profile)
				continue
			}
		}

		if sameBytes(r.src, deployed) {
			inSync++
			continue
		}
		diverged++
		if fixShown < maxFixLines {
			short := strings.TrimPrefix(deployed, d.home+"/")
			d.errf("verify-skill-drift: fix: research-sdd-install.sh --harness %s --force-skill  # deployed: ~/%s\n", h, short)
			fixShown++
		} else {
			// SENTINEL-ALSO-DIVERGED
			if alsoNames != "" {
				alsoNames += ", "
			}
			alsoNames += h
		}
	}

	// the names of the diverged harnesses beyond the cap; the output is capped, so it does not say "rerun"
	if alsoNames != "" {
		d.errf("verify-skill-drift: also diverged: %s (same fix with --harness <name>)\n", alsoNames)
	}
	// SENTINEL-SUMMARY-GUARD: a summary only on a non-zero exit (in-sync or all-absent is truly silent)
	if diverged > 0 || bad > 0 {
		d.errf("verify-skill-drift: all: checked=%d in-sync=%d diverged=%d absent=%d could-not-run=%d\n", checked, inSync, diverged, absent, bad)
	}
	if diverged > 0 {
		return 1
	}
	// SENTINEL-ERR-EXIT2
	if bad > 0 {
		return 2
	}
	return 0
}

// single is single-harness mode.
func (d *driftRun) single(harness string) int {
	// an unknown harness is rejected by rsdd_field itself
	if d.ad.call(`rsdd_field "$@"`, harness, "config_root", d.home).rc != 0 {
		d.errf("verify-skill-drift: ERROR: unknown harness \"%s\"\n", harness)
		return 2
	}
	srcRelkit := d.field(harness, "skill_src_relkit")
	deployed := d.field(harness, "skill_path")

	r, rc := d.resolve(harness, srcRelkit)
	if rc != 0 {
		if rc == 3 {
			d.errf("verify-skill-drift: ERROR: unknown profile for harness \"%s\"\n", harness)
		} else {
			d.errf("verify-skill-drift: ERROR: could not render profile for harness \"%s\"\n", harness)
		}
		return 2
	}
	if !isFile(r.src) {
		d.errf("verify-skill-drift: ERROR: kit source not found: %s\n", r.src)
		return 2
	}
	if !isReadable(r.src) {
		d.errf("verify-skill-drift: ERROR: kit source not readable: %s\n", r.src)
		return 2
	}

	// SENTINEL-DANGLING-SINGLE: a dangling symlink is could-not-run, and is told apart from absent first
	if isLink(deployed) && !exists(deployed) {
		d.errf("verify-skill-drift: could-not-run harness=%s (dangling symlink: %s)\n", harness, deployed)
		return 2
	}
	// absent is exit 3; a non-regular file is could-not-run
	if !exists(deployed) {
		d.errf("verify-skill-drift: absent harness=%s deployed=%s\n", harness, deployed)
		return 3
	}
	if !isFile(deployed) {
		d.errf("verify-skill-drift: ERROR: deployed path exists but is not a regular file: %s\n", deployed)
		return 2
	}
	if !isReadable(deployed) {
		d.errf("verify-skill-drift: ERROR: deployed skill not readable: %s\n", deployed)
		return 2
	}

	// byte for byte
	if sameBytes(r.src, deployed) {
		// for a non-claude profile a matching skill is not enough (kit issue #1024 review F3): never collapse into "in sync"
		if r.profile != "claude" {
			root := d.field(harness, "config_root")
			if state := d.rn.completeness(root, r.profile); state != renderOK {
				d.errf("verify-skill-drift: could-not-run harness=%s (render dir %s: %s)\n", harness, state,
					d.field(harness, "config_root")+"/research-sdd/profile/"+r.profile)
				return 2
			}
		}
		return 0 // in sync: silent
	}
	d.errf("verify-skill-drift: diverged harness=%s deployed=%s\n", harness, deployed)
	return 1
}
