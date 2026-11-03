package formats

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const (
	zipMetadataSchema  = "zip-metadata.v1"
	zipMetadataProfile = "in-process-metadata-only"
)

// zipMetadataLimitations is the report's fixed limitation text.
var zipMetadataLimitations = []string{"ZIP64, multi-disk archives, recovery, payload CRC validation, passwords, and extraction are unsupported."}

// zipExecutable is the running binary, recorded in the analysis manifest as the tool launcher; a test
// replaces it.
var zipExecutable = os.Executable

// zipAfterInventory runs between the metadata reads and the stability check; a test mutates the input there.
var zipAfterInventory func()

// zipLauncher is the resolved path of the running binary.
func zipLauncher() (string, error) {
	exe, err := zipExecutable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

// zipRecord is one entry as the canonical report carries it.
func zipRecord(e *ZipEntry) map[string]any {
	var ts any
	if t, ok := dosTimestamp(e.DosDate, e.DosTime); ok {
		ts = t
	}
	return map[string]any{
		"index": e.Index, "name": e.Name, "name_encoding": e.NameEncoding, "name_raw_hex": hex.EncodeToString(e.NameRaw),
		"method": e.Method, "flags": e.Flags, "encrypted": e.Flags&1 != 0, "crc32": fmt.Sprintf("%08x", e.CRC32),
		"compressed_size": e.Compressed, "uncompressed_size": e.Uncompressed,
		"internal_attributes": e.Internal, "external_attributes": e.External,
		"version_made_by": e.MadeBy, "version_needed": e.Needed, "dos_date": e.DosDate, "dos_time": e.DosTime,
		"timestamp": ts, "declared_local_header_offset": e.LocalOffset,
		"safety": map[string]any{
			"absolute": e.Safety.Absolute, "traversal": e.Safety.Traversal, "backslash": e.Safety.Backslash,
			"nul": e.Safety.NUL, "duplicate": e.Safety.Duplicate,
		},
	}
}

// zipParsed is the part of the metadata report that comes from the directory itself.
func zipParsed(d *ZipDirectory) map[string]any {
	entries := make([]any, len(d.Entries))
	for i := range d.Entries {
		entries[i] = zipRecord(&d.Entries[i])
	}
	return map[string]any{
		"entries": entries, "archive_prefix_bytes": d.PrefixBytes, "central_directory_offset": d.CentralOffset,
		"central_directory_size": d.CentralSize, "eocd_offset": d.EOCDOffset, "eocd_comment_raw_hex": hex.EncodeToString(d.EOCDComment()),
	}
}

// zipReportGuard is the incremental report-size cap: each record counts as its canonical line.
func zipReportGuard(maxReport int64) func(*ZipEntry) error {
	var total int64
	return func(e *ZipEntry) error {
		b, err := jsonout.CanonicalUnicode(zipRecord(e))
		if err != nil {
			return err
		}
		total += int64(len(b))
		if total > maxReport {
			return &ZipError{Msg: "canonical report exceeds max-report-bytes"}
		}
		return nil
	}
}

// zipFlags is the shared argument grammar: --input, --output, the hidden --manifest-cli (accepted and ignored), and
// integer caps.
type zipFlags struct {
	tool                    string
	input, output, manifest string
	caps                    map[string]*int64
	order                   []string
	set                     map[string]bool
	fs                      *flag.FlagSet
}

func newZipFlags(tool string, s cli.Stdio, caps []capDef) *zipFlags {
	z := &zipFlags{tool: tool, caps: map[string]*int64{}, set: map[string]bool{}}
	z.fs = flag.NewFlagSet(tool, flag.ContinueOnError)
	z.fs.SetOutput(s.Err)
	z.fs.StringVar(&z.input, "input", "", "archive to read")
	z.fs.StringVar(&z.output, "output", "", "new directory to publish")
	z.fs.StringVar(&z.manifest, "manifest-cli", "", "")
	for _, c := range caps {
		v := c.def
		z.caps[c.name] = &v
		z.order = append(z.order, c.name)
		z.fs.Var(intFlag{v: &v}, c.name, "positive cap (default "+fmt.Sprint(c.def)+")")
	}
	z.fs.Usage = func() {
		fmt.Fprintf(s.Err, "usage: rsdd formats %s --input ARCHIVE --output NEW-DIRECTORY", tool)
		for _, n := range z.order {
			fmt.Fprintf(s.Err, " [--%s N]", n)
		}
		fmt.Fprintln(s.Err)
	}
	return z
}

type capDef struct {
	name string
	def  int64
}

// parse returns the exit code to stop with, or -1 to continue.
func (z *zipFlags) parse(args []string, s cli.Stdio) int {
	if err := z.fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return cli.ExitOK
		}
		return cli.ExitUsage
	}
	z.fs.Visit(func(f *flag.Flag) { z.set[f.Name] = true })
	if z.fs.NArg() > 0 {
		z.fs.Usage()
		fmt.Fprintf(s.Err, "%s: error: unrecognized arguments: %s\n", z.tool, strings.Join(z.fs.Args(), " "))
		return cli.ExitUsage
	}
	var missing []string
	for _, n := range []string{"input", "output"} {
		if !z.set[n] {
			missing = append(missing, "--"+n)
		}
	}
	if len(missing) > 0 {
		z.fs.Usage()
		fmt.Fprintf(s.Err, "%s: error: the following arguments are required: %s\n", z.tool, strings.Join(missing, ", "))
		return cli.ExitUsage
	}
	return -1
}

