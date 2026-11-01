package niagara

import (
	"bytes"
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
)

// Caps that bound memory and run time (niagara-audit.v1).
const (
	maxPropsBytes  = 512 * 1024         // system.properties
	maxBogBytes    = 4 * 1024 * 1024    // a plaintext .bog
	maxJarScan     = 5000               // JARs inspected for SEC-15
	maxLicenseScan = 200                // directory entries examined for SEC-06
	maxModuleXML   = 64 * 1024          // META-INF/module.xml inflated bytes
	maxLicenseText = 64 * 1024          // characters of one .license file
	licenseBytes   = 4 * maxLicenseText // bytes enough for maxLicenseText characters
)

// Station file formats, the values _read_bog reports.
const (
	bogZip       = "zip"
	bogPlaintext = "plaintext"
	bogUnknown   = "unknown"
	bogError     = "error"
	bogTruncated = "truncated"
	bogNotFound  = "not_found"
	bogNotGiven  = "not_provided"
)

// pySpace is Python's \s for str patterns (str.isspace), as an RE2 class; pyWord is \w.
const (
	pySpace = `[\t-\r\x1c-\x20\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]`
	pyWord  = `[\p{L}\p{N}_]`
)

// ci renders a literal for a re.IGNORECASE pattern. Go's (?i) folds k/K/Kelvin and s/S/long s like Python's
// matcher but not the dotless/dotted I that Python also folds onto "i", so every i becomes an explicit class.
func ci(lit string) string {
	return strings.NewReplacer("i", "[iIıİ]", "I", "[iIıİ]").Replace(lit)
}

var (
	execRE   = regexp.MustCompile(`(?i)` + ci("allowProgramRuntimeExec") + pySpace + `*=` + pySpace + `*["']?` + ci("true"))
	enabled  = regexp.MustCompile(`(?i)` + ci("enabled") + pySpace + `*=` + pySpace + `*["']?` + ci("true"))
	syslogRE = regexp.MustCompile(`SyslogService|BSyslogSettings`)
	keySrcRE = regexp.MustCompile(`(?i)` + ci("reversibleEncodingKeySource") + pySpace + `*=` + pySpace + `*["']?(` + pyWord + `+)`)
	keyRing  = regexp.MustCompile(`KeyRingPermission"[^>]*?(?:name|target)="([^"]*)"`)
)

// relaxAttrs are the license attributes that relax module validation, in the order SEC-06 reports them.
var relaxAttrs = []struct {
	name string
	re   *regexp.Regexp
}{
	{"skipModuleValidation", regexp.MustCompile("skipModuleValidation" + pySpace + `*=` + pySpace + `*"?true`)},
	{"smDeveloperMode", regexp.MustCompile("smDeveloperMode" + pySpace + `*=` + pySpace + `*"?true`)},
	{"unreleasedSoftware", regexp.MustCompile("unreleasedSoftware" + pySpace + `*=` + pySpace + `*"?true`)},
}

// universalNewlines is what a text-mode file object does to the text it decodes: \r\n and \r become \n.
func universalNewlines(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
}

func skipSpace(s string, i int) int {
	for i < len(s) {
		r, size := utf8.DecodeRuneInString(s[i:])
		if !bog.IsSpace(r) {
			break
		}
		i += size
	}
	return i
}

// prop is one system.properties assignment.
type prop struct {
	val       string
	commented bool
}

// parsePropLine is re.match(r"\s*(#?)\s*(niagara\.[\w.]+|program\.[\w.]+)\s*=\s*(.*)", line) and the strip of
// its last group. The two alternatives start differently, so the match never needs to backtrack.
func parsePropLine(line string) (key string, p prop, ok bool) {
	i := skipSpace(line, 0)
	if i < len(line) && line[i] == '#' {
		p.commented = true
		i++
	}
	i = skipSpace(line, i)
	prefix := ""
	for _, pre := range []string{"niagara.", "program."} {
		if strings.HasPrefix(line[i:], pre) {
			prefix = pre
		}
	}
	if prefix == "" {
		return "", prop{}, false
	}
	j := i + len(prefix)
	k := j
	for k < len(line) {
		r, size := utf8.DecodeRuneInString(line[k:])
		if r != '.' && !bog.IsWord(r) {
			break
		}
		k += size
	}
	if k == j {
		return "", prop{}, false
	}
	e := skipSpace(line, k)
	if e >= len(line) || line[e] != '=' {
		return "", prop{}, false
	}
	e = skipSpace(line, e+1)
	p.val = bog.TrimSpace(line[e:])
	return line[i:k], p, true
}

// readProps is _read_props: the first of defaults/system.properties and system.properties that is a regular
// file inside the install root and not over the cap, parsed line by line. It never fails; a file that cannot be
// used yields no properties.
func readProps(cwd, home string) map[string]prop {
	props := map[string]prop{}
	for _, rel := range []string{"defaults/system.properties", "system.properties"} {
		p := pjoin(home, rel)
		if parent := pdirname(p); parent != home && !insideRoot(cwd, home, parent) {
			continue
		}
		fi, err := os.Lstat(p)
		if err != nil || !fi.Mode().IsRegular() || fi.Size() > maxPropsBytes {
			continue
		}
		f, err := bog.ReadFileCapped(p, maxPropsBytes)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(universalNewlines(bog.DecodeReplace(f.Data)), "\n") {
			if key, pr, ok := parsePropLine(line); ok {
				props[key] = pr
			}
		}
		break // first match wins; defaults/ takes priority
	}
	return props
}

