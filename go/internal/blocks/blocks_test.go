package blocks

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// drawn keeps the blocks that become images.
func drawn(bs []Block) []Block {
	var out []Block
	for _, b := range bs {
		switch b.Kind {
		case Mermaid, Math, Image:
			out = append(out, b)
		}
	}
	return out
}

func ofKind(bs []Block, k Kind) []Block {
	var out []Block
	for _, b := range bs {
		if b.Kind == k {
			out = append(out, b)
		}
	}
	return out
}

func TestParse(t *testing.T) {
	doc := strings.Split(`# Title
`+"```mermaid"+`
graph TD
  A-->B
`+"```"+`
text $x$ inline
$$ \frac{a}{b} $$
$$
\sum_{i=1}^n i
= \frac{n(n+1)}{2}
$$
![cat](img/cat.png "a cat")
see ![inline](x.png) here
`+"```go"+`
$$ not math $$
![no](no.png)
`+"```"+`
\[ x^2 \]
`+"~~~~math"+`
E = mc^2
`+"~~~~"+`
![sp](<my pic.png>)
$$ a $$ b
$$
open

$$`, "\n")
	got := drawn(Parse(doc))
	want := []Block{
		{Kind: Mermaid, Start: 2, End: 5, Source: "graph TD\n  A-->B"},
		{Kind: Math, Start: 7, End: 7, Source: `\frac{a}{b}`},
		{Kind: Math, Start: 8, End: 11, Source: "\\sum_{i=1}^n i\n= \\frac{n(n+1)}{2}"},
		{Kind: Image, Start: 12, End: 12, Path: "img/cat.png", Alt: "cat"},
		// Changed with goldmark: an image inside text is drawn below its
		// line (Keep) instead of being ignored.
		{Kind: Image, Start: 13, End: 13, Path: "x.png", Alt: "inline", Keep: true},
		{Kind: Math, Start: 18, End: 18, Source: "x^2"},
		{Kind: Math, Start: 19, End: 21, Source: "E = mc^2"},
		{Kind: Image, Start: 22, End: 22, Path: "my pic.png", Alt: "sp"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got\n%#v\nwant\n%#v", got, want)
	}
}

func TestUnclosedFence(t *testing.T) {
	got := drawn(Parse([]string{"```mermaid", "graph TD", "![x](y.png)"}))
	if len(got) != 0 {
		t.Fatalf("got %#v", got)
	}
}

func TestLongerClosingFence(t *testing.T) {
	got := drawn(Parse([]string{"```mermaid", "graph TD", "``", "`````"}))
	if len(got) != 1 || got[0].End != 4 || got[0].Source != "graph TD\n``" {
		t.Fatalf("got %#v", got)
	}
}

func TestEmptyFence(t *testing.T) {
	got := drawn(Parse([]string{"```mermaid", "```", "text"}))
	if len(got) != 1 || got[0].Start != 1 || got[0].End != 2 || got[0].Source != "" {
		t.Fatalf("got %#v", got)
	}
}

// The cases of the improvement plan (found with the old line-based parser).
func TestNested(t *testing.T) {
	cases := []struct {
		name string
		doc  string
		want []Block
	}{
		{"mermaid in a list", "- item\n\n    ```mermaid\n    graph TD\n      A-->B\n    ```\n",
			[]Block{{Kind: Mermaid, Start: 3, End: 6, Source: "graph TD\n  A-->B", Indent: 4}}},
		{"mermaid in a quote", "> ```mermaid\n> graph TD\n> ```\n",
			[]Block{{Kind: Mermaid, Start: 1, End: 3, Source: "graph TD", Indent: 2}}},
		{"math in a quote", "> $$x^2$$\n",
			[]Block{{Kind: Math, Start: 1, End: 1, Source: "x^2", Indent: 2}}},
		{"math in indented code", "text\n\n    $$x^2$$\n", nil},
		{"math in a comment", "<!--\n$$x$$\n-->\n", nil},
		{"math in pre", "<pre>\n$$x$$\n</pre>\n", nil},
		{"reference image", "![alt][ref]\n\n[ref]: a.png\n",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Alt: "alt"}}},
		{"image in text", "see ![a](a.png) here\n",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Alt: "a", Keep: true}}},
		{"image in a link", "[![a](a.png)](http://x)\n",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Alt: "a"}}},
		{"image in a list", "- ![a](a.png)\n",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Alt: "a", Indent: 2}}},
		{"two images on a line", "![a](a.png) ![b](b.png)\n",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Alt: "a"},
				{Kind: Image, Start: 1, End: 1, Path: "b.png", Alt: "b"}}},
		{"image with empty alt in text", "x ![](a.png)\n",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Keep: true}}},
		{"math block in a list", "1. step\n\n   $$\n   a+b\n   $$\n",
			[]Block{{Kind: Math, Start: 3, End: 5, Source: "a+b", Indent: 3}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := drawn(Parse(strings.Split(strings.TrimSuffix(c.doc, "\n"), "\n")))
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("got\n%#v\nwant\n%#v", got, c.want)
			}
		})
	}
}

