package formats

import (
	"cmp"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const (
	zipStoredSchema  = "zip-stored.v1"
	zipStoredProfile = "in-process-static-stored-copy"
)

var zipStoredLimitations = []string{"Classic single-disk, descriptor-free, unencrypted STORED regular files and directories only; no recovery, restoration, recursion, mounting, analysis, execution, or network access."}

// zipStoredCaps are the cap flags in the order the legacy parser declared them.
var zipStoredCaps = []capDef{
	{"max-input-bytes", 1073741824}, {"max-metadata-bytes", 16777216}, {"max-entries", 10000}, {"max-path-bytes", 4096},
	{"max-depth", 64}, {"max-entry-bytes", 1073741824}, {"max-total-bytes", 1073741824}, {"max-report-bytes", 16777216},
}

// storedEntry is one accepted entry: the central record, its payload location and what extraction learned.
type storedEntry struct {
	entry  *ZipEntry
	local  ZipLocal
	path   string
	dir    bool
	sha256 string
}

// stagedInput is what staging the source archive recorded.
type stagedInput struct {
	path, sha256 string
	size         int64
}

// stageChunk is how many bytes the next read may ask for: the buffer, but never more than one byte past the
// cap, so a source that grew is noticed without reading further than needed.
func stageChunk(bufLen, limit, total int64) int64 { return min(bufLen, limit-total+1) }

// stageInput copies the source into the stage as archive.zip through one descriptor, hashing it, and
// refuses a source that changed while it was copied or that is larger than limit.
func stageInput(source string, stage *os.Root, limit int64) (stagedInput, error) {
	src, before, err := zipOpenInput(source)
	if err != nil {
		return stagedInput{}, err
	}
	defer src.Close()
	if before.Size > limit {
		return stagedInput{}, &ZipError{Msg: "input exceeds max-input-bytes"}
	}
	resolved := src.Resolved()
	out, err := stage.OpenFile("archive.zip", os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o400)
	if err != nil {
		return stagedInput{}, err
	}
	defer out.Close()
	digest := sha256.New()
	var total int64
	buf := make([]byte, 1<<20)
	for {
		want := stageChunk(int64(len(buf)), limit, total)
		n, err := src.ReadAt(buf[:want], total)
		// n == 0 (the end of the file) runs through here as a no-op: nothing is added, hashed or written, and
		// total cannot exceed limit.
		total += int64(n)
		if total > limit {
			return stagedInput{}, &ZipError{Msg: "input exceeds max-input-bytes"}
		}
		digest.Write(buf[:n])
		if _, werr := out.Write(buf[:n]); werr != nil {
			return stagedInput{}, werr
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return stagedInput{}, err
		}
	}
	if err := out.Sync(); err != nil {
		return stagedInput{}, err
	}
	after, err := src.Stat()
	if err != nil {
		return stagedInput{}, err
	}
	if !zipStatEqual(before, after) || total != before.Size {
		return stagedInput{}, &ZipError{Msg: "input changed while staging"}
	}
	return stagedInput{path: resolved, size: total, sha256: "sha256:" + hex.EncodeToString(digest.Sum(nil))}, nil
}

func isSpecialRune(c rune) bool { return c < 32 || c == 127 }

// storedPathUnsafe is the legacy "unsafe entry path" predicate over a decoded name.
func storedPathUnsafe(name, plain string, parts []string) bool {
	if plain == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "\\") || strings.Contains(name, "\x00") || hasDrivePrefix(name, false) {
		return true
	}
	for _, p := range parts {
		if p == "" || p == "." || p == ".." || strings.IndexFunc(p, isSpecialRune) >= 0 {
			return true
		}
	}
	return zipNFC(name) != name
}

const (
	unixTypeMask = 0o170000
	unixDir      = 0o040000
	unixRegular  = 0o100000
)

// storedLimits are the caps inspect enforces.
type storedLimits struct {
	maxMetadata, maxEntries, maxPath, maxDepth, maxEntry, maxTotal, maxReport int64
}

