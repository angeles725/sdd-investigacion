package pcap

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"sort"
	"strings"
	"unicode/utf8"
)

// Parsers for what capinfos and tshark print. Each is a pure function of the text, so both commands and every
// test share them.

// parseCapinfos reads capinfos' "Key: value" lines. A later duplicate key wins; a missing or empty value
// reads as zero; the first unparseable field (duration, data size, file size, packets, in that order) is the
// error, naming its token the way Python's int()/float() do.
func parseCapinfos(text string) (capSummary, error) {
	kv := map[string]string{}
	for _, line := range pySplitlines(text) {
		if k, v, ok := strings.Cut(line, ":"); ok {
			kv[pyStrip(k)] = pyStrip(v)
		}
	}
	first := func(key string) (string, bool) {
		val, ok := kv[key]
		if !ok {
			val = "0"
		}
		f := pyFields(val)
		if len(f) == 0 {
			return "", false
		}
		return f[0], true
	}
	unparseable := func(detail string) error {
		return errors.New("capinfos output unparseable: " + detail)
	}
	asInt := func(key string) (*big.Int, error) {
		tok, ok := first(key)
		if !ok {
			return new(big.Int), nil
		}
		n, good := parseInt(tok)
		if !good {
			return nil, unparseable("invalid literal for int() with base 10: " + pyRepr(tok))
		}
		return n, nil
	}
	var s capSummary
	if tok, ok := first("Capture duration"); ok {
		f, good := parseFloat(tok)
		if !good {
			return capSummary{}, unparseable("could not convert string to float: " + pyRepr(tok))
		}
		s.DurationSeconds = f
	}
	var err error
	if s.DataSize, err = asInt("Data size"); err != nil {
		return capSummary{}, err
	}
	s.Encapsulation = "unknown"
	if v, ok := kv["File encapsulation"]; ok {
		s.Encapsulation = v
	}
	if s.FileSize, err = asInt("File size"); err != nil {
		return capSummary{}, err
	}
	if s.Packets, err = asInt("Number of packets"); err != nil {
		return capSummary{}, err
	}
	return s, nil
}

// leadingSpace splits line into its leading white space and the rest.
func leadingSpace(line string) (string, string) {
	rest := pyLstrip(line)
	return line[:len(line)-len(rest)], rest
}

// digitsAfter reads the ASCII digits at the start of s.
func digitsAfter(s string) (digits, rest string) {
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		n++
	}
	return s[:n], s[n:]
}

// parseHierarchy reads tshark -z io,phs: between the two "===" rules, "<proto> frames:N bytes:N" lines indented
// two spaces per level. The rows come back sorted by (level, protocol), the input order breaking ties.
func parseHierarchy(text string) []protocolRow {
	var rows []protocolRow
	inSection := false
	for _, line := range pySplitlines(text) {
		if strings.Contains(line, "===") {
			inSection = !inSection
			continue
		}
		if !inSection {
			continue
		}
		indent, rest := leadingSpace(line)
		end := strings.IndexFunc(rest, isSpace)
		if end <= 0 {
			continue
		}
		proto := rest[:end]
		frames, after, ok := labelled(pyLstrip(rest[end:]), "frames:")
		if !ok || len(pyLstrip(after)) == len(after) {
			continue
		}
		bytes, _, ok := labelled(pyLstrip(after), "bytes:")
		if !ok {
			continue
		}
		rows = append(rows, protocolRow{
			Protocol: proto, Level: utf8.RuneCountInString(indent) / 2,
			Frames: number(frames), Bytes: number(bytes),
		})
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].Level != rows[j].Level {
			return rows[i].Level < rows[j].Level
		}
		return rows[i].Protocol < rows[j].Protocol
	})
	return rows
}

// labelled reads prefix followed by ASCII digits at the start of s.
func labelled(s, prefix string) (digits, rest string, ok bool) {
	after, found := strings.CutPrefix(s, prefix)
	if !found {
		return "", s, false
	}
	digits, rest = digitsAfter(after)
	return digits, rest, digits != ""
}

// parseConversations extracts one protocol's rows from the combined tshark -z conv output. Sections are
// bounded by "===" rules and rows contain "<->". After the endpoint pair tshark interleaves the word "bytes"
// and float timestamps with the counters, so only pure-integer tokens are read:
// frames_b2a bytes_b2a frames_a2b bytes_a2b frames_total bytes_total. Endpoints are put in canonical order (the
// smaller string first) and the directional counters swap with them.
func parseConversations(text, proto string) []conversation {
	target := strings.ToUpper(proto) + " Conversations"
	var rows []conversation
	inSection, inRight := false, false
	for _, line := range pySplitlines(text) {
		if strings.Contains(line, "===") {
			if inSection && inRight {
				break
			}
			inSection = !inSection
			if !inSection {
				inRight = false
			}
			continue
		}
		if inSection && !inRight {
			if strings.Contains(line, target) {
				inRight = true
			}
			continue
		}
		if !(inSection && inRight) || !strings.Contains(line, "<->") {
			continue
		}
		left, right, _ := strings.Cut(line, "<->")
		a := pyStrip(left)
		right = pyLstrip(right)
		b, rest := right, ""
		if i := strings.IndexFunc(right, isSpace); i >= 0 {
			b, rest = right[:i], right[i:]
		}
		var nums []string
		for _, tok := range pyFields(strings.ReplaceAll(rest, "|", " ")) {
			if asciiDigits(tok) {
				nums = append(nums, tok)
			}
		}
		if len(nums) < 6 {
			continue
		}
		if a > b {
			a, b = b, a
			nums[0], nums[1], nums[2], nums[3] = nums[2], nums[3], nums[0], nums[1]
		}
		rows = append(rows, conversation{
			EndpointA: a, EndpointB: b,
			FramesB2A: number(nums[0]), BytesB2A: number(nums[1]), FramesA2B: number(nums[2]), BytesA2B: number(nums[3]),
			FramesTotal: number(nums[4]), BytesTotal: number(nums[5]),
		})
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].EndpointA != rows[j].EndpointA {
			return rows[i].EndpointA < rows[j].EndpointA
		}
		return rows[i].EndpointB < rows[j].EndpointB
	})
	return rows
}

// parseFollow reads tshark -z follow,tcp,raw,N and hashes the reassembled payload. Between the "===" rules,
// "Node 0:" / "Node 1:" lines name the endpoints, hex lines without a leading tab are client to server and
// tab-indented ones server to client. The digest covers every byte in encounter order; the bytes themselves
// are never kept. A hex line that does not decode marks the payload incomplete.
func parseFollow(text string, index json.Number) streamFollow {
	f := streamFollow{Index: index, Complete: true}
	h := sha256.New()
	active := false
	feed := func(line string, count *int) {
		raw, ok := fromHex(pyStrip(line))
		if !ok {
			f.Complete = false
			return
		}
		h.Write(raw)
		*count += len(raw)
	}
	for _, line := range pySplitlines(text) {
		if strings.Contains(line, "===") {
			if active {
				break
			}
			active = true
			continue
		}
		if !active {
			continue
		}
		switch {
		case strings.HasPrefix(line, "Node 0:"):
			f.Client = pyStrip(line[len("Node 0:"):])
		case strings.HasPrefix(line, "Node 1:"):
			f.Server = pyStrip(line[len("Node 1:"):])
		case strings.HasPrefix(line, "\t"):
			feed(line, &f.ServerBytes)
		case isHexDigits(pyStrip(line)):
			feed(line, &f.ClientBytes)
		}
	}
	f.SHA256 = "sha256:" + hex.EncodeToString(h.Sum(nil))
	return f
}
