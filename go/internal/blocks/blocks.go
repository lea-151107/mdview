// Package blocks finds the parts of a Markdown document that mdview draws:
// mermaid code blocks, display math, images, inline math, and the headings
// it shows in bold, and tables. It parses with goldmark, so blocks inside quotes and
// lists are found, and $$ inside code, HTML or comments is left alone.
package blocks

import (
	"bytes"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	extast "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// Kind is what a block is.
type Kind string

const (
	Mermaid    Kind = "mermaid"
	Math       Kind = "math"
	Image      Kind = "image"
	Heading    Kind = "heading"     // not drawn; its lines are shown in bold
	InlineMath Kind = "inline_math" // $…$ inside a line, shown as text
	Table      Kind = "table"       // a GFM table, laid out by Vim from Block.Table
	Quote      Kind = "quote"       // a blockquote, its '>' drawn as bars by Vim
	Code       Kind = "code"        // a fenced code block, framed by Vim
	Rule       Kind = "rule"        // a thematic break, drawn as a line by Vim
	Para       Kind = "para"        // a paragraph, laid out by Vim from Block.Spans
)

// Block is one part of the document. Start and End are 1-based line
// numbers, both inclusive.
//
// For Mermaid, Math and a drawn Image, the lines Start..End are the block's
// source (with fences or delimiters) and are replaced by the image, unless
// Keep is set: then the lines stay and the image goes below End (an image
// inside a line of text).
//
// For Table, Start..End are the table's lines (header to last row), replaced
// by the table Vim draws. Images in its cells are Image blocks (Keep) of
// their rows.
//
// For Quote, Start..End are the quote's lines (blocks inside it are blocks
// of their own); Marks has the 0-based byte column of its '>' on each of
// them, or -1 for a line without one (a lazy continuation line).
//
// For Code, Start..End are the fence lines and the code; Cols has the
// 0-based byte column where each line's text starts after its quote or
// list marks (the fence, the code), or -1. A mermaid or math fence is both
// its Mermaid or Math block and a Code block, shown when it is not drawn.
//
// For Para, Start..End are the paragraph's lines (or a list item's text),
// Col the 0-based byte column where its text starts on Start (after quote
// or list marks), and Spans its text without Markdown marks.
//
// For Rule, Start == End is the line, and Col the 0-based byte column of
// its first mark (after its quote or list marks).
//
// For InlineMath, Start == End is the line, and Col and ColEnd are the
// 0-based byte range of the $…$ in that line.
type Block struct {
	Kind   Kind
	Start  int
	End    int
	Source string     // diagram or formula source
	Path   string     // image path or URL as written (Image)
	Alt    string     // alt text (Image)
	Keep   bool       // keep the lines and put the image below them (Image)
	Indent int        // columns the block is indented by (quotes, lists)
	Col    int        // InlineMath: byte offset of $ in the line
	ColEnd int        // InlineMath: byte offset after the closing $
	Width  int        // Image: width in pixels from <img width="…">, 0 if none
	Table  *TableData // Table: its cells
	Cell   *CellPos   // Image: the table cell it is in, or nil
	Marks  []int      // Quote: column of its '>' on each line, or -1
	Alert  string     // Quote: a GitHub alert's kind ("note", "tip", …), or ""
	Lang   string     // Code: the first word of the info string, as written
	Cols   []int      // Code: column of the text of each line, or -1
	Closed bool       // Code: End is the closing fence
	Spans  []Span     // Para: its text
	ID     string     // Heading: the id a link "#id" goes to (see headingID)
}

// CellPos is where an image in a table is: the row (0 is the header) and
// column of its cell, which image of the cell it is (Nth, from 0), and how
// many columns the table has.
type CellPos struct {
	Row, Col, Nth, Cols int
}

var (
	imgTag   = regexp.MustCompile(`(?i)<img\b[^>]*>`)
	imgSrc   = regexp.MustCompile(`(?i)\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))`)
	imgAlt   = regexp.MustCompile(`(?i)\balt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))`)
	imgWidth = regexp.MustCompile(`(?i)\bwidth\s*=\s*["']?(\d+)(?:px)?["']?(?:[\s>/]|$)`)
	anyTag   = regexp.MustCompile(`<[^>]*>`)
)

var md = goldmark.New(
	goldmark.WithExtensions(extension.GFM, mathExtension{}),
	goldmark.WithParserOptions(parser.WithAttribute(),
		parser.WithBlockParsers(util.Prioritized(quoteParser{}, 799))),
)

// doc is a parsed document with a map from byte offsets to lines.
type doc struct {
	src    []byte
	starts []int // byte offset of the start of each line
	lines  []string
}

// line returns the 1-based line holding byte offset off.
func (d *doc) line(off int) int {
	return sort.Search(len(d.starts), func(i int) bool { return d.starts[i] > off })
}

// col returns the 0-based byte column of off in its line.
func (d *doc) col(off int) int {
	return off - d.starts[d.line(off)-1]
}

// Parse returns the blocks of lines in document order (by Start). Unclosed
// fences and math are not returned.
func Parse(lines []string) []Block {
	d := &doc{lines: lines}
	// The front matter is not Markdown: goldmark sees blank lines there.
	fmEnd, fm, hasFM := frontMatter(lines)
	var b bytes.Buffer
	for i, l := range lines {
		d.starts = append(d.starts, b.Len())
		if i >= fmEnd {
			b.WriteString(l)
		}
		if i < len(lines)-1 {
			b.WriteByte('\n')
		}
	}
	d.src = b.Bytes()
	if len(lines) == 0 {
		return nil
	}
	pc := parser.NewContext()
	root := md.Parser().Parse(text.NewReader(d.src), parser.WithContext(pc))
	marks, _ := pc.Get(quoteMarks).(map[*ast.Blockquote][]int)

	var out []Block
	if hasFM {
		out = append(out, Block{Kind: Table, Start: 1, End: fmEnd, Table: fm})
	}
	ids := map[string]int{} // heading id -> how many headings have it
	_ = ast.Walk(root, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		switch n := n.(type) {
		case *ast.FencedCodeBlock:
			if blk, ok := d.fenced(n); ok {
				out = append(out, blk)
			}
			if blk, ok := d.code(n); ok {
				out = append(out, blk)
			}
			return ast.WalkSkipChildren, nil
		case *MathBlock:
			if n.Closed {
				out = append(out, Block{Kind: Math, Start: d.line(n.Start), End: d.line(n.Last),
					Source: string(n.Expr), Indent: d.col(n.Start)})
			}
			return ast.WalkSkipChildren, nil
		case *ast.Heading:
			if n.Lines().Len() > 0 {
				first := n.Lines().At(0)
				last := n.Lines().At(n.Lines().Len() - 1)
				out = append(out, Block{Kind: Heading, Start: d.line(first.Start),
					End: d.line(max(last.Start, last.Stop-1)), ID: d.headingID(n, ids)})
			}
		case *ast.Image:
			out = append(out, d.image(n))
			return ast.WalkSkipChildren, nil
		case *ast.HTMLBlock:
			out = append(out, d.htmlImages(n.Lines(), n.HasClosure(), n.ClosureLine, nil)...)
			return ast.WalkSkipChildren, nil
		case *ast.RawHTML:
			out = append(out, d.htmlImages(n.Segments, false, text.Segment{}, n)...)
		case *ast.Paragraph, *ast.TextBlock:
			if blk, ok := d.para(n); ok {
				out = append(out, blk)
			}
		case *ast.ThematicBreak:
			if pos := n.Pos(); pos >= 0 && pos < len(d.src) && strings.IndexByte("-*_", d.src[pos]) >= 0 {
				l := d.line(pos)
				out = append(out, Block{Kind: Rule, Start: l, End: l, Col: d.col(pos)})
			}
		case *ast.Blockquote:
			if blk, ok := d.quote(n, marks[n]); ok {
				out = append(out, blk)
			}
		case *extast.Table:
			if blk, ok := d.table(n); ok {
				out = append(out, blk)
			}
		case *MathInline:
			if inTableCell(n) {
				return ast.WalkContinue, nil // part of the table's cell
			}
			l := d.line(n.Start)
			out = append(out, Block{Kind: InlineMath, Start: l, End: l, Source: n.Expr,
				Col: d.col(n.Start), ColEnd: d.col(n.Start) + (n.Stop - n.Start)})
		}
		return ast.WalkContinue, nil
	})
	sort.SliceStable(out, func(i, j int) bool { return out[i].Start < out[j].Start })
	// A fence line outside the code's quote or list item is not its closing
	// fence but the opening of the next code block.
	opens := map[int]bool{}
	for _, b := range out {
		if b.Kind == Code {
			opens[b.Start] = true
		}
	}
	for i := range out {
		if b := &out[i]; b.Kind == Code && b.Closed && opens[b.End] {
			b.Closed = false
			b.End--
			b.Cols = b.Cols[:len(b.Cols)-1]
		}
	}
	// Number the images of each cell in order.
	nth := map[[3]int]int{}
	for i := range out {
		if c := out[i].Cell; c != nil {
			k := [3]int{out[i].Start, c.Row, c.Col}
			c.Nth = nth[k]
			nth[k]++
		}
	}
	return out
}

