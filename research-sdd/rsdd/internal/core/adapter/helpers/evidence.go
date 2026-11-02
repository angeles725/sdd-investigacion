package helpers

import (
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// PcapMagic and PcapngMagic are _PCAP_MAGIC (LE/BE x microsecond/nanosecond)
// and _PCAPNG_MAGIC (the Section Header Block type).
var (
	PcapMagic = [][]byte{
		{0xd4, 0xc3, 0xb2, 0xa1},
		{0xa1, 0xb2, 0xc3, 0xd4},
		{0x4d, 0x3c, 0xb2, 0xa1},
		{0xa1, 0xb2, 0x3c, 0x4d},
	}
	PcapngMagic = []byte{0x0a, 0x0d, 0x0d, 0x0a}
)

// manifestMaxBytes caps what one manifest-CLI run may print (stdout+stderr).
// Python has no cap; proc.Run requires one, so it is generous.
const manifestMaxBytes = 64 << 20

// publishFn is the test seam for adapter_core.publish.
var publishFn = fsx.Publish

// safeSchemaRE is _SAFE_SCHEMA_RE. Python's "$" also matches before one
// trailing newline, which is spelled out here because Go's does not.
var safeSchemaRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*\n?$`)

func safeSchema(s string) bool { return safeSchemaRE.MatchString(s) }

// reservedKeys is _RESERVED_KEYS, in sorted order.
var reservedKeys = []string{"errors", "input", "isolation", "limitations", "schema", "status"}

// runCapErrors is _RUN_CAP_ERRORS, in sorted order.
var runCapErrors = []string{"output-cap", "process-cap", "timeout"}

// EmitConfig is every argument of emit_evidence plus the injected process
// seams. ManifestCLI is the argv prefix of the manifest CLI (interpreter and
// script, Python's [sys.executable, manifest_cli]); Env is the child's whole
// environment; Stdout and Stderr receive what the child printed (Python lets
// the child inherit them) and, for Stderr, the warn_evidence pointer. Nil
// writers discard. Run nil means proc.Run. Timeout is in seconds and applies
// to every CLI call.
type EmitConfig struct {
	Stage          string
	Schema         string
	Domain         map[string]any
	InputIdentity  any
	Isolation      any
	Limitations    []string
	Errors         []string
	ManifestSpec   any
	ManifestCLI    []string
	Destination    string
	Timeout        int
	Env            []string
	Stdout, Stderr io.Writer
	Run            func(proc.Spec) (proc.Result, error)
}

// EmitEvidence is emit_evidence: the evidence envelope written atomically to
// stage/<schema>.json, the manifest-CLI create/validate/verify tail, then the
// no-replace publish of stage to Destination. Guard, CLI and publish failures
// are ManifestError; filesystem failures of the writes and a program that
// cannot start are returned raw, as the Python OSErrors are.
func EmitEvidence(c EmitConfig) error {
	if !safeSchema(c.Schema) {
		return newErr(KindManifest, "unsafe schema identifier (must match ^[A-Za-z0-9][A-Za-z0-9._-]*$): "+pyRepr(c.Schema), nil)
	}
	var collisions []string
	for _, k := range reservedKeys {
		if _, ok := c.Domain[k]; ok {
			collisions = append(collisions, pyRepr(k))
		}
	}
	if len(collisions) > 0 {
		return newErr(KindManifest, "domain overrides reserved envelope key(s): ["+strings.Join(collisions, ", ")+"]", nil)
	}
	status := "complete"
	if len(c.Errors) > 0 {
		status = "failed"
	}
	envelope := map[string]any{
		"errors": nonNil(c.Errors), "input": c.InputIdentity, "isolation": c.Isolation,
		"limitations": nonNil(c.Limitations), "schema": c.Schema, "status": status,
	}
	for k, v := range c.Domain {
		envelope[k] = v
	}
	stage, dest := pyNorm(c.Stage), pyNorm(c.Destination)
	if err := writeCanonical(stage+"/"+c.Schema+".json", envelope); err != nil {
		return err
	}
	specPath := pyNorm(stage + "/engine/manifest-spec.json")
	if err := writeCanonical(specPath, c.ManifestSpec); err != nil {
		return err
	}
	manifestPath := pyNorm(stage + "/engine/analysis-manifest.v1.json")
	if err := c.runCLI("create", []string{"--root", stage, "--spec", specPath, "--output", manifestPath}); err != nil {
		return err
	}
	if err := os.Remove(specPath); err != nil {
		return err
	}
	if err := c.runCLI("validate", []string{manifestPath}); err != nil {
		return err
	}
	if err := c.runCLI("verify", []string{"--root", stage, manifestPath}); err != nil {
		return err
	}
	if err := publishFn(stage, dest); err != nil {
		return newErr(KindManifest, "publish failed: "+publishMessage(err, dest), err)
	}
	if len(c.Errors) > 0 {
		WarnEvidence(c.Stderr, c.Schema, dest, strings.Join(c.Errors, ", "))
	}
	return nil
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func writeCanonical(path string, v any) error {
	b, err := jsonout.Canonical(v)
	if err != nil {
		return err
	}
	return fsx.WriteAtomic(path, b)
}

// publishMessage is str(exc) of the Python failure: an errno becomes
// OSError(errno, "atomic publication failed", Path) text; anything else keeps
// its own message.
func publishMessage(err error, dest string) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return fmt.Sprintf("[Errno %d] atomic publication failed: PosixPath(%s)", int(errno), pyRepr(dest))
	}
	return err.Error()
}

// runCLI runs one manifest-CLI verb under the mandatory timeout, fail-closed.
func (c EmitConfig) runCLI(verb string, extra []string) error {
	secs := strconv.Itoa(c.Timeout)
	if c.Timeout <= 0 {
		return newErr(KindManifest, "manifest-cli '"+verb+"' timed out after "+secs+"s", nil)
	}
	argv := append(append(append([]string{}, c.ManifestCLI...), verb), extra...)
	run := c.Run
	if run == nil {
		run = proc.Run
	}
	res, err := run(proc.Spec{Argv: argv, Env: c.Env, Timeout: time.Duration(c.Timeout) * time.Second, MaxBytes: manifestMaxBytes})
	if err != nil {
		return err
	}
	forward(c.Stdout, res.Stdout)
	forward(c.Stderr, res.Stderr)
	switch {
	case res.Reason == proc.ReasonTimeout:
		return newErr(KindManifest, "manifest-cli '"+verb+"' timed out after "+secs+"s", nil)
	case res.Reason == proc.ReasonOutputCap:
		return newErr(KindManifest, "manifest-cli '"+verb+"' output exceeded the capture limit", nil)
	case res.ReturnCode != 0:
		return newErr(KindManifest, "manifest-cli '"+verb+"' failed (exit "+strconv.Itoa(res.ReturnCode)+")", nil)
	}
	return nil
}

func forward(w io.Writer, b []byte) {
	if w != nil {
		_, _ = w.Write(b)
	}
}

// WarnEvidence is warn_evidence: the one-line stderr pointer to the evidence
// file. destination is printed as given.
func WarnEvidence(w io.Writer, schema, destination, detail string) {
	if w == nil {
		return
	}
	d := ""
	if detail != "" {
		d = " (" + detail + ")"
	}
	_, _ = fmt.Fprintf(w, "%s: completed with issues%s — see %s/%s.json\n", schema, d, destination, schema)
}

// RunTruncation is run_truncation: whether a resource cap fired, and one
// limitation per fired cap in sorted order. "analyzer-exit:N" is not a cap.
func RunTruncation(runErrors []string, tool string) (bool, []string) {
	has := map[string]bool{}
	for _, e := range runErrors {
		has[e] = true
	}
	limitations := []string{}
	for _, name := range runCapErrors {
		if has[name] {
			limitations = append(limitations, tool+" run truncated: "+name+" reached — inventory is incomplete")
		}
	}
	return len(limitations) > 0, limitations
}