func TestHeadings(t *testing.T) {
	doc := strings.Split("# One\n\ntext\nSetext\n===\n\n```\n# not\n```\n> ## quoted\n\n- item\n---\n\n#", "\n")
	var got [][2]int
	for _, b := range ofKind(Parse(doc), Heading) {
		got = append(got, [2]int{b.Start, b.End})
	}
	// "text\nSetext\n===" is one paragraph made a heading: lines 3-4.
	want := [][2]int{{1, 1}, {3, 4}, {10, 10}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestInlineMath(t *testing.T) {
	doc := []string{"a $x^2$ and $5 or $10", "$$z$$ b `$y$`"}
	got := ofKind(Parse(doc), InlineMath)
	want := []Block{
		{Kind: InlineMath, Start: 1, End: 1, Source: "x^2", Col: 2, ColEnd: 7},
		{Kind: InlineMath, Start: 2, End: 2, Source: "z", Col: 0, ColEnd: 5},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got\n%#v\nwant\n%#v", got, want)
	}
}

func FuzzParseRanges(f *testing.F) {
	f.Add("# t\n```mermaid\ngraph TD\n```\n$$x$$\n![a](b.png) c $y$\n> $$\n> z\n> $$\n")
	f.Add("- a\n\n  ```math\n  x\n  ```\n\\[ y \\]\n[![i](i.png)](u)")
	f.Add("| a | b |\n|---|:-:|\n| ![x](x.png) $y$ | z<br>w |\n| c |\n> | q |\n> |---|")
	f.Fuzz(func(t *testing.T, s string) {
		lines := strings.Split(s, "\n")
		prev := 0
		lastEnd := 0
		for _, b := range Parse(lines) {
			if b.Start < 1 || b.Start > b.End || b.End > len(lines) {
				t.Fatalf("bad range %+v for %d lines", b, len(lines))
			}
			if b.Start < prev {
				t.Fatalf("out of order: %+v", b)
			}
			prev = b.Start
			if b.Kind == Mermaid || b.Kind == Math {
				if b.Start <= lastEnd {
					t.Fatalf("overlapping block %+v (last end %d)", b, lastEnd)
				}
				lastEnd = b.End
			}
			if b.Kind == Table {
				tb := b.Table
				if tb == nil || len(tb.Rows) != len(tb.Lines) || tb.Lines[0] != b.Start ||
					tb.Lines[len(tb.Lines)-1] > b.End || b.Indent > len(lines[b.Start-1]) {
					t.Fatalf("bad table %+v %+v", b, tb)
				}
				for i := 1; i < len(tb.Lines); i++ {
					if tb.Lines[i] <= tb.Lines[i-1] {
						t.Fatalf("table lines out of order %v", tb.Lines)
					}
				}
			}
			if b.Kind == InlineMath {
				l := lines[b.Start-1]
				if b.Col < 0 || b.Col >= b.ColEnd || b.ColEnd > len(l) || l[b.Col] != '$' {
					t.Fatalf("bad inline math %+v in %q", b, l)
				}
			}
		}
	})
}

// Cases found by the adversarial review of the goldmark branch.
func TestReviewCases(t *testing.T) {
	cases := []struct {
		name string
		doc  string
		want []Block
	}{
		{"image in a table cell keeps the row", "| a | b |\n|---|---|\n| ![x](x.png) | y |",
			[]Block{{Kind: Image, Start: 3, End: 3, Path: "x.png", Alt: "x", Keep: true, Indent: 2,
				Cell: &CellPos{Row: 1, Col: 0, Cols: 2}}}},
		{"\\[ does not interrupt a paragraph", "Intro text\n\\[1] ref ![a](a.png)\nmore",
			[]Block{{Kind: Image, Start: 2, End: 2, Path: "a.png", Alt: "a", Keep: true}}},
		{"unclosed $$ does not swallow lines", "$$\nnot closed ![a](a.png)\n\nnext",
			[]Block{{Kind: Image, Start: 2, End: 2, Path: "a.png", Alt: "a", Keep: true}}},
		{"\\[ block still works", "text\n\n\\[\nx^2\n\\]",
			[]Block{{Kind: Math, Start: 3, End: 5, Source: "x^2"}}},
		{"html img block", "<p align=\"center\"><img src=\"logo.png\" width=\"200\" alt=\"Logo\"></p>",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "logo.png", Alt: "Logo", Width: 200}}},
		{"html img inline", "see <img src='a.png'> here",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Keep: true, Indent: 4}}},
		{"html img alone in a paragraph", "<img src=a.png width=50px>\ntext",
			[]Block{{Kind: Image, Start: 1, End: 1, Path: "a.png", Width: 50}}},
		{"html comment", "<!--\n<img src=\"a.png\">\n-->", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := drawn(Parse(strings.Split(c.doc, "\n")))
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("got\n%#v\nwant\n%#v", got, c.want)
			}
		})
	}
	// Shell variables are not inline math.
	if got := ofKind(Parse([]string{"export PATH=$HOME/bin:$PATH now", "a $x$, b"}), InlineMath); len(got) != 1 || got[0].Source != "x" {
		t.Fatalf("inline math: %#v", got)
	}
}

