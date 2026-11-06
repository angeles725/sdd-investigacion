package cleancheck

import (
	"bytes"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// manifestName is the preservation record: its rows name scripts on purpose, so it is never a citing block.
const manifestName = "SCRIPTS-MANIFEST.md"

// listBlocks lists the .md files of the target, tracked or untracked, that can cite a scratchpad file: not the
// manifests, not the scratchpad's own. A listed file that is gone from the work tree (tracked, then deleted) is
// counted, never a crash.
func (r *run) listBlocks() (blocks []string, missing int, ok bool) {
	g := r.git("ls-files", "-co", "--exclude-standard", "-z", "--", "*.md")
	r.passthrough(g.err)
	if g.rc != 0 {
		return nil, 0, r.refuse("git ls-files failed or was truncated listing blocks in " + r.target)
	}
	for _, rel := range nulFields(g.out) {
		if rel[strings.LastIndex(rel, "/")+1:] == manifestName || r.inScratch(r.targetP+"/"+rel) {
			continue
		}
		if fi, err := os.Stat(r.targetP + "/" + rel); err != nil || !fi.Mode().IsRegular() {
			missing++
			continue
		}
		blocks = append(blocks, rel)
	}
	return blocks, missing, true
}

// blockReader finds the first block, in listing order, that mentions a file name. Each block is read once.
type blockReader struct {
	r      *run
	blocks []string
	cache  map[string][]byte
}

// firstCiting is the first block that mentions base, or "" when none does. A block that cannot be read ends the run
// (ok false): a quiet "not cited" would hide lost evidence.
func (b *blockReader) firstCiting(base string) (citer string, ok bool) {
	for _, rel := range b.blocks {
		body, cached := b.cache[rel]
		if !cached {
			var err error
			if body, err = os.ReadFile(b.r.targetP + "/" + rel); err != nil {
				b.r.stderr("grep: " + b.r.targetP + "/" + rel + ": " + newFindError("", err).reason)
				return "", b.r.refuse("grep failed reading block " + rel)
			}
			if b.cache == nil {
				b.cache = map[string][]byte{}
			}
			b.cache[rel] = body
		}
		if mentions(base, body) {
			return rel, true
		}
	}
	return "", true
}

// mentions reports whether some line of body holds name as a whole path component, never as a bare substring (run.sh
// is not prerun.sh, out is not layout). Before it: the start of the line, or / blank ` ( " ' | < > [ ]. After it:
// the end of the line, or blank ` ) " ' , : ; ! ? | < > [ ], or a . that ends the sentence (end of line or blank).
func mentions(name string, body []byte) bool {
	needle := []byte(name)
	for _, line := range bytes.Split(body, []byte("\n")) {
		for from := 0; ; {
			i := bytes.Index(line[from:], needle)
			if i < 0 {
				break
			}
			i += from
			if goodBefore(line, i) && goodAfter(line, i+len(needle)) {
				return true
			}
			from = i + 1
		}
	}
	return false
}

const (
	beforeChars = "[]/`(\"'|<>" + shellx.WsClass
	afterChars  = "[]`)\"',:;!?|<>" + shellx.WsClass
)

func goodBefore(line []byte, at int) bool {
	return at == 0 || strings.IndexByte(beforeChars, line[at-1]) >= 0
}

func goodAfter(line []byte, at int) bool {
	if at == len(line) || strings.IndexByte(afterChars, line[at]) >= 0 {
		return true
	}
	return line[at] == '.' && (at+1 == len(line) || strings.IndexByte(shellx.WsClass, line[at+1]) >= 0)
}
