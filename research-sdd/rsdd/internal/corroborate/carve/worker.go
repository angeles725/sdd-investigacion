package carve

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// limitations is the report's fixed caveat list.
var limitations = []string{
	"Bubblewrap is defense in depth, not a hostile-parser security boundary; use a disposable VM for hostile firmware.",
	"Carving validates only uImage CRCs and the SquashFS v4 little-endian structural byte range; it does not validate filesystem contents.",
}

// isolation is the report's fixed isolation claim; the parent refuses a report that says anything else.
func isolation() map[string]any {
	return map[string]any{"bubblewrap": true, "network_access": false, "payload_execution": false, "static_only": true, "vm_boundary": false}
}

// inputRecord is the identity of the staged input the parent measured and the worker must re-measure.
type inputRecord struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

func (r inputRecord) object() map[string]any {
	return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
}

// carveRecord is one carved range as the report lists it.
type carveRecord struct {
	Kind   string
	Offset int64
	Size   int64
	Path   string
	SHA256 string
}

func (c carveRecord) object() map[string]any {
	return map[string]any{"kind": c.Kind, "offset": c.Offset, "size": c.Size, "path": c.Path, "sha256": c.SHA256}
}

// carvePath is the logical path of a carve: offset in eight hex digits, then the kind.
func carvePath(offset int64, kind string) string {
	return fmt.Sprintf("carves/%08x-%s.bin", offset, kind)
}

// capsObject is the report's caps block (and what the parent expects it to say).
func capsObject(c config) map[string]any {
	return map[string]any{
		"max_input_bytes": c.maxInput, "max_output_bytes": c.maxOutput, "max_carves": c.maxCarves, "max_files": c.maxFiles,
		"timeout_seconds": c.timeout, "max_processes": c.maxProcs, "max_memory_bytes": c.maxMemory,
	}
}

// runWorker is the in-sandbox half: re-measure the staged input, find the validated ranges, write each into
// stage/carves and the canonical report next to them. Every file is created exclusively and read-only.
func runWorker(c config, euid uint64) error {
	stage := filepath.Clean(c.stage)
	source := filepath.Join(stage, "input.bin")
	f, err := openNoFollow(source)
	if err != nil {
		return err
	}
	defer f.Close()
	meta, err := f.Stat()
	if err != nil {
		return err
	}
	if !stagedFile(meta, euid) {
		return errStagedType
	}
	var want inputRecord
	if err := json.Unmarshal([]byte(c.inputRecord), &want); err != nil {
		return err
	}
	size := meta.Size()
	if size == 0 {
		return errors.New("cannot mmap an empty file") // the message the script's mmap raised for an empty input
	}
	h := sha256.New()
	if _, err := io.Copy(h, io.NewSectionReader(f, 0, size)); err != nil {
		return err
	}
	if size != want.Size || "sha256:"+hex.EncodeToString(h.Sum(nil)) != want.SHA256 {
		return errors.New("staged input identity mismatch")
	}
	found, err := findCandidates(f, size, caps{c.maxCarves, c.maxFiles, c.maxOutput})
	if err != nil {
		return err
	}
	if len(found) == 0 {
		return errors.New("no validated supported image found")
	}
	if err := os.Mkdir(filepath.Join(stage, "carves"), 0o700); err != nil {
		return err
	}
	records := make([]any, 0, len(found))
	for _, item := range found {
		rec, err := writeCarve(stage, f, item)
		if err != nil {
			return err
		}
		records = append(records, rec.object())
	}
	report := map[string]any{
		"schema": schema, "input": want.object(), "carves": records, "caps": capsObject(c),
		"isolation": isolation(), "isolation_artifact": map[string]any{"path": c.bwrapPath, "sha256": c.bwrapSHA},
		"limitations": []any{limitations[0], limitations[1]},
	}
	payload, err := jsonout.Canonical(report)
	if err != nil {
		return err
	}
	if err := writeExclusive(filepath.Join(stage, schema+".json"), bytes.NewReader(payload), nil); err != nil {
		return err
	}
	beforeFinalStat()
	after, err := f.Stat()
	if err != nil {
		return err
	}
	if tupleOf(meta) != tupleOf(after) {
		return errors.New("staged input changed while carving")
	}
	return nil
}

// writeCarve copies one range into its read-only file and returns its record.
func writeCarve(stage string, src io.ReaderAt, item candidate) (carveRecord, error) {
	rel := carvePath(item.start, item.kind)
	digest := sha256.New()
	if err := writeExclusive(filepath.Join(stage, rel), io.NewSectionReader(src, item.start, item.end-item.start), digest); err != nil {
		return carveRecord{}, err
	}
	return carveRecord{item.kind, item.start, item.end - item.start, rel, "sha256:" + hex.EncodeToString(digest.Sum(nil))}, nil
}

// writeExclusive creates path (O_EXCL, mode 0400), copies r into it (also into tee when given), and syncs it.
func writeExclusive(path string, r io.Reader, tee io.Writer) error {
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o400)
	if err != nil {
		return err
	}
	var w io.Writer = out
	if tee != nil {
		w = io.MultiWriter(out, tee)
	}
	_, err = io.Copy(w, r)
	if err == nil {
		err = out.Sync()
	}
	return errors.Join(err, out.Close())
}

// errStagedType is the refusal for a staged file that is not a regular, owned, 0400 file.
// beforeFinalStat runs between publishing the report and the final identity check of the staged input. It is a
// no-op; tests replace it to change the input at that exact point instead of racing the worker.
var beforeFinalStat = func() {}

var errStagedType = errors.New("staged input type, owner, or mode changed")

// stagedFile is the type, owner and mode every staged file must still have.
func stagedFile(fi os.FileInfo, euid uint64) bool {
	uid, _, ok := owner(fi)
	return fi.Mode().IsRegular() && ok && uid == euid && fi.Mode().Perm() == 0o400 && fi.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) == 0
}