func TestTable(t *testing.T) {
	doc := strings.Split("intro\n\n"+
		"| 左 | 中 | 右 |\n"+
		"|:--|:-:|--:|\n"+
		"| **b** *i* ***bi*** | `c` ~~s~~ <u>u</u> | a\\|b &amp; \\* |\n"+
		"| x<br>y | [l](u) <https://x.y> | ![alt](a.png) $x^2$ |\n"+
		"| only |\n", "\n")
	bs := Parse(doc)
	tables := ofKind(bs, Table)
	if len(tables) != 1 {
		t.Fatalf("tables: %#v", bs)
	}
	tb := tables[0]
	if tb.Start != 3 || tb.End != 7 || tb.Indent != 0 {
		t.Fatalf("range %d-%d indent %d", tb.Start, tb.End, tb.Indent)
	}
	want := &TableData{
		Align: []string{"l", "c", "r"},
		Lines: []int{3, 5, 6, 7},
		Rows: [][][]Span{
			{{{"左", ""}}, {{"中", ""}}, {{"右", ""}}},
			{{{"b", "b"}, {" ", ""}, {"i", "i"}, {" ", ""}, {"bi", "b,i"}},
				{{"c", "code"}, {" ", ""}, {"s", "strike"}, {" ", ""}, {"u", "u"}},
				{{"a|b & *", ""}}},
			{{{"x", ""}, {"\n", ""}, {"y", ""}},
				{{"l", "link"}, {" ", ""}, {"https://x.y", "link"}},
				{{"[alt]", "image"}, {" ", ""}, {"x^2", "math"}}},
			{{{"only", ""}}, {}, {}},
		},
	}
	if !reflect.DeepEqual(tb.Table, want) {
		t.Fatalf("got\n%#v\nwant\n%#v", tb.Table, want)
	}
	// The image in a cell is drawn below its row; the formula is part of
	// the cell, not inline math of the line.
	if imgs := ofKind(bs, Image); len(imgs) != 1 || imgs[0].Start != 6 || !imgs[0].Keep ||
		*imgs[0].Cell != (CellPos{Row: 2, Col: 2, Cols: 3}) {
		t.Fatalf("images: %#v", imgs)
	}
	if m := ofKind(bs, InlineMath); len(m) != 0 {
		t.Fatalf("inline math: %#v", m)
	}
}

func TestTableNested(t *testing.T) {
	cases := []struct {
		doc                string
		start, end, indent int
	}{
		{"> | a | b |\n> |---|---|\n> | 1 | 2 |", 1, 3, 2},
		{"- item\n\n  a | b\n  --|--\n  c | d", 3, 5, 2},
		{"| a |\n|---|", 1, 2, 0},
	}
	for _, c := range cases {
		tb := ofKind(Parse(strings.Split(c.doc, "\n")), Table)
		if len(tb) != 1 || tb[0].Start != c.start || tb[0].End != c.end || tb[0].Indent != c.indent {
			t.Errorf("%q: %#v", c.doc, tb)
		}
	}
}

func TestTableCellImages(t *testing.T) {
	doc := strings.Split("| a | b |\n|---|---|\n| x | ![1](1.png) t ![2](2.png) |\n"+
		"| <img src=\"3.png\" alt=\"three\"> <img alt=nosrc> | [![4](4.png)](u) |", "\n")
	var got []string
	for _, b := range ofKind(Parse(doc), Image) {
		if b.Cell == nil {
			t.Fatalf("no cell: %#v", b)
		}
		got = append(got, fmt.Sprintf("%s@%d:%d,%d#%d/%d", b.Path, b.Start, b.Cell.Row, b.Cell.Col, b.Cell.Nth, b.Cell.Cols))
	}
	want := []string{"1.png@3:1,1#0/2", "2.png@3:1,1#1/2", "3.png@4:2,0#0/2", "4.png@4:2,1#0/2"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	// One image span per image block, in the same order.
	tb := ofKind(Parse(doc), Table)[0].Table
	var spans []string
	for _, row := range tb.Rows {
		for _, cell := range row {
			for _, sp := range cell {
				if strings.Contains(sp.Style, "image") {
					spans = append(spans, sp.Text)
				}
			}
		}
	}
	if !reflect.DeepEqual(spans, []string{"[1]", "[2]", "[three]", "[4]"}) {
		t.Fatalf("image spans %v", spans)
	}
}
