package loopevidence

import (
	"bytes"
	"encoding/json"
	"path"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// needles are the cheap byte filters run before any JSON decode: a transcript of a long session is mostly tool
// calls, and only those naming the loop's instrument, skill, block files or state files can be evidence.
var needles = [][]byte{[]byte("research-sdd"), []byte("rsdd"), []byte("-block"), []byte("-bloque"), []byte("RESEARCH-STATE")}

var (
	toolUseMarker = []byte("tool_use")
	slashMarker   = []byte("<command-name>")
	reSlash       = regexp.MustCompile(`<command-name>/?research-sdd</command-name>`)
)

// skippedDirs are path segments whose files are test material or templates, never a session's research output.
var skippedDirs = map[string]bool{"fixtures": true, "testdata": true, "templates": true, "node_modules": true, ".git": true}

type entry struct {
	Type    string `json:"type"`
	Message struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type block struct {
	Type  string          `json:"type"`
	Name  string          `json:"name"`
	Text  string          `json:"text"`
	Input json.RawMessage `json:"input"`
}

type toolInput struct {
	Command  string `json:"command"`
	FilePath string `json:"file_path"`
	Path     string `json:"path"`
	Skill    string `json:"skill"`
}

// Classify reports the evidence one transcript line carries. A line that is not one JSON object, or whose shape is
// not the one a rule reads, carries none (the gate never guesses from prose).
func Classify(line []byte, o Options) (Evidence, bool) {
	isTool := bytes.Contains(line, toolUseMarker) && containsAny(line, needles)
	isSlash := bytes.Contains(line, slashMarker)
	if !isTool && !isSlash {
		return Evidence{}, false
	}
	var e entry
	if json.Unmarshal(line, &e) != nil {
		return Evidence{}, false
	}
	content := bytes.TrimSpace(e.Message.Content)
	switch {
	case e.Type == "user" && isSlash:
		return slashEvidence(content)
	case e.Type == "assistant" && isTool && bytes.HasPrefix(content, []byte("[")):
		var blocks []json.RawMessage
		if json.Unmarshal(content, &blocks) != nil {
			return Evidence{}, false
		}
		for _, raw := range blocks {
			if ev, ok := toolEvidence(raw, o); ok {
				return ev, true
			}
		}
	}
	return Evidence{}, false
}

func containsAny(b []byte, ns [][]byte) bool {
	for _, n := range ns {
		if bytes.Contains(b, n) {
			return true
		}
	}
	return false
}

// slashEvidence: the user message (a string, or text blocks, never a tool_result) holds the /research-sdd command tag.
func slashEvidence(content []byte) (Evidence, bool) {
	var texts []string
	if bytes.HasPrefix(content, []byte(`"`)) {
		var s string
		if json.Unmarshal(content, &s) == nil {
			texts = append(texts, s)
		}
	} else if bytes.HasPrefix(content, []byte("[")) {
		var blocks []block
		if json.Unmarshal(content, &blocks) == nil {
			for _, b := range blocks {
				if b.Type == "text" {
					texts = append(texts, b.Text)
				}
			}
		}
	}
	for _, t := range texts {
		if m := reSlash.FindString(t); m != "" {
			return Evidence{Kind: KindSlashCommand, Detail: m}, true
		}
	}
	return Evidence{}, false
}

func toolEvidence(raw json.RawMessage, o Options) (Evidence, bool) {
	var b block
	if json.Unmarshal(raw, &b) != nil || b.Type != "tool_use" {
		return Evidence{}, false
	}
	var in toolInput
	if json.Unmarshal(b.Input, &in) != nil {
		return Evidence{}, false
	}
	switch strings.ToLower(b.Name) {
	case "bash":
		if runsStatus(in.Command, o.Target) {
			return Evidence{Kind: KindStatusRun, Detail: excerpt(in.Command)}, true
		}
	case "write", "edit", "multiedit", "notebookedit":
		p := in.FilePath
		if p == "" {
			p = in.Path
		}
		if k, ok := writeKind(p, o.Target); ok {
			return Evidence{Kind: k, Detail: excerpt(p)}, true
		}
	case "skill":
		if in.Skill == "research-sdd" || strings.HasSuffix(in.Skill, ":research-sdd") {
			return Evidence{Kind: KindSkill, Detail: in.Skill}, true
		}
	}
	return Evidence{}, false
}

// writeKind classifies a written path: a block file (kit.FilterBlockFiles is the one block-name rule) or a state
// file (kit.IsStateFileName), inside the target and outside test material and templates.
func writeKind(p, target string) (Kind, bool) {
	if p == "" || !underTarget(p, target) {
		return "", false
	}
	for _, seg := range strings.Split(p, "/") {
		if skippedDirs[seg] {
			return "", false
		}
	}
	if kit.IsStateFileName(path.Base(p)) {
		return KindStateWrite, true
	}
	if _, err := kit.FilterBlockFiles([]string{p}, false, ""); err == nil {
		return KindBlockWrite, true
	}
	return "", false
}

// underTarget: a relative path resolves against the session cwd, which is the target, so it counts.
func underTarget(p, target string) bool {
	if target == "" || !strings.HasPrefix(p, "/") {
		return true
	}
	t := strings.TrimRight(target, "/")
	c := path.Clean(p)
	return c == t || strings.HasPrefix(c, t+"/")
}

// related: a path names the target, a directory below it, or a directory that holds it. Used for the arguments of
// a status run, which are corpus directories.
func related(p, target string) bool {
	t := strings.TrimRight(target, "/")
	c := strings.TrimRight(path.Clean(p), "/")
	return c == t || strings.HasPrefix(c, t+"/") || strings.HasPrefix(t, c+"/")
}

const maxExcerpt = 200

func excerpt(s string) string {
	if len(s) > maxExcerpt {
		return s[:maxExcerpt] + "…"
	}
	return s
}