// inspectStored is zip_stored.inspect: it admits the archive only if every entry is a plain STORED file or
// directory with agreeing central and local headers, in-range and non-overlapping payloads, and a safe,
// non-conflicting path. Nothing is extracted.
func inspectStored(r io.ReaderAt, size int64, lim storedLimits) (*ZipDirectory, []storedEntry, error) {
	dir, err := ReadZipDirectory(r, size, ZipCaps{MaxCentralDirectory: lim.maxMetadata, MaxEntries: lim.maxEntries, MaxField: lim.maxMetadata}, zipReportGuard(lim.maxReport))
	if err != nil {
		return nil, nil, err
	}
	var records []storedEntry
	var total int64
	paths := map[string]string{}
	declared := map[string]bool{}
	type span struct{ start, end int64 }
	var ranges []span
	for i := range dir.Entries {
		item := &dir.Entries[i]
		if int64(len(item.NameRaw)) > lim.maxPath {
			return nil, nil, &ZipError{Msg: "entry path exceeds max-path-bytes"}
		}
		name := item.Name
		if item.NameEncoding == "utf-8" {
			if !utf8.Valid(item.NameRaw) {
				return nil, nil, &ZipError{Msg: "entry name is not valid in its declared encoding"}
			}
		}
		isDir := strings.HasSuffix(name, "/")
		plain := name
		if isDir {
			plain = name[:len(name)-1]
		}
		parts := strings.Split(plain, "/")
		if storedPathUnsafe(name, plain, parts) {
			return nil, nil, &ZipError{Msg: "unsafe entry path"}
		}
		if int64(len(parts)) > lim.maxDepth {
			return nil, nil, &ZipError{Msg: "entry path exceeds max-depth"}
		}
		conflict := declared[plain] || (!isDir && paths[plain] != "")
		// The ancestors are parts[:1] .. parts[:len-1]; the entry's own path is never one of them (a
		// declared "file" at the full path is already the declared[plain] conflict above).
		ancestors := parts[:len(parts)-1]
		for j := range ancestors {
			conflict = conflict || paths[strings.Join(parts[:j+1], "/")] == "file"
		}
		if conflict {
			return nil, nil, &ZipError{Msg: "duplicate or ancestor path conflict"}
		}
		for j := range ancestors {
			if k := strings.Join(parts[:j+1], "/"); paths[k] == "" {
				paths[k] = "directory"
			}
		}
		kind := "file"
		if isDir {
			kind = "directory"
		}
		paths[plain], declared[plain] = kind, true
		madeHost, mode := item.MadeBy>>8, item.External>>16
		dosDir := item.External&0x10 != 0
		if madeHost == 3 {
			want := uint32(unixRegular)
			if isDir {
				want = unixDir
			}
			if mode&unixTypeMask != want {
				return nil, nil, &ZipError{Msg: "link or special entry attributes are unsupported"}
			}
		} else if dosDir != isDir || item.External&0x40 != 0 {
			return nil, nil, &ZipError{Msg: "inconsistent or special entry attributes"}
		}
		if item.Flags&(1|8) != 0 || item.Method != 0 {
			return nil, nil, &ZipError{Msg: "only unencrypted descriptor-free STORED entries are supported"}
		}
		if item.Compressed != item.Uncompressed || (isDir && item.Uncompressed != 0) {
			return nil, nil, &ZipError{Msg: "invalid STORED or directory size"}
		}
		if int64(item.Uncompressed) > lim.maxEntry {
			return nil, nil, &ZipError{Msg: "entry exceeds max-entry-bytes"}
		}
		total += int64(item.Uncompressed)
		if total > lim.maxTotal {
			return nil, nil, &ZipError{Msg: "extracted bytes exceed max-total-bytes"}
		}
		local, err := dir.ReadLocalHeader(r, item)
		if err != nil {
			return nil, nil, err
		}
		if local.Needed != item.Needed || local.Flags != item.Flags || local.Method != item.Method || local.DosTime != item.DosTime ||
			local.DosDate != item.DosDate || local.CRC32 != item.CRC32 || local.Compressed != item.Compressed ||
			local.Uncompressed != item.Uncompressed || string(local.NameRaw) != string(item.NameRaw) {
			return nil, nil, &ZipError{Msg: "central/local header mismatch"}
		}
		end := local.DataOffset + int64(local.Compressed)
		if end > dir.CentralOffset {
			return nil, nil, &ZipError{Msg: "payload range crosses central directory"}
		}
		ranges = append(ranges, span{dir.PrefixBytes + int64(item.LocalOffset), end})
		records = append(records, storedEntry{entry: item, local: local, path: name, dir: isDir})
	}
	// Two entries never share a start: equal local offsets mean one local header, so one raw name, which the
	// duplicate-path check above already rejected. Ordering by start alone is therefore total.
	slices.SortFunc(ranges, func(a, b span) int { return cmp.Compare(a.start, b.start) })
	for i := 1; i < len(ranges); i++ {
		if ranges[i].start < ranges[i-1].end {
			return nil, nil, &ZipError{Msg: "entry ranges overlap"}
		}
	}
	return dir, records, nil
}