// fenced returns a mermaid or math code block, with the lines of its fences.
func (d *doc) fenced(n *ast.FencedCodeBlock) (Block, bool) {
	var kind Kind
	switch strings.ToLower(string(n.Language(d.src))) {
	case "mermaid":
		kind = Mermaid
	case "math", "latex", "tex", "katex":
		kind = Math
	default:
		return Block{}, false
	}
	if n.Info == nil {
		return Block{}, false
	}
	start := d.line(n.Info.Segment.Start)
	opener := d.lines[start-1]
	fi := strings.Index(opener, "```")
	if j := strings.Index(opener, "~~~"); fi < 0 || (j >= 0 && j < fi) {
		fi = j
	}
	if fi < 0 {
		return Block{}, false
	}
	fence := opener[fi : fi+3]
	end := start + 1
	var body strings.Builder
	segs := n.Lines()
	for i := 0; i < segs.Len(); i++ {
		s := segs.At(i)
		body.WriteString(strings.Repeat(" ", s.Padding))
		body.Write(s.Value(d.src))
		end = d.line(max(s.Start, s.Stop-1)) + 1
	}
	// The closing fence must be there: an unclosed fence (or one cut off by
	// the end of its quote or list item) is not drawn.
	if end > len(d.lines) || !strings.Contains(d.lines[end-1], fence) ||
		strings.Trim(strings.TrimLeft(d.lines[end-1], " \t>"), fence[:1]+" \t") != "" {
		return Block{}, false
	}
	return Block{Kind: kind, Start: start, End: end,
		Source: strings.TrimRight(body.String(), "\n"), Indent: fi}, true
}

