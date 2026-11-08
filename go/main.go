// Command mdview is the goda.vim binary of the mdview Vim plugin. It finds
// the mermaid diagrams, display math and images of a Markdown buffer, draws
// them into raw RGB files and tells Vim where they are.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"log"
	"os"
	"runtime"
	"strings"
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
const scriptVersion = 7

const blockTimeout = 15 * time.Second

// defaultTableImageRows is the height of an image in a table cell when the
// request does not say.
const defaultTableImageRows = 8

// flushInterval is how often finished blocks are sent while others are
// still being drawn.
const flushInterval = 200 * time.Millisecond

type plugin struct {
	mu    sync.Mutex
	fonts map[string]*render.Fonts // by font spec

	jobMu sync.Mutex
	jobs  map[int]*job // by buffer number: the running render of a buffer

	// Drawing is shared by cache key and outlives the job that started it:
	// while typing, each pause starts a new job and cancels the old one, but
	// a slow diagram keeps drawing and the next job waits for it. Failures
	// are remembered for failTTL so that they are not drawn again at every
	// pause.
	flightMu sync.Mutex
	flights  map[string]*flight
	failed   map[string]failure
}

type flight struct {
	done chan struct{}
	r    result
}

type failure struct {
	r  result
	at time.Time
}

// failTTL is how long a failed drawing is not tried again.
const failTTL = 30 * time.Second

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
	// TableImageRows caps the height of an image in a table cell, in rows.
	TableImageRows int `json:"table_image_rows"`
	// NoImages: return no results for diagrams, math and images (the
	// terminal cannot show images).
	NoImages int    `json:"no_images"`
	Callback string `json:"callback"`
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
	// Cell: [row, column, nth] of an image in a table cell (see
	// blocks.CellPos); Vim puts it in the cell.
	Cell []int `json:"cell,omitempty"`
	// Table: the cells of a table, laid out by Vim.
	Table *tableResult `json:"table,omitempty"`
	// Marks: the column of a quote's '>' on each of its lines, or -1.
	Marks []int  `json:"marks,omitempty"`
	Alert string `json:"alert,omitempty"`
	// A code block: its language, the column of each line's text (or -1),
	// and whether End is its closing fence.
	Lang   string `json:"lang,omitempty"`
	Cols   []int  `json:"cols,omitempty"`
	Closed bool   `json:"closed,omitempty"`
	// Spans: a paragraph's text, [text, style, source line] each.
	Spans [][]any `json:"spans,omitempty"`
}

// tableResult is a table for Vim: rows[row][column] is a list of
// [text, style] runs (see blocks.Span); lines[row] is the source line of the
// row.
type tableResult struct {
	Align []string        `json:"align"`
	Rows  [][][][2]string `json:"rows"`
	Lines []int           `json:"lines"`
}

// tableOf converts a table, with its inline math as text when inlineMath.
// spanText returns the text of a span: a formula as one line of text (with
// inlineMath) or as its source in $…$.
func spanText(sp blocks.Span, inlineMath bool) string {
	if !strings.Contains(sp.Style, "math") {
		return sp.Text
	}
	if inlineMath {
		if t, err := dal.RenderLine(sp.Text, dal.LineOptions{}); err == nil && t != "" {
			return t
		}
	}
	return "$" + sp.Text + "$"
}