// mkdirChain makes every directory of parts under root (mode 0700), tolerating existing ones.
func mkdirChain(root *os.Root, parts []string) error {
	for i := range parts {
		if err := root.Mkdir(strings.Join(parts[:i+1], "/"), 0o700); err != nil && !os.IsExist(err) {
			return err
		}
	}
	return nil
}

// extractStored writes every accepted entry under stage, creating files exclusively with mode 0400 and
// verifying each payload's CRC-32 through the zip member reader.
func extractStored(archive io.ReaderAt, dir *ZipDirectory, stage *os.Root, records []storedEntry) error {
	for i := range records {
		rec := &records[i]
		parts := strings.Split(strings.TrimRight(rec.path, "/"), "/")
		if rec.dir {
			if err := mkdirChain(stage, parts); err != nil {
				return err
			}
			continue
		}
		if err := mkdirChain(stage, parts[:len(parts)-1]); err != nil {
			return err
		}
		if err := extractFile(archive, dir, stage, rec, strings.Join(parts, "/")); err != nil {
			return err
		}
	}
	return nil
}

func extractFile(archive io.ReaderAt, dir *ZipDirectory, stage *os.Root, rec *storedEntry, rel string) error {
	out, err := stage.OpenFile(rel, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o400)
	if err != nil {
		return err
	}
	defer out.Close()
	rd, err := dir.OpenMember(archive, rec.entry, rec.local)
	if err != nil {
		return err
	}
	digest := sha256.New()
	if _, err := copyAll(io.MultiWriter(out, digest), rd); err != nil {
		return err
	}
	if err := out.Sync(); err != nil {
		return err
	}
	rec.sha256 = "sha256:" + hex.EncodeToString(digest.Sum(nil))
	return nil
}

// ZipStored is `rsdd formats zip-stored`: it extracts an entire classic single-disk ZIP made only of
// descriptor-free, unencrypted STORED regular files and directories into a new, closed, manifest-verified
// directory. Exit 0 is durable success, 2 means nothing was published, 3 means the rename happened but the
// parent-directory sync failed (uncertain durability).
func ZipStored(args []string, s cli.Stdio) int {
	z := newZipFlags("zip-stored", s, zipStoredCaps)
	if code := z.parse(args, s); code >= 0 {
		return code
	}
	renamedUnsynced, err := zipStoredRun(z, s)
	switch {
	case renamedUnsynced:
		fmt.Fprintf(s.Err, "DEGRADED: zip-stored: published with uncertain durability: %v\n", err)
		return cli.ExitDegraded
	case err != nil:
		fmt.Fprintf(s.Err, "zip-stored: %v\n", err)
		return cli.ExitUsage
	}
	return cli.ExitOK
}

