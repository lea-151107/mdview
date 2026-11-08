package blocks

import (
	"regexp"
	"strings"

	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// quoteMarks is the parser.Context key of the '>' marks of each blockquote:
// map[*ast.Blockquote][]int of byte offsets in the source.
var quoteMarks = parser.NewContextKey()

// quoteParser parses blockquotes as goldmark's blockquoteParser does, and
// records where the '>' of each of their lines is, which goldmark does not
// keep.
type quoteParser struct{}

func (quoteParser) process(n ast.Node, reader text.Reader, pc parser.Context) bool {
	line, seg := reader.PeekLine()
	w, pos := util.IndentWidth(line, reader.LineOffset())
	if w > 3 || pos >= len(line) || line[pos] != '>' {
		return false
	}
	if bq, ok := n.(*ast.Blockquote); ok {
		marks, _ := pc.Get(quoteMarks).(map[*ast.Blockquote][]int)
		if marks == nil {
			marks = map[*ast.Blockquote][]int{}
			pc.Set(quoteMarks, marks)
		}
		marks[bq] = append(marks[bq], seg.Start+pos-seg.Padding)
	}
	pos++
	if pos >= len(line) || line[pos] == '\n' {
		reader.Advance(pos)
		return true
	}
	reader.Advance(pos)
	if line[pos] == ' ' || line[pos] == '\t' {
		padding := 0
		if line[pos] == '\t' {
			padding = util.TabWidth(reader.LineOffset()) - 1
		}
		reader.AdvanceAndSetPadding(1, padding)
	}
	return true
}

func (quoteParser) Trigger() []byte { return []byte{'>'} }

func (p quoteParser) Open(parent ast.Node, reader text.Reader, pc parser.Context) (ast.Node, parser.State) {
	n := ast.NewBlockquote()
	if p.process(n, reader, pc) {
		return n, parser.HasChildren
	}
	return nil, parser.NoChildren
}

func (p quoteParser) Continue(n ast.Node, reader text.Reader, pc parser.Context) parser.State {
	if p.process(n, reader, pc) {
		return parser.Continue | parser.HasChildren
	}
	return parser.Close
}

func (quoteParser) Close(ast.Node, text.Reader, parser.Context) {}
func (quoteParser) CanInterruptParagraph() bool                 { return true }
func (quoteParser) CanAcceptIndentedLine() bool                 { return false }

// alertLine is the first line of a GitHub alert, after its quote mark.
var alertLine = regexp.MustCompile(`(?i)^\s*\[!(note|tip|important|warning|caution)\]\s*$`)

// quote returns the block of a blockquote whose '>' are at the byte offsets
// marks.
func (d *doc) quote(n *ast.Blockquote, marks []int) (Block, bool) {
	if len(marks) == 0 {
		return Block{}, false
	}
	at := map[int]int{} // line -> column of its mark
	start, end := 0, 0
	for _, off := range marks {
		if off < 0 || off >= len(d.src) || d.src[off] != '>' {
			continue
		}
		l := d.line(off)
		if _, ok := at[l]; ok {
			continue
		}
		at[l] = d.col(off)
		if start == 0 || l < start {
			start = l
		}
		end = max(end, l)
	}
	if start == 0 {
		return Block{}, false
	}
	// Lines without a mark (lazy continuation lines) up to the last of its
	// content.
	if l := d.lastLine(n); l > end {
		end = l
	}
	blk := Block{Kind: Quote, Start: start, End: end}
	for l := start; l <= end; l++ {
		if c, ok := at[l]; ok {
			blk.Marks = append(blk.Marks, c)
		} else {
			blk.Marks = append(blk.Marks, -1)
		}
	}
	// A GitHub alert: "[!NOTE]" alone on the first line of its first
	// paragraph.
	if p, ok := n.FirstChild().(*ast.Paragraph); ok && p.Lines().Len() > 0 {
		first := p.Lines().At(0)
		l := d.line(first.Start)
		if c, ok := at[l]; ok && l == start {
			if m := alertLine.FindStringSubmatch(d.lines[l-1][c+1:]); m != nil {
				blk.Alert = strings.ToLower(m[1])
			}
		}
	}
	return blk, true
}

// lastLine returns the last line with content of n's descendants, or 0.
func (d *doc) lastLine(n ast.Node) int {
	last := 0
	_ = ast.Walk(n, func(c ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering || c.Type() != ast.TypeBlock {
			return ast.WalkContinue, nil
		}
		if ls := c.Lines(); ls != nil && ls.Len() > 0 {
			s := ls.At(ls.Len() - 1)
			last = max(last, d.line(max(s.Start, s.Stop-1)))
		}
		return ast.WalkContinue, nil
	})
	return last
}
