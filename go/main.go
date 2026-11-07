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
	"runtime"
	"sync"
	"time"

	"github.com/Shougo/goda.vim/host"
	"github.com/Shougo/goda.vim/sdk"
	"github.com/lea/dal"
	mermaid "github.com/lea/mermaid"

	"mdview/internal/blocks"
	"mdview/internal/cache"
	"mdview/internal/imageload"
	"mdview/internal/render"
)

// renderVersion changes whenever this program draws differently, so that
// cached images are not reused.
const renderVersion = "1"

// scriptVersion must equal s:script_version in autoload/mdview.vim.
const scriptVersion = 2

const blockTimeout = 15 * time.Second

// flushInterval is how often finished blocks are sent while others are
// still being drawn.
const flushInterval = 200 * time.Millisecond

type plugin struct {
	mu    sync.Mutex
	fonts map[string]*render.Fonts // by font spec

	jobMu sync.Mutex
	jobs  map[int]*job // by buffer number: the running render of a buffer
}

type job struct{ cancel context.CancelFunc }

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
	ID           int      `json:"id"`
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
	InlineMath   int      `json:"inline_math"`
	Remote       int      `json:"remote"`
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
	// Pending: still being drawn; a later result replaces it.
	Pending bool `json:"pending,omitempty"`
	// Col, ColEnd: the byte range of inline math in its line (Text[0]
	// replaces it).
	Col    int `json:"col"`
	ColEnd int `json:"col_end"`
}

// render starts drawing a buffer and returns at once. The results go to
// mdview#apply (or req.Callback) as they come: first what is cached, then
// finished blocks every flushInterval, then all of them (final). A new
// request for the same buffer cancels the one running.
func (p *plugin) render(ctx context.Context, h sdk.Host, params []any) (any, error) {
	var req request
	if err := sdk.DecodeArgs(params, &req); err != nil {
		return nil, err
	}
	if err := check(req); err != nil {
		return nil, err
	}
	jctx, cancel := context.WithCancel(context.Background())
	j := &job{cancel: cancel}
	p.jobMu.Lock()
	if old := p.jobs[req.Bufnr]; old != nil {
		old.cancel()
	}
	if p.jobs == nil {
		p.jobs = map[int]*job{}
	}
	p.jobs[req.Bufnr] = j
	p.jobMu.Unlock()

	cb := req.Callback
	if cb == "" {
		cb = "mdview#apply"
	}
	send := func(results []result, final bool) error {
		if jctx.Err() != nil {
			return jctx.Err()
		}
		out, err := sdk.Generic(shown(results))
		if err != nil {
			return err
		}
		meta := map[string]any{"id": req.ID, "final": final}
		if _, err := h.Call(jctx, cb, req.Bufnr, req.Tick, out, meta); err != nil {
			return fmt.Errorf("%s: %w", cb, err)
		}
		return nil
	}
	go func() {
		defer func() {
			p.jobMu.Lock()
			if p.jobs[req.Bufnr] == j {
				delete(p.jobs, req.Bufnr)
			}
			p.jobMu.Unlock()
			cancel()
		}()
		if err := p.run(jctx, req, send); err != nil && jctx.Err() == nil {
			log.Printf("render: %v", err)
		}
	}()
	return nil, nil
}

func check(req request) error {
	if len(req.Cell) != 2 || req.Cell[0] <= 0 || req.Cell[1] <= 0 {
		return fmt.Errorf("invalid cell size %v", req.Cell)
	}
	if req.CacheDir == "" {
		return fmt.Errorf("no cache directory")
	}
	return nil
}

// shown drops the empty results (blocks with nothing to show).
func shown(results []result) []result {
	out := make([]result, 0, len(results))
	for _, r := range results {
		if r.Kind != "" {
			out = append(out, r)
		}
	}
	return out
}

// renderAll draws everything and returns the final results.
func (p *plugin) renderAll(ctx context.Context, req request) ([]result, error) {
	if err := check(req); err != nil {
		return nil, err
	}
	var out []result
	err := p.run(ctx, req, func(rs []result, final bool) error {
		if final {
			out = shown(rs)
		}
		return nil
	})
	return out, err
}

