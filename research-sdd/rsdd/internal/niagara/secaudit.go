package niagara

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"syscall"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
)

// auditSchema is the evidence schema (research-sdd/toolbelt/niagara-audit.v1.md).
const auditSchema = "niagara-audit.v1"

const (
	auditProg  = "niagara-security-audit"
	auditUsage = "usage: niagara-security-audit [-h] [--station FILE] --output JSON INSTALL_ROOT\n"
	auditHelp  = auditUsage + "\nRead-only Niagara N4 install-directory security-posture auditor. No\n" +
		"subprocesses, no network I/O, no writes to input.\n\n" +
		"positional arguments:\n" +
		"  INSTALL_ROOT    Niagara N4 install directory (niagara_home)\n\n" +
		"options:\n" +
		"  -h, --help      show this help message and exit\n" +
		"  --station FILE  station config.bog for SEC-08/SEC-10/SEC-12 checks\n" +
		"  --output JSON   output JSON evidence file (must not already exist)\n"
)

var auditSpec = argSpec{
	prog: auditProg, usage: auditUsage, help: auditHelp, positional: "INSTALL_ROOT",
	opts: []optDef{{"--station", false}, {"--output", true}},
}

// auditChecks runs the checks; the tests replace it to prove a failing walk is reported, not lost.
var auditChecks = runChecks

// RunSecurityAudit is `rsdd niagara security-audit INSTALL_ROOT [--station config.bog] --output JSON`, the port
// of niagara_security_audit.py: a read-only scan of a Niagara N4 install directory that writes per-check
// security findings (SEC-01..SEC-16; SEC-13 is not defined by the source corpus) as key-sorted JSON. It emits
// check ids, verdicts and structural descriptions only, never a credential, key or certificate.
//
// Exit codes: 0 complete (findings may be present); 1 a walk error (status "failed" JSON is still written);
// 2 the root is absent, not a directory or a symlink, or the output could not be created (no JSON written), or
// a usage error.
func RunSecurityAudit(args []string, s cli.Stdio) int {
	pa, st := auditSpec.parse(args)
	if st != nil {
		fmt.Fprint(s.Out, st.out)
		fmt.Fprint(s.Err, st.err)
		return st.code
	}

	// Strip trailing separators: lstat("link/") follows the link.
	home := strings.TrimRight(pa.positional, "/")
	if home == "" {
		home = "/"
	}
	li, err := os.Lstat(home)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: %s: %s\n", auditProg, home, "No such file or directory")
		return 2
	}
	if li.Mode()&os.ModeSymlink != 0 {
		fmt.Fprintf(s.Err, "%s: %s: is a symbolic link (rejected)\n", auditProg, home)
		return 2
	}
	// stat, not lstat: the type check is on the real target even if the symlink check above were gone.
	di, err := os.Stat(home)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: %s: %s\n", auditProg, home, bog.StrError(err))
		return cli.ExitOperational
	}
	if !di.IsDir() {
		fmt.Fprintf(s.Err, "%s: %s: not a directory\n", auditProg, home)
		return 2
	}

	station, haveStation := pa.vals["--station"]
	checks, errs := safeChecks(s.Cwd, home, station, haveStation)

	var nPass, nFail, nManual, nNA int
	for _, c := range checks {
		switch c["verdict"] {
		case "PASS":
			nPass++
		case "FAIL":
			nFail++
		case "MANUAL":
			nManual++
		case "NA":
			nNA++
		}
	}
	rows := make([]any, len(checks))
	for i, c := range checks {
		rows[i] = c
	}
	errList := make([]any, len(errs))
	for i, e := range errs {
		errList[i] = jsonText(e)
	}
	status := "complete"
	if len(errs) > 0 {
		status = "failed"
	}
	result := map[string]any{
		"checks":       rows,
		"errors":       errList,
		"install_root": jsonText(home),
		"limitations": []any{
			"Network-dependent checks (SEC-04, SEC-09, SEC-14) are always MANUAL.",
			"Keystore password and key-size checks (SEC-02 partial, SEC-11) require keytool.",
			"Filesystem ACL checks (SEC-03) require platform tooling (icacls on Windows).",
			"Station-config checks (SEC-08, SEC-10, SEC-12) require --station <config.bog>.",
			"SEC-13 is not defined by the source corpus check set.",
		},
		"schema": auditSchema,
		"status": status,
		"summary": map[string]any{
			"checks_fail":   nFail,
			"checks_manual": nManual,
			"checks_na":     nNA,
			"checks_pass":   nPass,
			"checks_run":    len(checks),
		},
	}
	content, err := jsonout.Indented(result)
	if err != nil {
		fmt.Fprintf(s.Err, "%s: cannot encode evidence: %v\n", auditProg, err)
		return cli.ExitOperational
	}
	if err := writeNew(pa.vals["--output"], content); err != nil {
		fmt.Fprintf(s.Err, "%s: output error: %s\n", auditProg, osErrorText(err, pa.vals["--output"]))
		return 2
	}
	if len(errs) > 0 {
		return 1
	}
	return 0
}

