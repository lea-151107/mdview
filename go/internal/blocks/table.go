package blocks

import (
	"regexp"
	"strings"

	"github.com/yuin/goldmark/ast"
	extast "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/util"
)

// Span is a run of text in a table cell with one style: a comma-separated
// set of "b" (bold), "i" (italic), "code", "strike", "u" (underline),
// "link", "image" (an image's alt text) and "math" (Text is the formula's
// source); "" is plain. A Span whose Text is "\n" is a line break (<br>).
type Span struct {
	Text  string
	Style string
}

// TableData is a GFM table: its cells without Markdown marks, for Vim to
// lay out.
type TableData struct {
	Align []string   // per column: "l", "c", "r", or "" (none)
	Rows  [][][]Span // [row][column]; Rows[0] is the header
	Lines []int      // the source line of each row (1-based)
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
			cells = append(cells, d.spans(c))
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

// spans returns the text of a table cell as styled runs.
func (d *doc) spans(cell ast.Node) []Span {
	var out []Span
	add := func(text string, styles []string) {
		if text == "" {
			return
		}
		style := strings.Join(styles, ",")
		if text != "\n" && len(out) > 0 && out[len(out)-1].Style == style && out[len(out)-1].Text != "\n" {
			out[len(out)-1].Text += text
			return
		}
		out = append(out, Span{Text: text, Style: style})
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
				v := c.Segment.Value(d.src)
				if !c.IsRaw() {
					v = util.UnescapePunctuations(v)
					v = util.ResolveNumericReferences(v)
					v = util.ResolveEntityNames(v)
				}
				add(string(v), st)
				if c.SoftLineBreak() || c.HardLineBreak() {
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
			case *ast.CodeSpan:
				var b strings.Builder
				for k := c.FirstChild(); k != nil; k = k.NextSibling() {
					if t, ok := k.(*ast.Text); ok {
						b.Write(t.Segment.Value(d.src))
					} else if s, ok := k.(*ast.String); ok {
						b.Write(s.Value)
					}
				}
				add(b.String(), with(st, "code"))
			case *ast.Link:
				visit(c, with(styles, "link"))
			case *ast.AutoLink:
				add(string(c.Label(d.src)), with(st, "link"))
			case *ast.Image:
				add("["+string(altText(c, d.src))+"]", with(st, "image"))
			case *MathInline:
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
	visit(cell, nil)
	// Trim the spaces around the cell and around its line breaks.
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
