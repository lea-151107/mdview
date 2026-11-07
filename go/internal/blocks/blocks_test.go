package blocks

import (
	"reflect"
	"strings"
	"testing"
)

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
	got := Parse(doc)
	want := []Block{
		{Kind: Mermaid, Start: 2, End: 5, Source: "graph TD\n  A-->B"},
		{Kind: Math, Start: 7, End: 7, Source: `\frac{a}{b}`},
		{Kind: Math, Start: 8, End: 11, Source: "\\sum_{i=1}^n i\n= \\frac{n(n+1)}{2}"},
		{Kind: Image, Start: 12, End: 12, Path: "img/cat.png", Alt: "cat"},
		{Kind: Math, Start: 18, End: 18, Source: "x^2"},
		{Kind: Math, Start: 19, End: 21, Source: "E = mc^2"},
		{Kind: Image, Start: 22, End: 22, Path: "my pic.png", Alt: "sp"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got\n%#v\nwant\n%#v", got, want)
	}
}

func TestUnclosedFence(t *testing.T) {
	got := Parse([]string{"```mermaid", "graph TD", "![x](y.png)"})
	if len(got) != 0 {
		t.Fatalf("got %#v", got)
	}
}

func TestLongerClosingFence(t *testing.T) {
	got := Parse([]string{"```mermaid", "graph TD", "``", "`````"})
	if len(got) != 1 || got[0].End != 4 || got[0].Source != "graph TD\n``" {
		t.Fatalf("got %#v", got)
	}
}