// cap is a parsed cap by flag name.
func (z *zipFlags) cap(name string) int64 { return *z.caps[name] }

// positive is the "caps must be positive" check over every cap.
func (z *zipFlags) positive() error {
	for _, n := range z.order {
		if *z.caps[n] < 1 {
			return &ZipError{Msg: "caps must be positive"}
		}
	}
	return nil
}

// ZipMetadata is `rsdd formats zip-metadata`: it inventories classic ZIP central-directory metadata without
// reading entries and publishes a closed, manifest-verified output directory.
func ZipMetadata(args []string, s cli.Stdio) int {
	z := newZipFlags("zip-metadata", s, []capDef{
		{"max-input-bytes", 1073741824}, {"max-central-directory-bytes", 16777216}, {"max-entries", 10000},
		{"max-field-bytes", 65536}, {"max-report-bytes", 16777216},
	})
	if code := z.parse(args, s); code >= 0 {
		return code
	}
	if err := zipMetadataRun(z, s); err != nil {
		fmt.Fprintf(s.Err, "zip-metadata: %v\n", err)
		return cli.ExitUsage
	}
	return cli.ExitOK
}

func zipMetadataRun(z *zipFlags, s cli.Stdio) (err error) {
	if err := z.positive(); err != nil {
		return err
	}
	if err := zipRefusePrivileged(); err != nil {
		return err
	}
	parent, err := zipOutputParent(z.output, s.Cwd)
	if err != nil {
		return err
	}
	name := pyName(z.output)
	destination := parent + "/" + name
	owned, err := zipOwnedParent(parent)
	if err != nil {
		return err
	}
	if name == "" || name == "." || name == ".." || zipExists(destination) || !owned {
		return &ZipError{Msg: "output must be a new path in an owned non-writable directory"}
	}
	input := z.input
	if !strings.HasPrefix(input, "/") {
		input = s.Cwd + "/" + input
	}
	src, before, err := zipOpenInput(input)
	if err != nil {
		return err
	}
	var source string
	var parsed *ZipDirectory
	var metadata []byte
	func() {
		defer src.Close()
		if before.Size > z.cap("max-input-bytes") {
			err = &ZipError{Msg: "input exceeds max-input-bytes"}
			return
		}
		source = src.Resolved()
		parsed, err = ReadZipDirectory(src, before.Size, ZipCaps{
			MaxCentralDirectory: z.cap("max-central-directory-bytes"), MaxEntries: z.cap("max-entries"), MaxField: z.cap("max-field-bytes"),
		}, zipReportGuard(z.cap("max-report-bytes")))
		if err != nil {
			return
		}
		if metadata, err = parsed.Metadata(src); err != nil {
			return
		}
		if zipAfterInventory != nil {
			zipAfterInventory()
		}
		var after = before
		if after, err = src.Stat(); err == nil && !zipStatEqual(before, after) {
			err = &ZipError{Msg: "input changed while reading metadata"}
		}
	}()
	if err != nil {
		return err
	}
	stage, root, err := zipStage(parent, name)
	if err != nil {
		return err
	}
	published := false
	defer func() {
		_ = root.Close()
		if !published {
			_ = os.RemoveAll(stage)
		}
	}()
	if err := root.Mkdir("input", 0o700); err != nil {
		return err
	}
	digest := sha256.Sum256(metadata)
	if err := zipCreate(root, "input/central-directory.bin", metadata); err != nil {
		return err
	}
	if err := zipCreate(root, "stdout.txt", nil); err != nil {
		return err
	}
	if err := zipCreate(root, "stderr.txt", nil); err != nil {
		return err
	}
	report := zipParsed(parsed)
	report["schema"] = zipMetadataSchema
	report["input"] = map[string]any{"path": source, "size": before.Size, "metadata_sha256": "sha256:" + hex.EncodeToString(digest[:])}
	report["caps"] = map[string]any{
		"max_input_bytes": z.cap("max-input-bytes"), "max_central_directory_bytes": z.cap("max-central-directory-bytes"),
		"max_entries": z.cap("max-entries"), "max_field_bytes": z.cap("max-field-bytes"), "max_report_bytes": z.cap("max-report-bytes"),
	}
	report["payload_bytes_read"] = 0
	report["limitations"] = toAny(zipMetadataLimitations)
	payload, err := jsonout.CanonicalUnicode(report)
	if err != nil {
		return err
	}
	if int64(len(payload)) > z.cap("max-report-bytes") {
		return &ZipError{Msg: "canonical report exceeds max-report-bytes"}
	}
	if err := zipCreate(root, zipMetadataSchema+".json", payload); err != nil {
		return err
	}
	launcher, err := zipLauncher()
	if err != nil {
		return err
	}
	now := zipISONow(s.Clock())
	spec, err := jsonout.CanonicalUnicode(zipManifestSpec(manifestSpecArgs{
		tool: "zip-metadata", launcher: launcher, argv: []string{launcher, "formats", "zip-metadata", "--input", source, "--output", destination},
		inputPath: "input/central-directory.bin", detected: "ZIP central directory and EOCD metadata",
		outputs: []string{zipMetadataSchema + ".json"}, limitations: zipMetadataLimitations, profile: zipMetadataProfile, now: now,
	}))
	if err != nil {
		return err
	}
	if err := zipFinalize(s, stage, root, spec); err != nil {
		return err
	}
	if err := zipValidateTree(stage, map[string]bool{
		"input/central-directory.bin": true, "stdout.txt": true, "stderr.txt": true,
		zipMetadataSchema + ".json": true, "analysis-manifest.v1.json": true,
	}, nil); err != nil {
		return err
	}
	renamed, err := zipPublish(stage, destination, parent)
	published = renamed
	return err
}