func tableOf(t *blocks.TableData, inlineMath bool) *tableResult {
	out := &tableResult{Align: t.Align, Lines: t.Lines, Rows: make([][][][2]string, len(t.Rows))}
	for i, row := range t.Rows {
		out.Rows[i] = make([][][2]string, len(row))
		for j, cell := range row {
			out.Rows[i][j] = make([][2]string, 0, len(cell))
			for _, sp := range cell {
				out.Rows[i][j] = append(out.Rows[i][j], [2]string{spanText(sp, inlineMath), sp.Style})
			}
		}
	}
	return out
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
	seq := 0
	send := func(results []result, final bool) error {
		if jctx.Err() != nil {
			return jctx.Err()
		}
		// The results go through a file: Vim (9.2.1178) does not free a large
		// argument of a channel "call", so passing them directly leaks
		// memory at every drawing. Vim reads the file and deletes it.
		seq++
		path, err := writeResults(req, seq, shown(results))
		if err != nil {
			return err
		}
		meta := map[string]any{"id": req.ID, "final": final, "seq": seq}
		if _, err := h.Call(jctx, cb, req.Bufnr, req.Tick, path, meta); err != nil {
			os.Remove(path)
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

// writeResults writes results as JSON to a file in the cache directory and
// returns its path.
func writeResults(req request, seq int, results []result) (string, error) {
	data, err := json.Marshal(results)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(req.CacheDir, 0o755); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(req.CacheDir, fmt.Sprintf(".results-%d-%d-%d-*.json", req.Bufnr, req.ID, seq))
	if err != nil {
		return "", err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), f.Close()
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
		case blocks.Para:
			spans := make([][]any, 0, len(b.Spans))
			for _, sp := range b.Spans {
				spans = append(spans, []any{spanText(sp, req.InlineMath != 0), sp.Style, sp.Line})
			}
			results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End, Col: b.Col, Spans: spans}
		case blocks.Rule:
			results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End, Col: b.Col}
		case blocks.Code:
			results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End,
				Lang: b.Lang, Cols: b.Cols, Closed: b.Closed}
		case blocks.Quote:
			results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End, Marks: b.Marks, Alert: b.Alert}
		case blocks.Table:
			results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End, Indent: b.Indent,
				Table: tableOf(b.Table, req.InlineMath != 0)}
		case blocks.InlineMath:
			if req.InlineMath != 0 {
				if text, err := dal.RenderLine(b.Source, dal.LineOptions{}); err == nil && text != "" {
					results[i] = result{Kind: string(b.Kind), Start: b.Start, End: b.End,
						Col: b.Col, ColEnd: b.ColEnd, Text: []string{text}}
				}
			}
		case blocks.Mermaid, blocks.Math, blocks.Image:
			if req.NoImages != 0 {
				// Not drawn: Vim shows their source (a cell image, its [alt]).
				continue
			}
			r, done := p.prepare(req, blockStyle(st, b, req.TableImageRows), b)
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
			ch <- done{i, p.drawShared(ctx, req, blockStyle(st, b, req.TableImageRows), b)}
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
	r := result{Kind: string(b.Kind), Start: b.Start, End: b.End, Keep: b.Keep, Indent: b.Indent}
	if c := b.Cell; c != nil {
		r.Cell = []int{c.Row, c.Col, c.Nth}
	}
	return r
}

// blockStyle narrows the width for an indented block, and for an image
// with a width attribute (<img width="…">).
func blockStyle(st render.Style, b blocks.Block, tableRows int) render.Style {
	if c := b.Cell; c != nil {
		// An image in a table cell: at most an equal share of the width
		// (less the table's borders and padding), and tableRows rows high.
		if st.MaxW > 0 && c.Cols > 0 {
			st.MaxW = max(st.CellW, (st.MaxW-(c.Cols*3+1)*st.CellW)/c.Cols)
		}
		if tableRows <= 0 {
			tableRows = defaultTableImageRows
		}
		st.MaxH = tableRows * st.CellH
		if b.Width > 0 && b.Width < st.MaxW {
			st.MaxW = b.Width
		}
		return st
	}
	if b.Indent > 0 && st.MaxW > 0 {
		st.MaxW = max(st.CellW, st.MaxW-b.Indent*st.CellW)
	}
	if b.Width > 0 && (st.MaxW == 0 || b.Width < st.MaxW) {
		st.MaxW = b.Width
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
func (p *plugin) prepare(req request, st render.Style, b blocks.Block) (r result, done bool) {
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
	p.flightMu.Lock()
	f, ok := p.failed[key]
	p.flightMu.Unlock()
	if ok && time.Since(f.at) < failTTL {
		return rebase(f.r, b), true
	}
	return r, false
}

// rebase puts the drawing of a result (made for one block) onto block b,
// which has the same cache key but may be on other lines.
func rebase(d result, b blocks.Block) result {
	r := base(b)
	r.Key, r.Path, r.W, r.H, r.Rows, r.Text, r.Error = d.Key, d.Path, d.W, d.H, d.Rows, d.Text, d.Error
	return r
}

// drawShared draws b, sharing the drawing with any other job that needs the
// same cache key. The drawing runs on its own context (bounded by
// blockTimeout), so canceling ctx only stops the waiting.
func (p *plugin) drawShared(ctx context.Context, req request, st render.Style, b blocks.Block) result {
	key, _, ok, err := cacheKey(req, st, b)
	if !ok || err != nil {
		return draw(ctx, req, st, b)
	}
	p.flightMu.Lock()
	f := p.flights[key]
	if f == nil {
		f = &flight{done: make(chan struct{})}
		if p.flights == nil {
			p.flights = map[string]*flight{}
		}
		p.flights[key] = f
		go func() {
			dctx, cancel := context.WithTimeout(context.Background(), blockTimeout)
			defer cancel()
			r, err := sdk.Guard(dctx, func() (result, error) {
				return draw(dctx, req, st, b), nil
			})
			if err != nil {
				r = base(b)
				r.Error = err.Error()
			}
			p.flightMu.Lock()
			f.r = r
			delete(p.flights, key)
			if r.Error != "" {
				if p.failed == nil {
					p.failed = map[string]failure{}
				}
				p.failed[key] = failure{r: r, at: time.Now()}
			} else {
				delete(p.failed, key)
			}
			p.flightMu.Unlock()
			close(f.done)
		}()
	}
	p.flightMu.Unlock()
	select {
	case <-f.done:
		return rebase(f.r, b)
	case <-ctx.Done():
		r := base(b)
		r.Pending = true
		return r
	}
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