// image returns an image block. An image alone on its line (with other
// images or a link around it) replaces the line; one inside text keeps the
// line and goes below it.
func (d *doc) image(n *ast.Image) Block {
	off := d.inlineOffset(n)
	l := d.line(off)
	blk := Block{Kind: Image, Start: l, End: l, Path: string(n.Destination),
		Alt: string(altText(n, d.src)), Keep: true}
	blk.Cell = cellPos(n)
	if rest := d.withoutImages(n, l); strings.TrimSpace(rest) == "" && blk.Cell == nil {
		blk.Keep = false
	}
	// Indent: where the paragraph's text starts (after quote or list marks).
	for p := n.Parent(); p != nil; p = p.Parent() {
		if p.Type() == ast.TypeBlock && p.Lines().Len() > 0 {
			blk.Indent = d.col(p.Lines().At(0).Start)
			break
		}
	}
	return blk
}

// cellPos returns the table cell n is in, or nil. (A cell is a part of its
// row's line, so the line is never replaced by an image in it.)
func cellPos(n ast.Node) *CellPos {
	for p := n.Parent(); p != nil; p = p.Parent() {
		if p.Kind() != extast.KindTableCell {
			continue
		}
		c := &CellPos{}
		for s := p.PreviousSibling(); s != nil; s = s.PreviousSibling() {
			c.Col++
		}
		row := p.Parent()
		if row == nil || row.Parent() == nil {
			return c
		}
		for s := row.PreviousSibling(); s != nil; s = s.PreviousSibling() {
			c.Row++
		}
		if t, ok := row.Parent().(*extast.Table); ok {
			c.Cols = len(t.Alignments)
		}
		return c
	}
	return nil
}

