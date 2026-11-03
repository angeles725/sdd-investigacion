package formats

import (
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of toolbelt/squashfs_extract.py (kit issue #2417, epic #2270): safe SquashFS extraction. The input is
// staged (no symlink, size capped), its superblock is validated, unsquashfs runs inside bubblewrap under a
// wall-clock timeout, a per-file RLIMIT_FSIZE and an aggregate size watchdog, and the extracted tree is
// validated (no symlink, special file or hardlink; per-file sha256) before one evidence directory is
// published without replacing anything.
//
// The superblock scan and the argument handling are portable; the extraction itself is unix only
// (squashfs_unix.go; squashfs_other.go reports the command as unavailable elsewhere).

const (
	sqfsSchema           = "squashfs-extract.v1"
	sqfsSBSize           = 96
	sqfsFlagExportable   = 0x80
	sqfsNoTable          = ^uint64(0) // the "table absent" sentinel
	sqfsScanChunk        = 1 << 20
	sqfsScanOverlap      = 3 // len(sqfsMagic) - 1
	sqfsNoSuperblock     = "no valid SquashFS v4 LE superblock found in input"
	defaultMaxInputBytes = 512 * 1024 * 1024
	defaultMaxExtracted  = 256 * 1024 * 1024
	defaultMaxEntries    = 10_000
	defaultTimeoutSecs   = 120
)

var sqfsMagic = []byte("hsqs") // SquashFS v4 LE magic (0x73717368 little-endian)

// sqfsError is a SquashExtractError: a refusal with the exact Python message.
type sqfsError struct{ msg string }

func (e *sqfsError) Error() string { return e.msg }

func sqfsErrf(format string, a ...any) error { return &sqfsError{fmt.Sprintf(format, a...)} }

// sqfsValidSuperblock is the superblock test of find_squashfs_offset, applied to the 96 bytes at offset in a
// file of the given size: magic + struct fields + bounds.
func sqfsValidSuperblock(sb []byte, offset, size int64) bool {
	le := binary.LittleEndian
	inodes, block, fragments := le.Uint32(sb[4:]), le.Uint32(sb[12:]), le.Uint32(sb[16:])
	compression, log, flags := le.Uint16(sb[20:]), le.Uint16(sb[22:]), le.Uint16(sb[24:])
	ids, major, minor := le.Uint16(sb[26:]), le.Uint16(sb[28:]), le.Uint16(sb[30:])
	used := le.Uint64(sb[40:])
	idTable, xattr, inodeTable := le.Uint64(sb[48:]), le.Uint64(sb[56:]), le.Uint64(sb[64:])
	dirTable, fragTable, exportTable := le.Uint64(sb[72:]), le.Uint64(sb[80:]), le.Uint64(sb[88:])

	validTable := func(x uint64) bool { return x == sqfsNoTable || (sqfsSBSize <= x && x < used) }
	required := []uint64{idTable, inodeTable, dirTable}
	if fragments != 0 {
		required = append(required, fragTable)
	}
	if flags&sqfsFlagExportable != 0 {
		required = append(required, exportTable)
	}
	if inodes == 0 || ids == 0 || major != 4 || minor != 0 || compression < 1 || compression > 6 {
		return false
	}
	// block == 1 << log, with log a uint16. log needs no range check of its own: a shift count of 32..63 gives a
	// value no uint32 equals, and 64 or more gives 0, which the block >= 4096 bound refuses.
	if uint64(block) != 1<<log || block < 4096 || block > 1048576 {
		return false
	}
	// offset + used <= size. used <= 96 needs no check of its own: the required tables must lie in [96, used),
	// which is empty then, so the table checks below refuse it.
	if used > uint64(size-offset) {
		return false
	}
	for _, x := range []uint64{idTable, xattr, inodeTable, dirTable, fragTable, exportTable} {
		if !validTable(x) {
			return false
		}
	}
	for _, x := range required {
		if x == sqfsNoTable {
			return false
		}
	}
	return true
}

// findSquashfsOffset returns the offset of the first valid SquashFS v4 LE superblock in the size bytes behind
// r. Every position holding the magic is a candidate, in order; a failed candidate resumes the search one byte
// later. The scan streams in 1 MiB chunks (the script maps the whole file), so memory stays bounded.
func findSquashfsOffset(r io.ReaderAt, size int64) (int64, error) {
	// Sized to the input, not the chunk: a small input must not pay a 1 MiB buffer per call.
	// The window is sqfsScanOverlap bytes longer than the chunk so a magic that starts in the chunk and ends in
	// the next one is still seen; no candidate can start at or past the chunk end, so none is seen twice.
	buf := make([]byte, min(int64(sqfsScanChunk), max(size, 0))+sqfsScanOverlap)
	sb := make([]byte, sqfsSBSize)
	for base := int64(0); base < size; base += sqfsScanChunk {
		n, err := r.ReadAt(buf, base)
		if err != nil && !errors.Is(err, io.EOF) {
			return -1, err
		}
		window := buf[:n]
		for from := 0; ; {
			j := bytes.Index(window[from:], sqfsMagic)
			if j < 0 {
				break
			}
			pos := from + j
			offset := base + int64(pos)
			// A candidate within 96 bytes of the end reads short and is refused here.
			if got, err := r.ReadAt(sb, offset); got == sqfsSBSize && (err == nil || errors.Is(err, io.EOF)) &&
				sqfsValidSuperblock(sb, offset, size) {
				return offset, nil
			}
			from = pos + 1
		}
	}
	return -1, &sqfsError{sqfsNoSuperblock}
}

// ---------------------------------------------------------------- arguments

type squashfsOpts struct {
	input, output, manifestCLI       string
	maxInput, maxExtracted, maxEntry int64
	timeoutSeconds                   int64
}

const squashfsUsage = `usage: squashfs-extract --input INPUT --output OUTPUT [--manifest-cli MANIFEST_CLI]
                       [--max-input-bytes N] [--max-extracted-bytes N] [--max-entries N]
                       [--timeout-seconds N]

Safe SquashFS extraction with post-extraction tree validation.

  --input             SquashFS image or firmware blob containing one
  --output            evidence directory to publish (must not exist; its parent must be private)
  --manifest-cli      accepted and ignored (the manifest is built in process)
  --max-input-bytes   input size cap (default 536870912)
  --max-extracted-bytes  aggregate extracted size cap (default 268435456)
  --max-entries       tree entry cap (default 10000)
  --timeout-seconds   unsquashfs wall-clock cap (default 120)
`

func parseSquashfsArgs(args []string, s cli.Stdio) (a squashfsOpts, code int, done bool) {
	fs := flag.NewFlagSet("squashfs-extract", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&a.input, "input", "", "")
	fs.StringVar(&a.output, "output", "", "")
	fs.StringVar(&a.manifestCLI, "manifest-cli", "", "")
	fs.Int64Var(&a.maxInput, "max-input-bytes", defaultMaxInputBytes, "")
	fs.Int64Var(&a.maxExtracted, "max-extracted-bytes", defaultMaxExtracted, "")
	fs.Int64Var(&a.maxEntry, "max-entries", defaultMaxEntries, "")
	fs.Int64Var(&a.timeoutSeconds, "timeout-seconds", defaultTimeoutSecs, "")
	usageErr := func(format string, v ...any) (squashfsOpts, int, bool) {
		fmt.Fprint(s.Err, squashfsUsage)
		fmt.Fprintf(s.Err, "squashfs-extract: error: "+format+"\n", v...)
		return a, cli.ExitUsage, true
	}
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(s.Out, squashfsUsage)
			return a, cli.ExitOK, true
		}
		return usageErr("%v", err)
	}
	if fs.NArg() > 0 {
		return usageErr("unrecognized arguments: %v", fs.Args())
	}
	given := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { given[f.Name] = true })
	for _, name := range []string{"input", "output"} {
		if !given[name] {
			return usageErr("the following arguments are required: --%s", name)
		}
	}
	return a, 0, false
}

// minPositive reports whether every cap is at least 1.
func capsPositive(a squashfsOpts) bool {
	return min(a.maxInput, a.maxExtracted, a.maxEntry, a.timeoutSeconds) >= 1
}

// clampSeconds keeps a huge --timeout-seconds from overflowing a time.Duration.
func clampSeconds(n int64) int64 { return min(n, math.MaxInt32) }