// run parses the buffer and calls send with the results: once with what is
// ready at once (cache hits, headings, inline math), then as blocks finish.
func (p *plugin) run(ctx context.Context, req request, send func([]result, bool) error) error {
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
	var todo []int
	for i, b := range bs {
		switch b.Kind {
		case blocks.Heading:
			results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End}
		case blocks.InlineMath:
			if req.InlineMath != 0 {
				if text, err := dal.RenderLine(b.Source, dal.LineOptions{}); err == nil && text != "" {
					results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End,
						Col: b.Col, ColEnd: b.ColEnd, Text: []string{text}}
				}
			}
		case blocks.Mermaid, blocks.Math, blocks.Image:
			r, done := prepare(req, blockStyle(st, b), b)
			if !done {
				r.Pending = true
				todo = append(todo, i)
			}
			results[i] = r
		}
	}
	if len(todo) == 0 {
		return send(results, true)
	}
	if err := send(results, false); err != nil {
		return err
	}

	type done struct {
		i int
		r result
	}
	ch := make(chan done, len(todo))
	sem := make(chan struct{}, max(1, runtime.NumCPU()))
	for _, i := range todo {
		b := bs[i]
		go func() {
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				ch <- done{i, results[i]}
				return
			}
			defer func() { <-sem }()
			bctx, cancel := context.WithTimeout(ctx, blockTimeout)
			defer cancel()
			bst := blockStyle(st, b)
			r, err := sdk.Guard(bctx, func() (result, error) {
				return draw(bctx, req, bst, b), nil
			})
			if err != nil {
				r = base(b)
				r.Error = err.Error()
			}
			ch <- done{i, r}
		}()
	}
	tick := time.NewTicker(flushInterval)
	defer tick.Stop()
	dirty := false
	for left := len(todo); left > 0; {
		select {
		case d := <-ch:
			results[d.i] = d.r
			left--
			dirty = true
		case <-tick.C:
			if dirty {
				if err := send(results, false); err != nil {
					return err
				}
				dirty = false
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return send(results, true)
}

func base(b blocks.Block) result {
	return result{Kind: string(b.Kind), Start: b.Start, End: b.End, Keep: b.Keep, Indent: b.Indent}
}

// blockStyle narrows the width for an indented block.
func blockStyle(st render.Style, b blocks.Block) render.Style {
	if b.Indent > 0 && st.MaxW > 0 {
		st.MaxW = max(st.CellW, st.MaxW-b.Indent*st.CellW)
	}
	return st
}

// cacheKey returns the cache key of a block, or an error to show for it.
// ok is false for an image mdview does not show (a URL with remote images
// off, an unknown scheme).
func cacheKey(req request, st render.Style, b blocks.Block) (key string, src imageload.Source, ok bool, err error) {
	keySrc, stamp := b.Source, ""
	if b.Kind == blocks.Image {
		src, ok = imageload.Resolve(req.Dir, b.Path)
		if !ok || (src.Remote && req.Remote == 0) {
			return "", src, false, nil
		}
		stamp, err = src.Stamp()
		if err != nil {
			return "", src, true, fmt.Errorf("image: %w", err)
		}
		keySrc = b.Path
	}
	key = cache.Key(renderVersion, mermaid.Version, dal.Version, string(b.Kind), keySrc, stamp,
		fmt.Sprint(st.CellW, st.CellH, st.MaxW, st.MaxH, st.Bg, st.Fg, req.MathSize, req.MermaidScale,
			req.Font, req.FontIndex, req.FontBold, req.FontBoldIdx))
	return key, src, true, nil
}

// prepare returns the result of a block when it needs no drawing (cached,
// or an error found at once); done is false when draw must run.
func prepare(req request, st render.Style, b blocks.Block) (r result, done bool) {
	r = base(b)
	key, _, ok, err := cacheKey(req, st, b)
	switch {
	case !ok:
		return result{}, true
	case err != nil:
		r.Error = err.Error()
		return r, true
	}
	if e, ok := cache.Load(req.CacheDir, key); ok {
		return withEntry(r, key, e, st), true
	}
	return r, false
}

// draw draws a block and stores it in the cache.
func draw(ctx context.Context, req request, st render.Style, b blocks.Block) result {
	r := base(b)
	key, src, ok, err := cacheKey(req, st, b)
	switch {
	case !ok:
		return result{}
	case err != nil:
		r.Error = err.Error()
		return r
	}
	var img image.Image
	switch b.Kind {
	case blocks.Mermaid:
		img, err = render.Mermaid(ctx, b.Source, st)
	case blocks.Math:
		img, err = render.Math(ctx, b.Source, st)
	case blocks.Image:
		img, err = imageload.Load(ctx, src, req.Remote != 0)
		if err != nil {
			err = fmt.Errorf("image: %w", err)
		}
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