// inTableCell reports whether n is in a table cell.
func inTableCell(n ast.Node) bool { return cellPos(n) != nil }

// htmlImages returns the <img> tags in HTML (a block, or a tag inside a
// paragraph when inline). An image whose line holds nothing but tags replaces
// the line; one with text around it, or inline, keeps it. HTML comments are
// skipped. inline is the RawHTML node of a tag inside a paragraph, else nil.
func (d *doc) htmlImages(segs *text.Segments, closed bool, closure text.Segment, inline ast.Node) []Block {
	var out []Block
	all := []text.Segment{}
	for i := 0; i < segs.Len(); i++ {
		all = append(all, segs.At(i))
	}
	if closed && closure.Start < closure.Stop {
		all = append(all, closure)
	}
	if len(all) == 0 || bytes.HasPrefix(bytes.TrimSpace(all[0].Value(d.src)), []byte("<!--")) {
		return nil
	}
	for _, seg := range all {
		v := seg.Value(d.src)
		for _, tag := range imgTag.FindAll(v, -1) {
			src := firstGroup(imgSrc.FindSubmatch(tag))
			if src == "" {
				continue
			}
			l := d.line(seg.Start)
			line := d.lines[l-1]
			// The line is replaced only when it holds nothing but tags (after
			// the quote or list marks); otherwise the image goes below it.
			text := line[min(d.col(seg.Start), len(line)):]
			if inline != nil {
				text = strings.TrimLeft(line, " \t>")
			}
			blk := Block{Kind: Image, Start: l, End: l, Path: src, Alt: firstGroup(imgAlt.FindSubmatch(tag)),
				Keep:   strings.TrimSpace(anyTag.ReplaceAllString(text, "")) != "" || inTableRow(line),
				Indent: d.col(seg.Start)}
			if inline != nil {
				blk.Cell = cellPos(inline)
				if blk.Cell != nil {
					blk.Keep = true
				}
			}
			if m := imgWidth.FindSubmatch(tag); m != nil {
				blk.Width, _ = strconv.Atoi(string(m[1]))
			}
			out = append(out, blk)
		}
	}
	return out
}

// inTableRow reports whether line looks like a table row ("| a | b |").
func inTableRow(line string) bool {
	t := strings.TrimSpace(strings.TrimLeft(line, " \t>"))
	return strings.HasPrefix(t, "|") && strings.Count(t, "|") >= 2
}

func firstGroup(m [][]byte) string {
	if len(m) < 2 {
		return ""
	}
	for _, g := range m[1:] {
		if len(g) > 0 {
			return string(g)
		}
	}
	return ""
}

// withoutImages returns line l with the images (and links holding only an
// image) of n's paragraph removed, to tell whether anything else is on it.
func (d *doc) withoutImages(n *ast.Image, l int) string {
	line := d.lines[l-1]
	start := d.starts[l-1]
	para := n.Parent()
	for para != nil && para.Type() != ast.TypeBlock {
		para = para.Parent()
	}
	if para == nil {
		return line
	}
	// Mark the bytes of this line that are text outside images.
	keep := make([]bool, len(line))
	mark := func(from, to int) {
		for o := max(from, start); o < min(to, start+len(line)); o++ {
			keep[o-start] = true
		}
	}
	var visit func(ast.Node, bool)
	visit = func(c ast.Node, inImage bool) {
		for ; c != nil; c = c.NextSibling() {
			switch c := c.(type) {
			case *ast.Image:
				visit(c.FirstChild(), true)
			case *ast.Link:
				visit(c.FirstChild(), inImage || onlyImages(c))
			case *ast.Text:
				if !inImage {
					mark(c.Segment.Start, c.Segment.Stop)
				}
			case *ast.RawHTML:
				if !inImage {
					for i := 0; i < c.Segments.Len(); i++ {
						mark(c.Segments.At(i).Start, c.Segments.At(i).Stop)
					}
				}
			case *MathInline:
				if !inImage {
					mark(c.Start, c.Stop)
				}
			default:
				visit(c.FirstChild(), inImage)
			}
		}
	}
	visit(para.FirstChild(), false)
	var b strings.Builder
	for i, k := range keep {
		if k {
			b.WriteByte(line[i])
		}
	}
	return b.String()
}

