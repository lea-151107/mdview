// Package render turns mdview blocks into raw RGB images sized for terminal
// cells: mermaid with dam, math with dal, and image files with the standard
// decoders.
package render

import (
	"context"
	"errors"
	"image"
	"image/color"
	"image/draw"
	"strings"

	"github.com/lea/dal"
	mermaid "github.com/lea/mermaid"
	xdraw "golang.org/x/image/draw"
)

// Style says how and how large to draw.
type Style struct {
	Bg, Fg       color.RGBA
	CellW, CellH int     // terminal cell size in pixels
	MaxW, MaxH   int     // largest image in pixels
	MathSizePx   float64 // em size for math; 0 picks one from CellH
	MermaidScale float64 // dam Scale; 0 picks one from CellH
	Fonts        *Fonts  // fonts for characters the built-in ones lack; may be nil
}

func (s Style) mathSize() float64 {
	if s.MathSizePx > 0 {
		return s.MathSizePx
	}
	return float64(s.CellH) * 1.1
}

func (s Style) mermaidScale() float64 {
	if s.MermaidScale > 0 {
		return s.MermaidScale
	}
	// The built-in text is 14px × Scale; aim for about the terminal's text size.
	v := float64(s.CellH) * 0.8 / 14
	if v < 0.5 {
		v = 0.5
	}
	return v
}

// Mermaid draws a diagram. Labels the built-in font cannot draw (Japanese,
// say) are retried with Fonts.
func Mermaid(ctx context.Context, src string, st Style) (image.Image, error) {
	opt := mermaid.Options{
		MaxWidth:   st.MaxW,
		Scale:      st.mermaidScale(),
		Foreground: st.Fg,
		Background: nil,
	}
	img, err := mermaid.Render(ctx, src, opt)
	if errors.Is(err, mermaid.ErrUnsupported) && st.Fonts != nil {
		opt.FontFunc = st.Fonts.MermaidFunc()
		if img2, err2 := mermaid.Render(ctx, src, opt); err2 == nil {
			return img2, nil
		}
	}
	return img, err
}

// MermaidText draws a diagram with box-drawing characters.
func MermaidText(ctx context.Context, src string, cols int) ([]string, error) {
	return mermaid.RenderText(ctx, src, mermaid.TextOptions{MaxCols: cols})
}

// Math draws a display formula. A formula wider than MaxW is drawn at its
// natural size and scaled down by Finish.
func Math(ctx context.Context, src string, st Style) (image.Image, error) {
	opt := dal.Options{
		Display:    true,
		SizePx:     st.mathSize(),
		Foreground: st.Fg,
		PaddingPx:  2,
	}
	if st.Fonts != nil {
		opt.TextFace = st.Fonts.TextFace
	}
	res, err := dal.Render(ctx, src, opt)
	if err != nil {
		return nil, err
	}
	return res.Image, nil
}

// MathText draws a formula with box-drawing characters.
func MathText(ctx context.Context, src string, cols int) ([]string, error) {
	res, err := dal.RenderText(ctx, src, dal.TextOptions{Display: true, MaxCols: cols})
	if err != nil {
		return nil, err
	}
	return res.Lines, nil
}

// Finish scales img down to fit MaxW × MaxH (never up), flattens it onto Bg
// and pads it with Bg to whole cells. It returns packed RGB bytes.
func Finish(img image.Image, st Style) (rgb []byte, w, h int) {
	b := img.Bounds()
	sw, sh := b.Dx(), b.Dy()
	dw, dh := fit(sw, sh, st.MaxW, st.MaxH)
	cw, ch := max(st.CellW, 1), max(st.CellH, 1)
	w = (dw + cw - 1) / cw * cw
	h = (dh + ch - 1) / ch * ch
	canvas := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.Draw(canvas, canvas.Bounds(), &image.Uniform{st.Bg}, image.Point{}, draw.Src)
	dst := image.Rect(0, 0, dw, dh)
	if dw == sw && dh == sh {
		draw.Draw(canvas, dst, img, b.Min, draw.Over)
	} else {
		xdraw.CatmullRom.Scale(canvas, dst, img, b, draw.Over, nil)
	}
	rgb = make([]byte, 0, w*h*3)
	for y := 0; y < h; y++ {
		row := canvas.Pix[y*canvas.Stride : y*canvas.Stride+w*4]
		for x := 0; x < w*4; x += 4 {
			rgb = append(rgb, row[x], row[x+1], row[x+2])
		}
	}
	return rgb, w, h
}

func fit(w, h, maxW, maxH int) (int, int) {
	r := 1.0
	if maxW > 0 && w > maxW {
		r = float64(maxW) / float64(w)
	}
	if maxH > 0 && float64(h)*r > float64(maxH) {
		r = float64(maxH) / float64(h)
	}
	if r >= 1 {
		return w, h
	}
	return max(1, int(float64(w)*r)), max(1, int(float64(h)*r))
}

// ShortError returns the first line of err without the library prefix.
func ShortError(err error) string {
	s := err.Error()
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}