// jsonText makes s encodable. Python carries the bytes of a name that is not valid UTF-8 as lone surrogates and
// json.dumps writes them as \udcXX; the shared encoder refuses invalid UTF-8, so each run of such bytes becomes
// one U+FFFD here (a declared divergence, see the parity test).
func jsonText(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	return strings.ToValidUTF8(s, "�")
}

// osErrorText is str(OSError) for a failed open(path): "[Errno N] strerror: 'path'".
func osErrorText(err error, path string) string {
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		return err.Error()
	}
	return fmt.Sprintf("[Errno %d] %s: %s", int(errno), bog.StrError(errno), bog.PyReprPath(path))
}

// safeChecks runs the checks and turns a failure inside them into the "errors" entry of a failed document, the
// way the legacy try/except does.
func safeChecks(cwd, home, station string, haveStation bool) (checks []map[string]any, errs []string) {
	defer func() {
		if r := recover(); r != nil {
			checks, errs = nil, []string{fmt.Sprint(r)}
		}
	}()
	return auditChecks(cwd, home, station, haveStation), nil
}

// check builds one result row. The JSON encoder sorts the keys.
func check(id, sev, title, verdict, observed, secure, note string) map[string]any {
	return map[string]any{
		"id": id, "note": note, "observed": observed, "secure": secure,
		"severity": sev, "title": title, "verdict": verdict,
	}
}

func verdictOf(fail bool) string {
	if fail {
		return "FAIL"
	}
	return "PASS"
}

func present(b bool) string {
	if b {
		return "present"
	}
	return "absent"
}

// regularNoLink is os.path.isfile(p) and not os.path.islink(p).
func regularNoLink(p string) bool {
	fi, err := os.Lstat(p)
	return err == nil && fi.Mode().IsRegular()
}

// dirNoLink is os.path.isdir(p) and not os.path.islink(p).
func dirNoLink(p string) bool {
	fi, err := os.Lstat(p)
	return err == nil && fi.IsDir()
}

// stationFormat classifies the --station argument the way run_audit does before it reads the file.
func stationFormat(station string, have bool) (xml, format string) {
	if !have {
		return "", bogNotGiven
	}
	fi, err := os.Stat(station)
	li, lerr := os.Lstat(station)
	if err != nil || !fi.Mode().IsRegular() || lerr != nil || li.Mode()&os.ModeSymlink != 0 {
		return "", bogNotFound
	}
	return readBog(station)
}

// manualObserved is the "observed" text of a station check that could not run.
func manualObserved(format string) string {
	switch format {
	case bogNotGiven:
		return "not checked (no --station config.bog provided)"
	case bogNotFound:
		return "not checked (station file not found or not a regular file)"
	case bogTruncated:
		return "not checked (ZIP file.xml exceeds 32 MiB inflate cap)"
	case bogUnknown:
		return "not checked (station file format unrecognized: not a ZIP bog or plaintext)"
	case bogError:
		return "not checked (station file could not be read)"
	}
	return "not checked"
}