func toAny(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

type manifestSpecArgs struct {
	tool, launcher       string
	argv                 []string
	inputPath, detected  string
	outputs, limitations []string
	profile, now         string
}

// zipManifestSpec is the analysis-manifest.v1 spec both commands hand to `analysis_manifest.py create`.
// The launcher is the rsdd binary itself, so tool.artifacts is empty: the legacy script and parser files
// no longer exist as separate artifacts.
func zipManifestSpec(a manifestSpecArgs) map[string]any {
	return map[string]any{
		"schema_version": "analysis-manifest.v1",
		"input":          map[string]any{"path": a.inputPath, "detected_type": a.detected},
		"tool":           map[string]any{"name": a.tool, "version": "1", "executable": a.launcher, "artifacts": []any{}},
		"argv":           toAny(a.argv), "environment": map[string]any{},
		"run":         map[string]any{"started_at": a.now, "ended_at": a.now, "duration_ms": 0, "exit_code": 0, "signal": nil},
		"stdout_path": "stdout.txt", "stderr_path": "stderr.txt", "outputs": toAny(a.outputs), "findings": []any{},
		"limitations": toAny(a.limitations), "errors": []any{}, "completeness": "complete",
		"isolation_profile": map[string]any{"name": a.profile, "static_only": true, "network_access": false, "target_execution": false},
	}
}
