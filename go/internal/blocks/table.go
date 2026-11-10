package blocks

import (
	"regexp"
	"strings"

	"github.com/yuin/goldmark/ast"
	extast "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/util"
)

// Span is a run of text in a table cell or a paragraph with one style: a
// comma-separated set of "b" (bold), "i" (italic), "code", "strike", "u"
// (underline), "link", "image" (an image's alt text) and "math" (Text is
// the formula's source); "" is plain. A Span whose Text is "\n" is a line
// break (<br>, or a hard line break in a paragraph). Line is the source
// line (1-based) the span starts on. URL is the destination of the link the
// span is in (as written, or an autolink's URL), or "".
type Span struct {
	Text  string
	Style string
	Line  int
	URL   string
}

// TableData is a GFM table: its cells without Markdown marks, for Vim to
// lay out.
type TableData struct {
	Align []string   // per column: "l", "c", "r", or "" (none)
	Rows  [][][]Span // [row][column]; Rows[0] is the header
	Lines []int      // the source line of each row (1-based)
	// NoHeader: Rows[0] is a row like the others (the front matter's).
	NoHeader bool
}

var htmlTag = regexp.MustCompile(`(?i)^<\s*(/?)\s*([a-z][a-z0-9]*)\b[^>]*?(/?)\s*>$`)

// table returns the table block of n.
func (d *doc) table(n *extast.Table) (Block, bool) {
	t := &TableData{}
	for _, a := range n.Alignments {
		t.Align = append(t.Align, map[extast.Alignment]string{
			extast.AlignLeft: "l", extast.AlignCenter: "c", extast.AlignRight: "r"}[a])
	}
	prev := 0
	firstCell := -1 // byte offset of the header's first cell
	for row := n.FirstChild(); row != nil; row = row.NextSibling() {
		line := 0
		var cells [][]Span
		for c := row.FirstChild(); c != nil; c = c.NextSibling() {
			if c.Lines().Len() > 0 {
				off := c.Lines().At(0).Start
				if line == 0 {
					line = d.line(off)
				}
				if firstCell < 0 {
					firstCell = off
				}
			}
			cells = append(cells, d.spans(c, false))
		}
		if line == 0 {
			line = prev + 1
		}
		if prev > 0 && line <= prev {
			line = prev + 1
		}
		if line > len(d.lines) {
			return Block{}, false
		}
		t.Rows = append(t.Rows, cells)
		t.Lines = append(t.Lines, line)
		prev = line
		if row == n.FirstChild() {
			// The delimiter row follows the header.
			prev++
		}
	}
	if len(t.Rows) == 0 || firstCell < 0 {
		return Block{}, false
	}
	start := t.Lines[0]
	end := max(start+1, t.Lines[len(t.Lines)-1])
	if end > len(d.lines) {
		return Block{}, false
	}
	// Indent: the column of the header's leading pipe, or of its first cell.
	line := d.lines[start-1]
	indent := min(d.col(firstCell), len(line))
	if i := strings.LastIndex(line[:indent], "|"); i >= 0 && strings.TrimSpace(line[i+1:indent]) == "" {
		indent = i
	}
	return Block{Kind: Table, Start: start, End: end, Indent: indent, Table: t}, true
}

// softBreak stands for a soft line break of a paragraph until spans
// decides what it becomes.
const softBreak = "\x00"

