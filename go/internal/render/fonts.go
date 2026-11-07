package render

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	mermaid "github.com/lea/mermaid"
	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
)

// Fonts are the faces used for characters the built-in fonts lack. The
// parsed fonts are safe for concurrent use; every call makes a new face.
type Fonts struct {
	Regular *opentype.Font
	Bold    *opentype.Font // may equal Regular
}

// FontSpec names a font file and, for a collection (.ttc), its index.
type FontSpec struct {
	Path  string
	Index int
}

// LoadFonts loads the regular and bold fonts. An empty regular path asks
// fontconfig (fc-match) for a Japanese sans-serif font; with no fontconfig
// it returns nil, nil. An empty bold path uses the regular font, or
// fontconfig's bold match when the regular one came from fontconfig.
func LoadFonts(regular, bold FontSpec) (*Fonts, error) {
	auto := regular.Path == ""
	if auto {
		regular = fcMatch("sans-serif:lang=ja")
		if regular.Path == "" {
			return nil, nil
		}
		if bold.Path == "" {
			bold = fcMatch("sans-serif:lang=ja:bold")
		}
	}
	r, err := loadFont(regular)
	if err != nil {
		return nil, err
	}
	f := &Fonts{Regular: r, Bold: r}
	if bold.Path != "" {
		if b, err := loadFont(bold); err == nil {
			f.Bold = b
		} else if !auto {
			return nil, err
		}
	}
	return f, nil
}

func loadFont(s FontSpec) (*opentype.Font, error) {
	data, err := os.ReadFile(s.Path)
	if err != nil {
		return nil, err
	}
	if c, err := opentype.ParseCollection(data); err == nil {
		if s.Index < 0 || s.Index >= c.NumFonts() {
			return nil, fmt.Errorf("%s: font index %d out of range (%d fonts)", s.Path, s.Index, c.NumFonts())
		}
		return c.Font(s.Index)
	}
	f, err := opentype.Parse(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", s.Path, err)
	}
	return f, nil
}

func fcMatch(pattern string) FontSpec {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "fc-match", "-f", "%{file}\n%{index}", pattern).Output()
	if err != nil {
		return FontSpec{}
	}
	parts := strings.SplitN(string(bytes.TrimSpace(out)), "\n", 2)
	if len(parts) == 0 || parts[0] == "" {
		return FontSpec{}
	}
	s := FontSpec{Path: parts[0]}
	if len(parts) == 2 {
		s.Index, _ = strconv.Atoi(strings.TrimSpace(parts[1]))
	}
	return s
}

func newFace(f *opentype.Font, px float64) (font.Face, error) {
	return opentype.NewFace(f, &opentype.FaceOptions{Size: px, DPI: 72, Hinting: font.HintingNone})
}

// TextFace is dal.Options.TextFace.
func (f *Fonts) TextFace(px float64) (font.Face, error) { return newFace(f.Regular, px) }

// MermaidFunc is a dam Options.FontFunc. Italic falls back to upright.
func (f *Fonts) MermaidFunc() func(float64, mermaid.FontStyle) (font.Face, error) {
	return func(px float64, st mermaid.FontStyle) (font.Face, error) {
		if st == mermaid.Bold || st == mermaid.BoldItalic {
			return newFace(f.Bold, px)
		}
		return newFace(f.Regular, px)
	}
}