// listdirSorted is sorted(os.listdir(dir)).
func listdirSorted(dir string) ([]string, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	names, err := f.Readdirnames(-1)
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	return names, nil
}

// licenseHit is one relaxation attribute found in one license file.
type licenseHit struct{ file, attr string }

// scanLicenses is _scan_licenses. ok is false when security/licenses/ is absent, unreadable or resolves outside
// the install root (SEC-06 reports NA, not PASS); hits may be empty with ok true.
func scanLicenses(cwd, home string) (hits []licenseHit, ok bool) {
	dir := pjoin(pjoin(home, "security"), "licenses")
	if !insideRoot(cwd, home, dir) {
		return nil, false
	}
	names, err := listdirSorted(dir)
	if err != nil {
		return nil, false
	}
	for i, name := range names {
		if i >= maxLicenseScan {
			break
		}
		if !strings.HasSuffix(name, ".license") {
			continue
		}
		path := pjoin(dir, name)
		fi, err := os.Lstat(path)
		if err != nil || !fi.Mode().IsRegular() {
			continue
		}
		f, err := bog.ReadFileCapped(path, licenseBytes)
		if err != nil {
			continue
		}
		text := firstChars(universalNewlines(bog.DecodeReplace(f.Data)), maxLicenseText)
		for _, a := range relaxAttrs {
			if a.re.MatchString(text) || (strings.Contains(text, a.name) && strings.Contains(text, "developer")) {
				hits = append(hits, licenseHit{name, a.name})
			}
		}
	}
	return hits, true
}

// firstChars is s[:n] counted in characters, like TextIOWrapper.read(n).
func firstChars(s string, n int) string {
	for i := range s {
		if n == 0 {
			return s[:i]
		}
		n--
	}
	return s
}

// keyringScan is the outcome of _scan_keyring_perms.
type keyringScan struct {
	all, wild, wildUnsigned []string
	scanned, total          int
}

func hasName(names []string, want string) bool {
	for _, n := range names {
		if n == want {
			return true
		}
	}
	return false
}

// signedName is n.startswith("META-INF/") and n.upper().endswith((".RSA", ".DSA", ".EC")).
func signedName(n string) bool {
	if !strings.HasPrefix(n, "META-INF/") {
		return false
	}
	u := strings.ToUpper(n)
	return strings.HasSuffix(u, ".RSA") || strings.HasSuffix(u, ".DSA") || strings.HasSuffix(u, ".EC")
}

// moduleXML reads META-INF/module.xml of one JAR under the inflate cap. ok is false for anything the legacy
// scan skips: not an archive, no module.xml, an unreadable member, an oversized one.
func moduleXML(path string) (xml string, names []string, ok bool) {
	h, err := bog.Open(path)
	if err != nil {
		return "", nil, false
	}
	defer h.Close()
	z, err := h.Zip()
	if err != nil {
		return "", nil, false
	}
	names = z.Names()
	if !hasName(names, "META-INF/module.xml") {
		return "", nil, false
	}
	body, truncated, err := z.ReadMember("META-INF/module.xml", maxModuleXML)
	if err != nil || truncated {
		return "", nil, false
	}
	return bog.DecodeReplace(body), names, true
}

// scanKeyring is _scan_keyring_perms: modules/*.jar whose META-INF/module.xml declares KeyRingPermission.
func scanKeyring(cwd, home string) keyringScan {
	var r keyringScan
	dir := pjoin(home, "modules")
	if !insideRoot(cwd, home, dir) {
		return r
	}
	entries, err := listdirSorted(dir)
	if err != nil {
		return r
	}
	var jars []string
	for _, e := range entries {
		if strings.HasSuffix(e, ".jar") {
			jars = append(jars, e)
		}
	}
	r.total = len(jars)
	for _, name := range jars {
		if r.scanned >= maxJarScan {
			break
		}
		path := pjoin(dir, name)
		fi, err := os.Lstat(path)
		if err != nil || fi.Mode()&os.ModeSymlink != 0 {
			continue
		}
		r.scanned++
		xml, names, ok := moduleXML(path)
		if !ok || !strings.Contains(xml, "KeyRingPermission") {
			continue
		}
		r.all = append(r.all, name)
		wild := false
		for _, m := range keyRing.FindAllStringSubmatch(xml, -1) {
			if m[1] == "*" {
				wild = true
			}
		}
		if !wild {
			continue
		}
		r.wild = append(r.wild, name)
		signed := false
		for _, n := range names {
			if signedName(n) {
				signed = true
				break
			}
		}
		if !signed {
			r.wildUnsigned = append(r.wildUnsigned, name)
		}
	}
	return r
}

// readBog is _read_bog: the station file's XML text and what it was (zip, plaintext, unknown, error,
// truncated). A ZIP whose file.xml cannot be read falls back to the plaintext read like the legacy fallback
// does, which classifies it unknown because a ZIP header holds NUL bytes.
func readBog(path string) (xml, format string) {
	h, err := bog.Open(path)
	if err != nil {
		return "", bogError
	}
	defer h.Close()
	if z, err := h.Zip(); err == nil {
		if !hasName(z.Names(), "file.xml") {
			return "", bogUnknown
		}
		if body, truncated, err := z.ReadMember("file.xml", bog.MaxInflate); err == nil {
			if truncated {
				return "", bogTruncated
			}
			return bog.DecodeReplace(body), bogZip
		}
	}
	raw, err := h.Head(maxBogBytes)
	if err != nil {
		return "", bogError
	}
	if bytes.IndexByte(raw[:min(512, len(raw))], 0) >= 0 {
		return "", bogUnknown
	}
	return bog.DecodeReplace(raw), bogPlaintext
}