// spans returns the text of a table cell, or of a paragraph (para), as
// styled runs. In a paragraph a hard line break is a line break, and a soft
// one is a space, or nothing between two wide characters (as in Japanese).
func (d *doc) spans(n ast.Node, para bool) []Span {
	var out []Span
	line := 0 // the source line of the text being added
	if n.Lines().Len() > 0 {
		line = d.line(n.Lines().At(0).Start)
	}
	url := "" // the destination of the link being visited
	add := func(text string, styles []string) {
		if text == "" {
			return
		}
		style := strings.Join(styles, ",")
		u := url
		if style == "" && (text == "\n" || text == softBreak) {
			u = ""
		}
		if k := len(out) - 1; text != "\n" && k >= 0 && out[k].Style == style &&
			out[k].Text != "\n" && out[k].Line == line && out[k].URL == u {
			out[k].Text += text
			return
		}
		out = append(out, Span{Text: text, Style: style, Line: line, URL: u})
	}
	// Styles opened by HTML tags (<u>, <b>, …) until their closing tag.
	html := map[string]int{}
	htmlStyles := func(styles []string) []string {
		for _, s := range []string{"b", "i", "code", "strike", "u"} {
			if html[s] > 0 {
				styles = with(styles, s)
			}
		}
		return styles
	}
	var visit func(n ast.Node, styles []string)
	visit = func(n ast.Node, styles []string) {
		for c := n.FirstChild(); c != nil; c = c.NextSibling() {
			st := htmlStyles(styles)
			switch c := c.(type) {
			case *ast.Text:
				line = d.line(c.Segment.Start)
				v := c.Segment.Value(d.src)
				if !c.IsRaw() {
					v = util.UnescapePunctuations(v)
					v = util.ResolveNumericReferences(v)
					v = util.ResolveEntityNames(v)
				}
				add(string(v), st)
				switch {
				case para && c.HardLineBreak():
					add("\n", nil)
				case para && c.SoftLineBreak():
					add(softBreak, nil)
				case c.SoftLineBreak() || c.HardLineBreak():
					add(" ", st)
				}
			case *ast.String:
				add(string(c.Value), st)
			case *ast.Emphasis:
				s := "i"
				if c.Level >= 2 {
					s = "b"
				}
				visit(c, with(styles, s))
			case *extast.Strikethrough:
				visit(c, with(styles, "strike"))
			case *extast.TaskCheckBox:
				if c.IsChecked {
					add("[x] ", st)
				} else {
					add("[ ] ", st)
				}
			case *ast.CodeSpan:
				var b strings.Builder
				for k := c.FirstChild(); k != nil; k = k.NextSibling() {
					if t, ok := k.(*ast.Text); ok {
						line = d.line(t.Segment.Start)
						b.Write(t.Segment.Value(d.src))
					} else if s, ok := k.(*ast.String); ok {
						b.Write(s.Value)
					}
				}
				add(b.String(), with(st, "code"))
			case *ast.Link:
				outer := url
				url = string(c.Destination)
				visit(c, with(styles, "link"))
				url = outer
			case *ast.AutoLink:
				outer := url
				url = autoLinkURL(c, d.src)
				add(string(c.Label(d.src)), with(st, "link"))
				url = outer
			case *ast.Image:
				add("["+string(altText(c, d.src))+"]", with(st, "image"))
			case *MathInline:
				line = d.line(c.Start)
				add(c.Expr, with(st, "math"))
			case *ast.RawHTML:
				var b strings.Builder
				for i := 0; i < c.Segments.Len(); i++ {
					seg := c.Segments.At(i)
					b.Write(seg.Value(d.src))
				}
				tag := b.String()
				if m := htmlTag.FindStringSubmatch(tag); m != nil {
					name := strings.ToLower(m[2])
					s := map[string]string{"b": "b", "strong": "b", "i": "i", "em": "i",
						"code": "code", "s": "strike", "del": "strike", "strike": "strike",
						"u": "u", "ins": "u"}[name]
					switch {
					case name == "img":
						// Only those Parse returns, so that the nth image span
						// of a cell is its nth image block.
						if firstGroup(imgSrc.FindSubmatch([]byte(tag))) != "" {
							add("["+firstGroup(imgAlt.FindSubmatch([]byte(tag)))+"]", with(st, "image"))
						}
					case name == "br":
						add("\n", nil)
					case s != "" && m[1] == "/":
						html[s] = max(0, html[s]-1)
					case s != "" && m[3] == "":
						html[s]++
					}
				}
			default:
				visit(c, styles)
			}
		}
	}
	visit(n, nil)
	if para {
		joinSoftBreaks(out)
	}
	// Trim the spaces around the text and around its line breaks.
	for i := range out {
		if out[i].Text == "\n" {
			continue
		}
		if i == 0 || out[i-1].Text == "\n" {
			out[i].Text = strings.TrimLeft(out[i].Text, " \t")
		}
		if i == len(out)-1 || out[i+1].Text == "\n" {
			out[i].Text = strings.TrimRight(out[i].Text, " \t")
		}
	}
	res := out[:0]
	for _, s := range out {
		if s.Text != "" {
			res = append(res, s)
		}
	}
	if len(res) == 0 {
		return []Span{}
	}
	return res
}

