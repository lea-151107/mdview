// Command mdview is the goda.vim binary of the mdview Vim plugin. It finds
// the mermaid diagrams, display math and images of a Markdown buffer, draws
// them into raw RGB files and tells Vim where they are.
package main

import (
	"context"
	"fmt"
	"image"
	"image/color"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Shougo/goda.vim/host"
	"github.com/Shougo/goda.vim/sdk"
	"github.com/lea/dal"
	mermaid "github.com/lea/mermaid"

	"mdview/internal/blocks"
	"mdview/internal/cache"
	"mdview/internal/render"
)

// renderVersion changes whenever this program draws differently, so that
// cached images are not reused.
const renderVersion = "1"

// scriptVersion must equal s:script_version in autoload/mdview.vim.
const scriptVersion = 2

const blockTimeout = 15 * time.Second

type plugin struct {
	mu    sync.Mutex
	fonts map[string]*render.Fonts // by font spec
}

func (*plugin) Name() string       { return "mdview" }
func (*plugin) ScriptVersion() int { return scriptVersion }

func (p *plugin) Handlers() map[string]sdk.Handler {
	return map[string]sdk.Handler{
		"render": p.render,
		"prune":  p.prune,
	}
}

// request is what autoload/mdview.vim sends to "render".
type request struct {
	Bufnr        int      `json:"bufnr"`
	Tick         int      `json:"tick"`
	Lines        []string `json:"lines"`
	Dir          string   `json:"dir"`
	CacheDir     string   `json:"cache_dir"`
	Cell         []int    `json:"cell"`
	WidthPx      int      `json:"width_px"`
	HeightPx     int      `json:"height_px"`
	Bg           []int    `json:"bg"`
	Fg           []int    `json:"fg"`
	MathSize     float64  `json:"math_size"`
	MermaidScale float64  `json:"mermaid_scale"`
	Font         string   `json:"font"`
	FontIndex    int      `json:"font_index"`
	FontBold     string   `json:"font_bold"`
	FontBoldIdx  int      `json:"font_bold_index"`
	Callback     string   `json:"callback"`
}

// result is one block as returned to Vim.
type result struct {
	Kind  string   `json:"kind"`
	Start int      `json:"start"`
	End   int      `json:"end"`
	Key   string   `json:"key,omitempty"`
	Path  string   `json:"path,omitempty"`
	W     int      `json:"w,omitempty"`
	H     int      `json:"h,omitempty"`
	Rows  int      `json:"rows,omitempty"`
	Text  []string `json:"text,omitempty"`
	Error string   `json:"error,omitempty"`
	// Keep: the lines stay and the image goes below them (an image inside
	// text). Indent: columns to shift the image right (quotes, lists).
	Keep   bool `json:"keep,omitempty"`
	Indent int  `json:"indent,omitempty"`
}

func (p *plugin) render(ctx context.Context, h sdk.Host, params []any) (any, error) {
	var req request
	if err := sdk.DecodeArgs(params, &req); err != nil {
		return nil, err
	}
	results, err := p.renderAll(ctx, req)
	if err != nil {
		return nil, err
	}
	out, err := sdk.Generic(results)
	if err != nil {
		return nil, err
	}
	cb := req.Callback
	if cb == "" {
		cb = "mdview#apply"
	}
	if _, err := h.Call(ctx, cb, req.Bufnr, req.Tick, out); err != nil {
		return nil, fmt.Errorf("%s: %w", cb, err)
	}
	return nil, nil
}

func (p *plugin) renderAll(ctx context.Context, req request) ([]result, error) {
	if len(req.Cell) != 2 || req.Cell[0] <= 0 || req.Cell[1] <= 0 {
		return nil, fmt.Errorf("invalid cell size %v", req.Cell)
	}
	if req.CacheDir == "" {
		return nil, fmt.Errorf("no cache directory")
	}
	st := render.Style{
		Bg:           rgba(req.Bg, color.RGBA{0, 0, 0, 255}),
		Fg:           rgba(req.Fg, color.RGBA{220, 220, 220, 255}),
		CellW:        req.Cell[0],
		CellH:        req.Cell[1],
		MaxW:         req.WidthPx,
		MaxH:         req.HeightPx,
		MathSizePx:   req.MathSize,
		MermaidScale: req.MermaidScale,
	}
	fonts, err := p.loadFonts(req)
	if err != nil {
		log.Printf("fonts: %v", err)
	}
	st.Fonts = fonts

	bs := blocks.Parse(req.Lines)
	results := make([]result, len(bs))
	sem := make(chan struct{}, max(1, runtime.NumCPU()))
	var wg sync.WaitGroup
	for i, b := range bs {
		switch b.Kind {
		case blocks.Heading:
			results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End}
			continue
		case blocks.Mermaid, blocks.Math, blocks.Image:
		default:
			continue // not shown yet
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			bctx, cancel := context.WithTimeout(ctx, blockTimeout)
			defer cancel()
			r, err := sdk.Guard(bctx, func() (result, error) {
				return renderBlock(bctx, req, st, b), nil
			})
			if err != nil {
				r = result{Kind: string(b.Kind), Start: b.Start, End: b.End, Keep: b.Keep,
					Indent: b.Indent, Error: err.Error()}
			}
			results[i] = r
		}()
	}
	wg.Wait()
	// Drop images that are not files we can draw (URLs): they get nothing.
	out := results[:0]
	for _, r := range results {
		if r.Kind != "" {
			out = append(out, r)
		}
	}
	return out, nil
}