func zipStoredRun(z *zipFlags, s cli.Stdio) (unsynced bool, err error) {
	if err := z.positive(); err != nil {
		return false, err
	}
	if err := zipRefusePrivileged(); err != nil {
		return false, err
	}
	parent, err := zipOutputParent(z.output, s.Cwd)
	if err != nil {
		return false, err
	}
	name := pyName(z.output)
	owned, err := zipOwnedParent(parent)
	if err != nil {
		return false, err
	}
	if !owned || name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\\") {
		return false, &ZipError{Msg: "unsafe output path"}
	}
	destination := parent + "/" + name
	if zipExists(destination) {
		return false, &ZipError{Msg: "output destination already exists"}
	}
	stage, root, err := zipStage(parent, name)
	if err != nil {
		return false, err
	}
	published := false
	defer func() {
		_ = root.Close()
		if !published {
			_ = os.RemoveAll(stage)
		}
	}()
	input := z.input
	if !strings.HasPrefix(input, "/") {
		input = s.Cwd + "/" + input
	}
	source, err := stageInput(input, root, z.cap("max-input-bytes"))
	if err != nil {
		return false, err
	}
	archive, err := root.Open("archive.zip")
	if err != nil {
		return false, err
	}
	dir, records, err := inspectStored(archive, source.size, storedLimits{
		maxMetadata: z.cap("max-metadata-bytes"), maxEntries: z.cap("max-entries"), maxPath: z.cap("max-path-bytes"), maxDepth: z.cap("max-depth"),
		maxEntry: z.cap("max-entry-bytes"), maxTotal: z.cap("max-total-bytes"), maxReport: z.cap("max-report-bytes"),
	})
	if err == nil {
		err = extractStored(archive, dir, root, records)
	}
	_ = archive.Close()
	if err != nil {
		return false, err
	}
	entries := make([]any, len(records))
	var extracted int64
	var outputs []string
	expectedFiles := map[string]bool{zipStoredSchema + ".json": true, "stdout.txt": true, "stderr.txt": true, "analysis-manifest.v1.json": true}
	expectedDirs := map[string]bool{}
	for i, rec := range records {
		m := map[string]any{
			"path": rec.path, "type": "file", "size": rec.entry.Uncompressed, "crc32": fmt.Sprintf("%08x", rec.entry.CRC32),
			"payload_offset": rec.local.DataOffset,
		}
		parts := strings.Split(strings.TrimRight(rec.path, "/"), "/")
		upto := len(parts)
		if rec.dir {
			m["type"] = "directory"
		} else {
			m["sha256"] = rec.sha256
			outputs = append(outputs, rec.path)
			expectedFiles[rec.path] = true
			upto--
		}
		for j := 1; j <= upto; j++ {
			expectedDirs[strings.Join(parts[:j], "/")] = true
		}
		extracted += int64(rec.entry.Uncompressed)
		entries[i] = m
	}
	caps := map[string]any{}
	for _, c := range zipStoredCaps {
		caps[strings.ReplaceAll(c.name, "-", "_")] = z.cap(c.name)
	}
	report := map[string]any{
		"schema": zipStoredSchema, "input": map[string]any{"path": source.path, "size": source.size, "sha256": source.sha256},
		"entries": entries, "caps": caps, "total_extracted_bytes": extracted, "limitations": toAny(zipStoredLimitations),
	}
	payload, err := jsonout.CanonicalUnicode(report)
	if err != nil {
		return false, err
	}
	if int64(len(payload)) > z.cap("max-report-bytes") {
		return false, &ZipError{Msg: "canonical report exceeds max-report-bytes"}
	}
	for _, f := range []struct {
		name string
		data []byte
	}{{zipStoredSchema + ".json", payload}, {"stdout.txt", nil}, {"stderr.txt", nil}} {
		if err := zipCreate(root, f.name, f.data); err != nil {
			return false, err
		}
	}
	if err := root.Remove("archive.zip"); err != nil {
		return false, err
	}
	launcher, err := zipLauncher()
	if err != nil {
		return false, err
	}
	spec, err := jsonout.CanonicalUnicode(zipManifestSpec(manifestSpecArgs{
		tool: "zip-stored", launcher: launcher, argv: []string{launcher, "formats", "zip-stored", "--input", source.path, "--output", destination},
		inputPath: zipStoredSchema + ".json", detected: "ZIP STORED extraction report with source SHA-256",
		outputs: outputs, limitations: zipStoredLimitations, profile: zipStoredProfile, now: zipISONow(s.Clock()),
	}))
	if err != nil {
		return false, err
	}
	if err := zipFinalize(s, z.manifest, stage, root, spec); err != nil {
		return false, err
	}
	if err := zipValidateTree(stage, expectedFiles, expectedDirs); err != nil {
		return false, err
	}
	renamed, err := zipPublish(stage, destination, parent)
	published = renamed
	return renamed && err != nil, err
}
