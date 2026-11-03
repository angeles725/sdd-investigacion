package gaprows

import "strings"

// continuationMax is how many lines after the bullet line belong to the bullet.
const continuationMax = 7

// Bullets indexes the gap bullets of one block file. A gap bullet is a line `- **B<n>-G<m>` / `* **[B<n>-G<m>` (the
// forms `- **B1-G2** text`, `- **[B1-G2]** text`, `- **B1-G2 (state, note)** text` and `- **B1-G2**: text`).
type Bullets struct {
	lines []string
	first map[string]int // id -> index of the first line that defines it
}

// ParseBullets indexes src once; Text then answers any number of ids.
func ParseBullets(src string) *Bullets {
	b := &Bullets{first: map[string]int{}}
	if src == "" {
		return b
	}
	b.lines = strings.Split(strings.TrimSuffix(src, "\n"), "\n")
	for i, l := range b.lines {
		l = strings.TrimSuffix(l, "\r")
		b.lines[i] = l
		if id, ok := bulletID(l); ok {
			if _, seen := b.first[id]; !seen {
				b.first[id] = i
			}
		}
	}
	return b
}

// Text is gap_bullet_text: the first line defining id plus up to seven continuation lines (the run stops at the next
// gap bullet, a heading or a blank line), joined with single spaces. found is false when the block file defines no
// such bullet; B4-G1 never matches B4-G10.
func (b *Bullets) Text(id string) (text string, found bool) {
	i, ok := b.first[id]
	if !ok {
		return "", false
	}
	body := b.lines[i]
	for k, j := 0, i+1; k < continuationMax && j < len(b.lines); k, j = k+1, j+1 {
		l := b.lines[j]
		if _, isBullet := bulletID(l); isBullet || strings.HasPrefix(l, "#") || strings.Trim(l, " \t") == "" {
			break
		}
		body += " " + l
	}
	return body, true
}

// bulletID reads `^[ \t]*[-*] \*\*\[?B[0-9]+-G[0-9]+` and returns the id.
func bulletID(l string) (string, bool) {
	s := strings.TrimLeft(l, " \t")
	if !strings.HasPrefix(s, "- **") && !strings.HasPrefix(s, "* **") {
		return "", false
	}
	s = strings.TrimPrefix(s[4:], "[")
	id, _, ok := scanID(s)
	return id, ok
}
