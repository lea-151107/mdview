package render

import (
	"context"
	"image"
	"image/color"
	"testing"
)

var style = Style{
	Bg: color.RGBA{10, 20, 30, 255}, Fg: color.RGBA{230, 230, 230, 255},
	CellW: 9, CellH: 18, MaxW: 600, MaxH: 400,
}

func checkRGB(t *testing.T, img image.Image) {
	t.Helper()
	rgb, w, h := Finish(img, style)
	if w%style.CellW != 0 || h%style.CellH != 0 {
		t.Fatalf("size %dx%d not whole cells", w, h)
	}
	if w > style.MaxW+style.CellW || h > style.MaxH+style.CellH {
		t.Fatalf("size %dx%d exceeds max", w, h)
	}
	if len(rgb) != w*h*3 {
		t.Fatalf("len %d, want %d", len(rgb), w*h*3)
	}
	// The padding at the bottom right is the background.
	i := len(rgb) - 3
	if rgb[i] != 10 || rgb[i+1] != 20 || rgb[i+2] != 30 {
		t.Fatalf("corner %v, want background", rgb[i:])
	}
}

func TestMermaid(t *testing.T) {
	img, err := Mermaid(context.Background(), "graph TD\n  A-->B", style)
	if err != nil {
		t.Fatal(err)
	}
	checkRGB(t, img)
}

func TestMath(t *testing.T) {
	img, err := Math(context.Background(), `\sum_{i=1}^n \frac{1}{i^2}`, style)
	if err != nil {
		t.Fatal(err)
	}
	checkRGB(t, img)
}

func TestMathTextFallback(t *testing.T) {
	lines, err := MathText(context.Background(), `\frac{a}{b}`, 80)
	if err != nil || len(lines) != 3 {
		t.Fatalf("%q %v", lines, err)
	}
}

func TestFinishScalesDown(t *testing.T) {
	big := image.NewRGBA(image.Rect(0, 0, 3000, 1000))
	_, w, h := Finish(big, style)
	if w > 600+9 || h > 400+18 || w < 590 {
		t.Fatalf("got %dx%d", w, h)
	}
}

func TestJapaneseMermaid(t *testing.T) {
	f, err := LoadFonts(FontSpec{}, FontSpec{})
	if err != nil || f == nil {
		t.Skip("no Japanese font:", err)
	}
	st := style
	st.Fonts = f
	if _, err := Mermaid(context.Background(), "graph TD\n  A[開始]-->B[終了]", st); err != nil {
		t.Fatal(err)
	}
	if _, err := Math(context.Background(), `x \text{ただし} y`, st); err != nil {
		t.Fatal(err)
	}
}