func renderBlock(ctx context.Context, req request, st render.Style, b blocks.Block) result {
	r := result{Kind: string(b.Kind), Start: b.Start, End: b.End, Keep: b.Keep, Indent: b.Indent}
	if b.Indent > 0 && st.MaxW > 0 {
		st.MaxW = max(st.CellW, st.MaxW-b.Indent*st.CellW)
	}
	var keySrc, stamp string
	var path string
	switch b.Kind {
	case blocks.Image:
		path = resolveImage(req.Dir, b.Path)
		if path == "" {
			return result{} // remote or data: URL
		}
		info, err := os.Stat(path)
		if err != nil {
			r.Error = fmt.Sprintf("image: %v", err)
			return r
		}
		keySrc = path
		stamp = info.ModTime().UTC().Format(time.RFC3339Nano) + "/" + strconv.FormatInt(info.Size(), 10)
	default:
		keySrc = b.Source
	}
	key := cache.Key(renderVersion, mermaid.Version, dal.Version, string(b.Kind), keySrc, stamp,
		fmt.Sprint(st.CellW, st.CellH, st.MaxW, st.MaxH, st.Bg, st.Fg, req.MathSize, req.MermaidScale,
			req.Font, req.FontIndex, req.FontBold, req.FontBoldIdx))
	if e, ok := cache.Load(req.CacheDir, key); ok {
		return withEntry(r, key, e, st)
	}

	var img image.Image
	var err error
	switch b.Kind {
	case blocks.Mermaid:
		img, err = render.Mermaid(ctx, b.Source, st)
	case blocks.Math:
		img, err = render.Math(ctx, b.Source, st)
	case blocks.Image:
		img, err = render.ImageFile(path)
	}
	if err != nil {
		r.Error = render.ShortError(err)
		r.Text = fallbackText(ctx, b, st)
		return r
	}
	rgb, w, h := render.Finish(img, st)
	e, err := cache.Store(req.CacheDir, key, rgb, w, h)
	if err != nil {
		r.Error = fmt.Sprintf("cache: %v", err)
		return r
	}
	return withEntry(r, key, e, st)
}

func withEntry(r result, key string, e cache.Entry, st render.Style) result {
	r.Key = key
	r.Path = e.Path
	r.W, r.H = e.W, e.H
	r.Rows = (e.H + st.CellH - 1) / st.CellH
	return r
}

func fallbackText(ctx context.Context, b blocks.Block, st render.Style) []string {
	cols := 0
	if st.CellW > 0 && st.MaxW > 0 {
		cols = st.MaxW / st.CellW
	}
	var lines []string
	var err error
	switch b.Kind {
	case blocks.Mermaid:
		lines, err = render.MermaidText(ctx, b.Source, cols)
	case blocks.Math:
		lines, err = render.MathText(ctx, b.Source, cols)
	default:
		return nil
	}
	if err != nil {
		return nil
	}
	return lines
}

// resolveImage turns the path of ![](path) into a file name, or "" for a
// URL that is not a local file.
func resolveImage(dir, p string) string {
	switch {
	case strings.HasPrefix(p, "file://"):
		if u, err := url.Parse(p); err == nil {
			return u.Path
		}
		return ""
	case strings.Contains(p, "://"), strings.HasPrefix(p, "data:"):
		return ""
	}
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			p = filepath.Join(home, p[2:])
		}
	}
	if !filepath.IsAbs(p) {
		p = filepath.Join(dir, p)
	}
	if _, err := os.Stat(p); err != nil {
		if u, err := url.PathUnescape(p); err == nil {
			if _, err := os.Stat(u); err == nil {
				return u
			}
		}
	}
	return p
}

func (p *plugin) loadFonts(req request) (*render.Fonts, error) {
	spec := fmt.Sprint(req.Font, "\x00", req.FontIndex, "\x00", req.FontBold, "\x00", req.FontBoldIdx)
	p.mu.Lock()
	defer p.mu.Unlock()
	if f, ok := p.fonts[spec]; ok {
		return f, nil
	}
	f, err := render.LoadFonts(render.FontSpec{Path: req.Font, Index: req.FontIndex},
		render.FontSpec{Path: req.FontBold, Index: req.FontBoldIdx})
	if p.fonts == nil {
		p.fonts = map[string]*render.Fonts{}
	}
	p.fonts[spec] = f // remember failures too (as nil)
	return f, err
}

func (p *plugin) prune(ctx context.Context, h sdk.Host, params []any) (any, error) {
	var dir string
	days := 30.0
	if err := sdk.DecodeArgs(params, &dir, sdk.Optional(&days)); err != nil {
		return nil, err
	}
	if dir == "" {
		return nil, fmt.Errorf("no cache directory")
	}
	cache.Prune(dir, time.Duration(days*24*float64(time.Hour)))
	return nil, nil
}

func rgba(c []int, def color.RGBA) color.RGBA {
	if len(c) != 3 {
		return def
	}
	cl := func(v int) uint8 { return uint8(min(255, max(0, v))) }
	return color.RGBA{cl(c[0]), cl(c[1]), cl(c[2]), 255}
}

func main() { host.Main(&plugin{}) }