// runChecks is run_audit: every check against the install root, in report order.
func runChecks(cwd, home, station string, haveStation bool) []map[string]any {
	var checks []map[string]any
	props := readProps(cwd, home)
	prop := func(key string) (val string, set bool, commented bool) {
		p, ok := props[key]
		if !ok {
			return "", false, true // props.get(key, (None, True))
		}
		return p.val, true, p.commented
	}
	bogXML, bogFmt := stationFormat(station, haveStation)
	haveBog := bogFmt == bogZip || bogFmt == bogPlaintext

	// SEC-01 (crit) moduleVerificationMode
	v, set, commented := prop("niagara.moduleVerificationMode")
	fail01 := !set || commented || strings.ToLower(v) == "low"
	observed := v
	switch {
	case !set:
		observed = "(unset)"
	case commented:
		observed = "(commented)"
	}
	checks = append(checks, check("SEC-01", "crit", "moduleVerificationMode", verdictOf(fail01), observed, "high",
		"low allows an unsigned module requesting NETWORK_COMMUNICATION to load"))

	// SEC-02 (crit) truststore presence; the password check needs keytool
	tsPresent := regularNoLink(pjoin(pjoin(home, "security"), "truststore.jks"))
	checks = append(checks, check("SEC-02", "crit", "truststore.jks default password", "MANUAL", present(tsPresent),
		"non-default store password",
		"password check requires keytool: keytool -list -keystore <path> -storepass changeit"))

	// SEC-03 (crit) security/ ACLs: platform specific, MANUAL here
	secPresent := dirNoLink(pjoin(home, "security"))
	secObserved := "directory absent"
	if secPresent {
		secObserved = "directory present"
	}
	checks = append(checks, check("SEC-03", "crit", "security/ filesystem ACLs", "MANUAL", secObserved,
		"Admin/SYSTEM only",
		"ACL check requires icacls.exe (Windows); verify with icacls <home>\\security"))

	// SEC-04 (crit) default TLS certificate: live probe, MANUAL in install-audit mode
	checks = append(checks, check("SEC-04", "crit", "station TLS certificate", "MANUAL",
		"not checked (requires live port probe)",
		"CA-issued certificate replacing the factory self-signed default",
		"use --host with the source tool for live TLS check on ports 443 and 5011"))

	// SEC-05 (high) commandLinePropertyBlacklist covers the skip levers
	v, set, commented = prop("niagara.commandLinePropertyBlacklist")
	covered := false
	obs05 := "disabled/absent"
	if set && v != "" && !commented {
		covered = strings.Contains(v, "skipModuleValidation") && strings.Contains(v, "ignoreVerificationMode")
		obs05 = "partial (missing skip levers)"
		if covered {
			obs05 = "full"
		}
	}
	checks = append(checks, check("SEC-05", "high", "commandLinePropertyBlacklist covers skip levers", verdictOf(!covered), obs05,
		"includes skipModuleValidation + commissioning.ignoreVerificationMode",
		"-Dniagara.classLoader.skipModuleValidation can disable chain validation at launch"))

	// SEC-06 (high) license attributes relaxing signature validation
	const t06 = "license attributes relaxing signature validation"
	const sec06 = "no developer/unreleased/smDeveloper flags in any license"
	if hits, ok := scanLicenses(cwd, home); !ok {
		checks = append(checks, check("SEC-06", "high", t06, "NA", "security/licenses/ absent, unreadable, or outside install root", sec06, ""))
	} else {
		obs, note := "none found", ""
		if len(hits) > 0 {
			obs = fmt.Sprintf("%d relaxation attribute(s) found", len(hits))
			note = jsonText(licenseNote(hits))
		}
		checks = append(checks, check("SEC-06", "high", t06, verdictOf(len(hits) > 0), obs, sec06, note))
	}

	// SEC-07 (high) program.requireSigning
	v, set, commented = prop("program.requireSigning")
	bad07 := !set || commented || strings.ToLower(v) == "false"
	obs07 := v
	if bad07 {
		obs07 = "false/default"
	}
	checks = append(checks, check("SEC-07", "high", "program.requireSigning (BProgram bytecode)", verdictOf(bad07), obs07, "true",
		"superuser BProgram runs arbitrary bytecode unsigned when false or absent"))

	// SEC-08 (high) allowProgramRuntimeExec, needs --station
	if haveBog {
		on := execRE.MatchString(bogXML)
		obs := "false/default"
		if on {
			obs = "true"
		}
		checks = append(checks, check("SEC-08", "high", "allowProgramRuntimeExec", verdictOf(on), obs, "false",
			"Runtime.exec() from BProgram is permitted when true"))
	} else {
		checks = append(checks, check("SEC-08", "high", "allowProgramRuntimeExec", "MANUAL", manualObserved(bogFmt), "false",
			"pass --station <config.bog> to enable this check"))
	}

	// SEC-09 (high) platform daemon plaintext port 3011: live probe, MANUAL
	checks = append(checks, check("SEC-09", "high", "platform daemon plaintext port 3011", "MANUAL",
		"not checked (requires live port probe)", "sslOnly=true (port 5011 only)",
		"use --host with the source tool for live port check"))

	// SEC-10 (high) syslog offload to an external SIEM, needs --station
	const sec10 = "enabled with serverHost and TLS transport configured"
	if haveBog {
		on := syslogRE.MatchString(bogXML) && enabled.MatchString(bogXML)
		obs := "disabled/absent"
		if on {
			obs = "enabled"
		}
		checks = append(checks, check("SEC-10", "high", "syslog offload to external SIEM", verdictOf(!on), obs, sec10,
			"the only tamper-resistance for the local audit/history record"))
	} else {
		checks = append(checks, check("SEC-10", "high", "syslog offload to external SIEM", "MANUAL", manualObserved(bogFmt), sec10,
			"pass --station <config.bog> to enable this check"))
	}

	// SEC-11 (med) weak signing keys / FIPS: file presence only
	fips := regularNoLink(pjoin(pjoin(pjoin(pjoin(home, "jre"), "lib"), "security"), "cacerts.bcfks"))
	checks = append(checks, check("SEC-11", "med", "weak signing keys / FIPS", "MANUAL",
		"truststore.jks: "+present(tsPresent)+"; FIPS indicator (cacerts.bcfks): "+present(fips),
		"all keys >= 2048 bit; FIPS keystore (cacerts.bcfks) present",
		"key size check requires keytool; FIPS indicator: jre/lib/security/cacerts.bcfks"))

	// SEC-12 (med) config.bog at-rest encoding, needs --station
	const sec12 = "reversibleEncodingKeySource set to external or equivalent"
	if haveBog {
		encoded := false
		if m := keySrcRE.FindStringSubmatch(bogXML); m != nil {
			switch strings.ToLower(m[1]) {
			case "none", "false", "0", "":
			default:
				encoded = true
			}
		}
		obs := "none (plaintext)"
		if encoded {
			obs = "external/encoded"
		}
		checks = append(checks, check("SEC-12", "med", "config.bog at-rest encoding", verdictOf(!encoded), obs, sec12,
			"reversibleEncodingKeySource=none leaves reversible passwords in the clear"))
	} else {
		checks = append(checks, check("SEC-12", "med", "config.bog at-rest encoding", "MANUAL", manualObserved(bogFmt), sec12,
			"pass --station <config.bog> to enable this check"))
	}

	// SEC-14 (med) Fox/HTTP plaintext ports: live probe, MANUAL
	checks = append(checks, check("SEC-14", "med", "Fox/HTTP plaintext ports (1911/80)", "MANUAL",
		"not checked (requires live port probe)", "TLS-only endpoints (4911/443)",
		"use --host with the source tool for live port check on 1911 and 80"))

	// SEC-15 (med) KeyRingPermission wildcard in an unsigned module
	const t15 = "KeyRingPermission wildcard in unsigned module"
	const sec15 = "no wildcard KeyRingPermission in an unsigned module"
	if dirNoLink(pjoin(home, "modules")) {
		k := scanKeyring(cwd, home)
		risk := len(k.wildUnsigned) > 0
		scan := fmt.Sprintf("scanned %d of %d JAR(s)", k.scanned, k.total)
		if k.scanned < k.total {
			scan += " (truncated)"
		}
		note := "all wildcard holders are signed (or no wildcard holders found)"
		if risk {
			note = fmt.Sprintf("%d unsigned wildcard holder(s) detected", len(k.wildUnsigned))
		}
		checks = append(checks, check("SEC-15", "med", t15, verdictOf(risk),
			fmt.Sprintf("%d module(s) declare KeyRingPermission; %d wildcard (name=*); %d wildcard AND unsigned; %s",
				len(k.all), len(k.wild), len(k.wildUnsigned), scan),
			sec15, note))
	} else {
		checks = append(checks, check("SEC-15", "med", t15, "NA", "modules/ directory absent", sec15, ""))
	}

	// SEC-16 (med) local data record integrity: architectural, always FAIL
	checks = append(checks, check("SEC-16", "med", "local data record integrity (audit/history/backup)", "FAIL",
		"unsigned by design (architectural limitation)",
		"syslog offload to external SIEM (see SEC-10) provides tamper-resistance",
		"Niagara signs code modules but not data records; no configuration toggle exists"))

	return checks
}

// licenseNote is "; ".join(f"{f}:{a}" for f, a in sorted(set(hits))).
func licenseNote(hits []licenseHit) string {
	seen := map[licenseHit]bool{}
	var uniq []licenseHit
	for _, h := range hits {
		if !seen[h] {
			seen[h] = true
			uniq = append(uniq, h)
		}
	}
	sort.Slice(uniq, func(i, j int) bool {
		if uniq[i].file != uniq[j].file {
			return uniq[i].file < uniq[j].file
		}
		return uniq[i].attr < uniq[j].attr
	})
	parts := make([]string, len(uniq))
	for i, h := range uniq {
		parts[i] = h.file + ":" + h.attr
	}
	return strings.Join(parts, "; ")
}
