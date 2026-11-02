package firmware

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

const supportedBinwalkMajor = "2"

// versionRe reads the banner of Binwalk 2.x ("Binwalk v2.3.3") and 3.x ("binwalk 3.1.0"). The usage line of 3.x
// ("Usage: binwalk [OPTIONS]") names no version and must not match.
var versionRe = regexp.MustCompile(`\b[Bb]inwalk (?:v([^` + pyWS + `]+)|(\p{Nd}[^` + pyWS + `]*))`)

// binwalkVersion is the version a --help or --version output announces, or "" when it announces none.
func binwalkVersion(text string) string {
	m := versionRe.FindStringSubmatch(text)
	switch {
	case m == nil:
		return ""
	case m[1] != "":
		return m[1]
	}
	return m[2]
}

// checkBinwalkVersion refuses a major version whose output the parser does not read.
func checkBinwalkVersion(version string) error {
	if major, _, _ := strings.Cut(version, "."); major != supportedBinwalkMajor {
		return refusal("unsupported Binwalk version " + version + ": only major " + supportedBinwalkMajor + " output is supported")
	}
	return nil
}

// Trust labels the report carries.
const (
	trustRoot     = "root-owned"
	trustUser     = "user-owned-explicit"
	trustOverride = "test-override"
)

const (
	hintDefault  = "; set RSDD_BINWALK=<absolute path> to select a user-owned install"
	hintExplicit = " (RSDD_BINWALK: or owned by the invoking user, not group/world-writable)"
)

// analyzer is the selected Binwalk: where it is, how it was identified, and the gate its bytes must pass when
// they are staged. gate is nil for a test override, which is trusted by nothing.
type analyzer struct {
	record fsx.Record
	trust  string
	gate   *gate
}

// absolutePath keeps the absolute entries of a PATH: a relative or empty entry resolves against the caller's
// working directory, which must never select an analyzer.
func absolutePath(search string) string {
	var keep []string
	for _, entry := range strings.Split(search, string(os.PathListSeparator)) {
		if strings.HasPrefix(entry, "/") {
			keep = append(keep, entry)
		}
	}
	return strings.Join(keep, string(os.PathListSeparator))
}

// which is shutil.which over a PATH of absolute entries: the first entry holding an executable regular file.
func which(name, search string) (string, bool) {
	if search == "" {
		return "", false
	}
	seen := map[string]bool{}
	for _, dir := range strings.Split(search, string(os.PathListSeparator)) {
		if seen[dir] {
			continue
		}
		seen[dir] = true
		p := filepath.Join(dir, name)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && canExec(p) {
			return p, true
		}
	}
	return "", false
}

// resolveStrict is Path.resolve(strict=True): the path with every symlink followed, which must exist.
func resolveStrict(p, cwd string) (string, error) {
	if !filepath.IsAbs(p) {
		p = filepath.Join(cwd, p)
	}
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", osError(err, p)
	}
	return real, nil
}

// executable resolves a configured program and identifies it. With mustMatch the configured path must be the
// one PATH selects for name (a program that merely lives somewhere is not "the" name); without it the file
// only has to be an executable regular file. A gate makes the descriptor owner and mode part of the identity.
func executable(name, configured, search, cwd string, g *gate, mustMatch bool, sink *uint64) (string, fsx.Record, error) {
	search = absolutePath(search)
	candidate, err := resolveStrict(configured, cwd)
	if err != nil {
		return "", fsx.Record{}, err
	}
	fi, statErr := os.Stat(candidate)
	usable := statErr == nil && fi.Mode().IsRegular() && canExec(candidate)
	if mustMatch {
		selected, ok := which(name, search)
		if !ok {
			return "", fsx.Record{}, refusal("PATH-selected " + name + " is missing")
		}
		real, err := resolveStrict(selected, cwd)
		if err != nil {
			return "", fsx.Record{}, err
		}
		same, serr := os.Stat(real)
		if !usable || serr != nil || !os.SameFile(fi, same) {
			return "", fsx.Record{}, refusal("configured " + name + " does not match PATH-selected executable")
		}
	} else if !usable {
		return "", fsx.Record{}, refusal("configured " + name + " is not an executable file: " + candidate)
	}
	resolved, size, digest, err := trustedIdentity(candidate, g, sink)
	if err != nil {
		return "", fsx.Record{}, err
	}
	return resolved, fsx.Record{Path: resolved, Size: size, SHA256: digest}, nil
}

// resolveBinwalk selects the analyzer. RSDD_BINWALK_TEST_ONLY (a test) wins and is not trust-checked; else an
// explicit absolute RSDD_BINWALK is used even when it is not first on PATH, and it and its directory may be
// owned by the invoking user; else the PATH-selected binwalk, which must be root-owned.
func resolveBinwalk(env func(string) string, cwd string, euid uint64) (analyzer, error) {
	testOnly, explicit, search := env("RSDD_BINWALK_TEST_ONLY"), env("RSDD_BINWALK"), env("PATH")
	if testOnly != "" {
		_, rec, err := executable("binwalk", testOnly, search, cwd, nil, true, nil)
		return analyzer{record: rec, trust: trustOverride}, err
	}
	var g *gate
	var configured string
	mustMatch := true
	if explicit != "" {
		if !strings.HasPrefix(explicit, "/") {
			return analyzer{}, refusal("RSDD_BINWALK must be an absolute path")
		}
		g, configured, mustMatch = &gate{uids: map[uint64]bool{0: true, euid: true}, hint: hintExplicit}, explicit, false
	} else {
		selected, ok := which("binwalk", absolutePath(search))
		if !ok {
			return analyzer{}, refusal("PATH-selected binwalk is missing")
		}
		g, configured = &gate{uids: map[uint64]bool{0: true}, hint: hintDefault}, selected
	}
	var uid uint64
	_, rec, err := executable("binwalk", configured, search, cwd, g, mustMatch, &uid)
	if err != nil {
		return analyzer{}, err
	}
	trust := trustUser
	if uid == 0 {
		trust = trustRoot
	}
	return analyzer{record: rec, trust: trust, gate: g}, nil
}
