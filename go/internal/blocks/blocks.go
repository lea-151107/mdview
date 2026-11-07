// Package blocks finds the parts of a Markdown document that mdview draws as
// images: mermaid code blocks, display math and images on a line of their own.
package blocks

import (
	"regexp"
	"strings"
)

// Kind is what a block is drawn from.
type Kind string

const (
	Mermaid Kind = "mermaid"
	Math    Kind = "math"
	Image   Kind = "image"
)

// Block is one drawable part of the document. Start and End are 1-based line
// numbers, both inclusive, covering the whole block including its fences or
// delimiters.
type Block struct {
	Kind   Kind
	Start  int
	End    int
	Source string // diagram or formula source (Mermaid, Math)
	Path   string // image path or URL as written (Image)
	Alt    string // alt text (Image)
}

var (
	fenceOpen = regexp.MustCompile("^( {0,3})(`{3,}|~{3,})\\s*([^`\\s{]*)")
	// An image alone on its line: ![alt](path) or ![alt](path "title").
	imageLine = regexp.MustCompile(`^\s{0,3}!\[([^\]]*)\]\(\s*(<[^>]*>|[^\s)]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)\s*$`)
)

// Parse returns the blocks of lines in document order. Unclosed blocks are
// ignored, as is anything inside other fenced code blocks.
func Parse(lines []string) []Block {
	var out []Block
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if m := fenceOpen.FindStringSubmatch(line); m != nil {
			fence := m[2]
			lang := strings.ToLower(m[3])
			end := closingFence(lines, i+1, fence)
			if end < 0 {
				// CommonMark: an unclosed fence runs to the end of the document.
				break
			}
			body := strings.Join(lines[i+1:end], "\n")
			switch lang {
			case "mermaid":
				out = append(out, Block{Kind: Mermaid, Start: i + 1, End: end + 1, Source: body})
			case "math", "latex", "tex", "katex":
				out = append(out, Block{Kind: Math, Start: i + 1, End: end + 1, Source: body})
			}
			i = end
			continue
		}
		if b, end, ok := displayMath(lines, i); ok {
			out = append(out, b)
			i = end
			continue
		}
		if m := imageLine.FindStringSubmatch(line); m != nil {
			p := strings.TrimSuffix(strings.TrimPrefix(m[2], "<"), ">")
			out = append(out, Block{Kind: Image, Start: i + 1, End: i + 1, Path: p, Alt: m[1]})
		}
	}
	return out
}

// closingFence returns the index of the line closing a fence opened with
// fence, searching from from, or -1.
func closingFence(lines []string, from int, fence string) int {
	ch := fence[:1]
	for j := from; j < len(lines); j++ {
		t := strings.TrimRight(lines[j], " \t")
		lead := len(t) - len(strings.TrimLeft(t, " "))
		if lead > 3 {
			continue
		}
		t = t[lead:]
		if len(t) >= len(fence) && strings.Trim(t, ch) == "" {
			return j
		}
	}
	return -1
}

// displayMath recognises $$…$$ and \[…\] that start a line, on one line or
// spanning several. It returns the block and the index of its last line.
func displayMath(lines []string, i int) (Block, int, bool) {
	t := strings.TrimSpace(lines[i])
	var open, close string
	switch {
	case strings.HasPrefix(t, "$$"):
		open, close = "$$", "$$"
	case strings.HasPrefix(t, `\[`):
		open, close = `\[`, `\]`
	default:
		return Block{}, 0, false
	}
	rest := t[len(open):]
	if k := strings.Index(rest, close); k >= 0 {
		// Single line: the closing delimiter must end the line.
		if strings.TrimSpace(rest[k+len(close):]) != "" {
			return Block{}, 0, false
		}
		src := strings.TrimSpace(rest[:k])
		if src == "" {
			return Block{}, 0, false
		}
		return Block{Kind: Math, Start: i + 1, End: i + 1, Source: src}, i, true
	}
	parts := []string{}
	if s := strings.TrimSpace(rest); s != "" {
		parts = append(parts, s)
	}
	for j := i + 1; j < len(lines); j++ {
		u := strings.TrimSpace(lines[j])
		if u == "" {
			// A blank line ends the paragraph: not display math.
			return Block{}, 0, false
		}
		if strings.HasSuffix(u, close) {
			if s := strings.TrimSpace(strings.TrimSuffix(u, close)); s != "" {
				parts = append(parts, s)
			}
			src := strings.Join(parts, "\n")
			if strings.TrimSpace(src) == "" {
				return Block{}, 0, false
			}
			return Block{Kind: Math, Start: i + 1, End: j + 1, Source: src}, j, true
		}
		parts = append(parts, lines[j])
	}
	return Block{}, 0, false
}