// autoLinkURL returns the URL an autolink goes to: an e-mail address with
// "mailto:" when it has no scheme.
func autoLinkURL(n *ast.AutoLink, src []byte) string {
	u := string(n.URL(src))
	if n.AutoLinkType == ast.AutoLinkEmail && !strings.HasPrefix(strings.ToLower(u), "mailto:") {
		u = "mailto:" + u
	}
	return u
}

// joinSoftBreaks turns the soft line breaks of spans into a space, or into
// nothing between two wide characters (Japanese text is not spaced) or at a
// hard line break.
func joinSoftBreaks(spans []Span) {
	// The runes of all the spans, to look at the neighbors of each break.
	type at struct{ span, off int }
	var runes []rune
	var where []at
	for i, s := range spans {
		for off, r := range s.Text {
			runes = append(runes, r)
			where = append(where, at{i, off})
		}
	}
	repl := map[int]string{} // span -> its text with the breaks replaced
	for k, r := range runes {
		if string(r) != softBreak {
			continue
		}
		var prev, next rune
		for j := k - 1; j >= 0; j-- {
			if string(runes[j]) != softBreak {
				prev = runes[j]
				break
			}
		}
		for j := k + 1; j < len(runes); j++ {
			if string(runes[j]) != softBreak {
				next = runes[j]
				break
			}
		}
		sep := " "
		if (isWide(prev) && isWide(next)) || prev == '\n' || next == '\n' || prev == 0 || next == 0 {
			sep = ""
		}
		i := where[k].span
		if _, ok := repl[i]; !ok {
			repl[i] = spans[i].Text
		}
		repl[i] = strings.Replace(repl[i], softBreak, sep+"\x01", 1)
	}
	for i, t := range repl {
		spans[i].Text = strings.ReplaceAll(t, "\x01", "")
	}
}

// isWide reports whether r is a wide (East Asian) character: CJK, kana,
// Hangul, and full-width forms and punctuation.
func isWide(r rune) bool {
	switch {
	case r >= 0x1100 && r <= 0x115F, // Hangul Jamo
		r >= 0x2E80 && r <= 0x303E, // CJK radicals, punctuation
		r >= 0x3041 && r <= 0x33FF, // kana, CJK symbols
		r >= 0x3400 && r <= 0x4DBF, // CJK Ext A
		r >= 0x4E00 && r <= 0x9FFF, // CJK
		r >= 0xA000 && r <= 0xA4CF, // Yi
		r >= 0xAC00 && r <= 0xD7A3, // Hangul
		r >= 0xF900 && r <= 0xFAFF, // CJK compatibility
		r >= 0xFE30 && r <= 0xFE4F, // CJK compatibility forms
		r >= 0xFF00 && r <= 0xFF60, // full-width forms
		r >= 0xFFE0 && r <= 0xFFE6,
		r >= 0x20000 && r <= 0x3FFFD:
		return true
	}
	return false
}

// with returns styles plus s (once), in a fixed order.
func with(styles []string, s string) []string {
	out := []string{}
	for _, o := range []string{"b", "i", "code", "strike", "u", "link", "image", "math"} {
		if o == s || contains(styles, o) {
			out = append(out, o)
		}
	}
	return out
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}
