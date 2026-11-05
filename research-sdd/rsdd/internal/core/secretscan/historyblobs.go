package secretscan

import (
	"bufio"
	"io"
	"sort"
	"strconv"
	"strings"
)

// Blob scan: one `cat-file --batch` process streams every unique in-scope blob once (the legacy script ran one
// process per blob); each blob is analysed with the same rules as a working-tree file.

// keyed is one report entry with the sort key the legacy `sort -u` used: the whole "path:line:content" line.
type keyed struct{ key, disp string }

// sortedUnique sorts by key (bytewise: the legacy relied on the caller's locale) and drops repeated keys.
func sortedUnique(in []keyed) []string {
	sort.Slice(in, func(i, j int) bool { return in[i].key < in[j].key })
	var out []string
	for i, k := range in {
		if i == 0 || k.key != in[i-1].key {
			out = append(out, k.disp)
		}
	}
	return out
}

func entry(path string, line int, content, disp string) keyed {
	return keyed{key: path + ":" + strconv.Itoa(line) + ":" + content, disp: disp + ":" + strconv.Itoa(line)}
}

// scanBlobs analyses every blob of the set and returns the committed findings. An object that cannot be read is
// DEGRADED: an empty read would otherwise look clean.
func (s *session) scanBlobs(blobs blobSet) (findings, *stop) {
	shas := make([]string, 0, len(blobs))
	for sha := range blobs {
		shas = append(shas, sha)
	}
	sort.Strings(shas)
	f := findings{leaks: make([][]string, len(rules))}
	if len(shas) == 0 {
		return f, nil
	}
	p, err := s.git.Start(s.abs, strings.NewReader(strings.Join(shas, "\n")+"\n"), "--no-replace-objects", "cat-file", "--batch")
	if err != nil {
		return f, s.fail(rcDegraded, "DEGRADED: git cat-file blob "+shas[0][:7]+" failed — committed blob scan aborted")
	}
	defer func() { _, _ = io.Copy(io.Discard, p.Stdout()); p.Wait() }()
	r := bufio.NewReaderSize(p.Stdout(), 1<<20)
	byRule := make([][]keyed, len(rules))
	var adv []keyed
	for _, sha := range shas {
		data, ok := readObject(r, sha)
		if !ok {
			return f, s.fail(rcDegraded, "DEGRADED: git cat-file blob "+sha[:7]+" failed — committed blob scan aborted")
		}
		path := blobs[sha]
		loc := path + "@" + sha[:7]
		a := analyze(data, analyzeOpts{keepContent: true, advisoryOnNUL: true})
		for _, h := range a.HC {
			byRule[h.Rule] = append(byRule[h.Rule], entry(loc, h.Line, h.Content, loc))
		}
		for _, h := range a.Adv {
			adv = append(adv, entry(path, h.Line, h.Content, path))
		}
	}
	for i := range byRule {
		f.leaks[i] = sortedUnique(byRule[i])
	}
	f.warns = sortedUnique(adv)
	return f, nil
}

// readObject reads one `cat-file --batch` response: "<sha> <type> <size>\n<content>\n", or "<sha> missing\n".
func readObject(r *bufio.Reader, sha string) ([]byte, bool) {
	head, err := r.ReadString('\n')
	if err != nil {
		return nil, false
	}
	f := strings.Fields(head)
	if len(f) != 3 || f[0] != sha || f[1] != "blob" {
		return nil, false
	}
	n, err := strconv.Atoi(f[2])
	if err != nil || n < 0 {
		return nil, false
	}
	buf := make([]byte, n+1) // the content and the LF the protocol appends
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, false
	}
	return buf[:n], true
}
