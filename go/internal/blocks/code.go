package blocks

import (
	"strings"

	"github.com/yuin/goldmark/ast"
)

// code returns the Code block of a fenced code block.
func (d *doc) code(n *ast.FencedCodeBlock) (Block, bool) {
	pos := n.Pos()
	if pos < 0 || pos >= len(d.src) {
		return Block{}, false
	}
	start := d.line(pos)
	opener := d.lines[start-1]
	// The fence: the first run of ``` or ~~~ at or after pos.
	fc := d.col(pos)
	fi := -1
	for _, f := range []string{"```", "~~~"} {
		if j := strings.Index(opener[min(fc, len(opener)):], f); j >= 0 && (fi < 0 || fc+j < fi) {
			fi = fc + j
		}
	}
	if fi < 0 {
		return Block{}, false
	}
	fence := opener[fi : fi+3]
	blk := Block{Kind: Code, Start: start, End: start, Lang: string(n.Language(d.src)), Cols: []int{fi}}
	segs := n.Lines()
	for i := 0; i < segs.Len(); i++ {
		s := segs.At(i)
		l := d.line(s.Start)
		for blk.End < l-1 {
			blk.End++
			blk.Cols = append(blk.Cols, -1)
		}
		if l == blk.End {
			continue // a second segment of a line
		}
		blk.End = l
		blk.Cols = append(blk.Cols, d.col(s.Start))
	}
	// The closing fence, if it is there (as in fenced()).
	if l := blk.End + 1; l <= len(d.lines) {
		line := d.lines[l-1]
		if j := strings.Index(line, fence); j >= 0 &&
			strings.Trim(strings.TrimLeft(line, " \t>"), fence[:1]+" \t") == "" {
			blk.End = l
			blk.Cols = append(blk.Cols, j)
			blk.Closed = true
		}
	}
	return blk, true
}