func onlyImages(link *ast.Link) bool {
	has := false
	for c := link.FirstChild(); c != nil; c = c.NextSibling() {
		if _, ok := c.(*ast.Image); !ok {
			return false
		}
		has = true
	}
	return has
}

// inlineOffset returns a byte offset on the line where inline node n is: its
// first text, else the end of the text before it, else the start of the text
// after it, else its block's first line.
func (d *doc) inlineOffset(n ast.Node) int {
	if off, ok := firstText(n); ok {
		return off
	}
	for p := n; p != nil && p.Type() != ast.TypeBlock; p = p.Parent() {
		for s := p.PreviousSibling(); s != nil; s = s.PreviousSibling() {
			if off, ok := lastText(s); ok {
				return off
			}
		}
		for s := p.NextSibling(); s != nil; s = s.NextSibling() {
			if off, ok := firstText(s); ok {
				return off
			}
		}
	}
	for p := n; p != nil; p = p.Parent() {
		if p.Type() == ast.TypeBlock && p.Lines().Len() > 0 {
			return p.Lines().At(0).Start
		}
	}
	return 0
}

func firstText(n ast.Node) (int, bool) {
	if t, ok := n.(*ast.Text); ok {
		return t.Segment.Start, true
	}
	for c := n.FirstChild(); c != nil; c = c.NextSibling() {
		if off, ok := firstText(c); ok {
			return off, true
		}
	}
	return 0, false
}

func lastText(n ast.Node) (int, bool) {
	if t, ok := n.(*ast.Text); ok {
		return max(t.Segment.Start, t.Segment.Stop-1), true
	}
	for c := n.LastChild(); c != nil; c = c.PreviousSibling() {
		if off, ok := lastText(c); ok {
			return off, true
		}
	}
	return 0, false
}

func altText(n ast.Node, src []byte) []byte {
	var b []byte
	for c := n.FirstChild(); c != nil; c = c.NextSibling() {
		if t, ok := c.(*ast.Text); ok {
			b = append(b, t.Segment.Value(src)...)
		} else {
			b = append(b, altText(c, src)...)
		}
	}
	return b
}

// para returns the Para block of a paragraph or a list item's text.
func (d *doc) para(n ast.Node) (Block, bool) {
	ls := n.Lines()
	if ls.Len() == 0 {
		return Block{}, false
	}
	first, last := ls.At(0), ls.At(ls.Len()-1)
	return Block{Kind: Para, Start: d.line(first.Start), End: d.line(max(last.Start, last.Stop-1)),
		Col: d.col(first.Start), Spans: d.spans(n, true)}, true
}

// headingID returns the id of heading n: its {#id} attribute, or its text
// made a slug as GitHub does (lower case, without punctuation, spaces as
// "-"), with "-1", "-2", … after an id an earlier heading has. ids counts
// the ids given so far.
func (d *doc) headingID(n *ast.Heading, ids map[string]int) string {
	if v, ok := n.AttributeString("id"); ok {
		if b, ok := v.([]byte); ok && len(b) > 0 {
			id := string(b)
			ids[id]++
			return id
		}
	}
	var t strings.Builder
	for _, sp := range d.spans(n, false) {
		t.WriteString(sp.Text)
	}
	var b strings.Builder
	for _, r := range strings.ToLower(t.String()) {
		switch {
		case r == ' ':
			b.WriteByte('-')
		case r == '-' || r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsMark(r):
			b.WriteRune(r)
		}
	}
	base := b.String()
	id := base
	for k := 1; ids[id] > 0; k++ {
		id = fmt.Sprintf("%s-%d", base, k)
	}
	ids[id]++
	return id
}
