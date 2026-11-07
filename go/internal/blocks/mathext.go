package blocks

// The math extension for goldmark: $$…$$ and \[…\] blocks that start a line
// (inside quotes and lists too), and $…$ / $$…$$ inside a line. Based on
// gvmd's internal/render/mathext.go, with \[…\], source positions, and a
// blank line ending an unclosed block (it is then not drawn).

import (
	"bytes"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// Node kinds for math. ast.NewNodeKind registers a name once at start-up.
var (
	KindMathInline = ast.NewNodeKind("MathInline")
	KindMathBlock  = ast.NewNodeKind("MathBlock")
)

// MathInline is $…$ inside a line. Display is set for $$…$$ written inside a
// line. Start and Stop are the byte offsets of the whole $…$ in the source.
type MathInline struct {
	ast.BaseInline
	Expr        string
	Display     bool
	Start, Stop int
}

// Kind implements ast.Node.
func (n *MathInline) Kind() ast.NodeKind { return KindMathInline }

// Dump implements ast.Node.
func (n *MathInline) Dump(source []byte, level int) {
	ast.DumpHelper(n, source, level, map[string]string{"Expr": n.Expr}, nil)
}

// MathBlock is a $$ … $$ or \[ … \] block. Start is the byte offset of the
// opening delimiter, Last that of the line holding the closing one.
type MathBlock struct {
	ast.BaseBlock
	Expr   []byte
	Closed bool
	Start  int
	Last   int
	close  []byte
}

// Kind implements ast.Node.
func (n *MathBlock) Kind() ast.NodeKind { return KindMathBlock }

// IsRaw implements ast.Node: the content is not Markdown.
func (n *MathBlock) IsRaw() bool { return true }

// Dump implements ast.Node.
func (n *MathBlock) Dump(source []byte, level int) {
	ast.DumpHelper(n, source, level, map[string]string{"Expr": string(n.Expr)}, nil)
}

type mathExtension struct{}

func (mathExtension) Extend(m goldmark.Markdown) {
	m.Parser().AddOptions(
		parser.WithBlockParsers(util.Prioritized(mathBlockParser{}, 90)),
		parser.WithInlineParsers(util.Prioritized(mathInlineParser{}, 150)),
	)
}

type mathBlockParser struct{}

func (mathBlockParser) Trigger() []byte { return []byte{'$', '\\'} }

func (mathBlockParser) Open(parent ast.Node, reader text.Reader, pc parser.Context) (ast.Node, parser.State) {
	line, seg := reader.PeekLine()
	pos := pc.BlockOffset()
	if pos < 0 || pos >= len(line) {
		return nil, parser.NoChildren
	}
	var open, close []byte
	switch {
	case bytes.HasPrefix(line[pos:], []byte("$$")):
		open, close = []byte("$$"), []byte("$$")
	case bytes.HasPrefix(line[pos:], []byte(`\[`)):
		open, close = []byte(`\[`), []byte(`\]`)
	default:
		return nil, parser.NoChildren
	}
	rest := bytes.TrimSpace(line[pos+len(open):])
	node := &MathBlock{Start: seg.Start + pos, Last: seg.Start + pos, close: close}
	if i := bytes.Index(rest, close); i >= 0 {
		// One line; anything after the closing delimiter makes it not a block.
		if len(bytes.TrimSpace(rest[i+len(close):])) > 0 || len(bytes.TrimSpace(rest[:i])) == 0 {
			return nil, parser.NoChildren
		}
		node.Expr = append(node.Expr, bytes.TrimSpace(rest[:i])...)
		node.Closed = true
	} else if len(rest) > 0 {
		node.Expr = append(node.Expr, rest...)
		node.Expr = append(node.Expr, '\n')
	}
	reader.AdvanceToEOL()
	return node, parser.NoChildren
}

func (mathBlockParser) Continue(node ast.Node, reader text.Reader, pc parser.Context) parser.State {
	n := node.(*MathBlock)
	if n.Closed {
		return parser.Close
	}
	line, seg := reader.PeekLine()
	trimmed := bytes.TrimSpace(line)
	if len(trimmed) == 0 {
		// A blank line ends it unclosed, as a paragraph would end.
		return parser.Close
	}
	if bytes.HasSuffix(trimmed, n.close) {
		n.Expr = append(n.Expr, bytes.TrimSpace(trimmed[:len(trimmed)-len(n.close)])...)
		n.Closed = true
		n.Last = seg.Start
		reader.AdvanceToEOL()
		return parser.Close
	}
	n.Expr = append(n.Expr, trimmed...)
	n.Expr = append(n.Expr, '\n')
	reader.AdvanceToEOL()
	return parser.Continue | parser.NoChildren
}

func (mathBlockParser) Close(node ast.Node, reader text.Reader, pc parser.Context) {
	n := node.(*MathBlock)
	n.Expr = bytes.TrimSpace(n.Expr)
	if len(n.Expr) == 0 {
		n.Closed = false
	}
}

func (mathBlockParser) CanInterruptParagraph() bool { return true }
func (mathBlockParser) CanAcceptIndentedLine() bool { return false }

type mathInlineParser struct{}

func (mathInlineParser) Trigger() []byte { return []byte{'$'} }

// Parse follows the usual rules (pandoc, GitHub): the opening $ is not
// followed by a space, the closing $ is not preceded by a space nor followed
// by a digit, so "$5 and $10" stays text.
func (mathInlineParser) Parse(parent ast.Node, block text.Reader, pc parser.Context) ast.Node {
	line, seg := block.PeekLine()
	if len(line) < 2 || line[0] != '$' {
		return nil
	}
	delim := 1
	if line[1] == '$' {
		delim = 2
	}
	body := line[delim:]
	if len(body) == 0 || body[0] == ' ' || body[0] == '\t' || body[0] == '\n' {
		return nil
	}
	for i := 0; i < len(body); i++ {
		switch body[i] {
		case '\\':
			i++ // skip the escaped character
			continue
		case '\n':
			return nil // stay on one line
		case '$':
		default:
			continue
		}
		if delim == 2 {
			if i+1 >= len(body) || body[i+1] != '$' {
				continue
			}
		}
		if i == 0 || body[i-1] == ' ' || body[i-1] == '\t' {
			continue
		}
		end := i + delim
		if delim == 1 && end < len(body) && body[end] >= '0' && body[end] <= '9' {
			continue
		}
		block.Advance(delim + end)
		return &MathInline{Expr: string(body[:i]), Display: delim == 2,
			Start: seg.Start, Stop: seg.Start + delim + end}
	}
	return nil
}
