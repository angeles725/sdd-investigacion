package scoreloop

import (
	"encoding/json"
	"strings"
)

// lastParagraphOf is the last paragraph of the text of a record: .message.content when it is a string, else the
// "text" blocks of an array joined by newlines. A .message that is neither null nor an object, an array element that
// is neither null nor an object, or a text that is an array or object, is a shape error (jq could not read it).
func lastParagraphOf(obj map[string]any) (string, error) {
	var content any
	switch msg := obj["message"].(type) {
	case nil:
	case map[string]any:
		content = msg["content"]
	default:
		return "", errShape
	}
	switch c := content.(type) {
	case string:
		return lastParagraph(c), nil
	case []any:
		text, err := joinTextBlocks(c)
		return lastParagraph(text), err
	}
	return "", nil
}

func joinTextBlocks(blocks []any) (string, error) {
	var parts []string
	for _, b := range blocks {
		switch blk := b.(type) {
		case nil:
		case map[string]any:
			if blk["type"] != "text" {
				continue
			}
			s, err := jqJoinPart(blk["text"])
			if err != nil {
				return "", err
			}
			parts = append(parts, s)
		default:
			return "", errShape
		}
	}
	return strings.Join(parts, "\n"), nil
}

// jqJoinPart renders one value the way jq's join does: null is empty, scalars print as JSON, strings as themselves.
func jqJoinPart(v any) (string, error) {
	switch x := v.(type) {
	case nil:
		return "", nil
	case string:
		return x, nil
	case []any, map[string]any:
		return "", errShape
	}
	b, err := json.Marshal(v)
	return string(b), err
}

// lastParagraph is the last contiguous run of non-empty lines (a line of only blanks is not empty), or "".
func lastParagraph(text string) string {
	lines := strings.Split(text, "\n")
	end := len(lines) - 1
	for end >= 0 && lines[end] == "" {
		end--
	}
	if end < 0 {
		return ""
	}
	start := end
	for start > 0 && lines[start-1] != "" {
		start--
	}
	return strings.Join(lines[start:end+1], "\n")
}
