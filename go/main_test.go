package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"mdview/internal/blocks"
	"mdview/internal/render"
)

func TestRenderAll(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	f, err := os.Create(filepath.Join(dir, "pic.png"))
	if err != nil {
		t.Fatal(err)
	}
	png.Encode(f, image.NewRGBA(image.Rect(0, 0, 40, 30)))
	f.Close()

	req := request{
		Lines: []string{
			"```mermaid", "graph TD", "  A-->B", "```",
			"$$ \\frac{a}{b} $$",
			"![p](pic.png)",
			"![remote](https://example.com/x.png)",
			"![missing](nope.png)",
			"```mermaid", "graph TD", "  A-->", "```",
		},
		Dir: dir, CacheDir: cacheDir, Cell: []int{8, 16}, WidthPx: 640, HeightPx: 480,
		Bg: []int{0, 0, 0}, Fg: []int{255, 255, 255},
	}
	p := &plugin{}
	for round := 0; round < 2; round++ { // the second round reads the cache
		res, err := p.renderAll(context.Background(), req)
		if err != nil {
			t.Fatal(err)
		}
		if len(res) != 5 {
			t.Fatalf("got %d results: %+v", len(res), res)
		}
		for _, r := range res[:3] {
			if r.Error != "" || r.Path == "" || r.Rows != r.H/16 || r.W%8 != 0 {
				t.Fatalf("round %d: bad result %+v", round, r)
			}
			if st, err := os.Stat(r.Path); err != nil || st.Size() != int64(r.W*r.H*3) {
				t.Fatalf("cache file: %v", err)
			}
		}
		if res[2].W != 40 || res[2].H != 32 {
			t.Fatalf("image size %dx%d", res[2].W, res[2].H)
		}
		if res[3].Error == "" || res[3].Start != 8 {
			t.Fatalf("missing image: %+v", res[3])
		}
		if res[4].Error == "" || res[4].Start != 9 || res[4].End != 12 {
			t.Fatalf("broken mermaid: %+v", res[4])
		}
	}
}

func TestRunProgressive(t *testing.T) {
	dir := t.TempDir()
	req := request{
		Lines: []string{"# T", "```mermaid", "graph TD", "  A-->B", "```", "a $x^2$ b"},
		Dir:   dir, CacheDir: filepath.Join(dir, "cache"), Cell: []int{8, 16}, WidthPx: 640, HeightPx: 480,
		Bg: []int{0, 0, 0}, Fg: []int{255, 255, 255}, InlineMath: 1,
	}
	type call struct {
		rs    []result
		final bool
	}
	var calls []call
	p := &plugin{}
	collect := func(rs []result, final bool) error {
		calls = append(calls, call{shown(rs), final})
		return nil
	}
	if err := p.run(context.Background(), req, collect); err != nil {
		t.Fatal(err)
	}
	if len(calls) < 2 || calls[0].final || !calls[len(calls)-1].final {
		t.Fatalf("calls: %+v", calls)
	}
	first := calls[0].rs
	if len(first) != 3 || first[0].Kind != "heading" || !first[1].Pending || first[2].Kind != "inline_math" {
		t.Fatalf("first: %+v", first)
	}
	if first[2].Text[0] != "x²" || first[2].Col != 2 || first[2].ColEnd != 7 {
		t.Fatalf("inline math: %+v", first[2])
	}
	last := calls[len(calls)-1].rs
	if last[1].Pending || last[1].Path == "" {
		t.Fatalf("last: %+v", last[1])
	}

	// Drawn again: everything comes from the cache in one final call.
	calls = nil
	if err := p.run(context.Background(), req, collect); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || !calls[0].final {
		t.Fatalf("cached: %+v", calls)
	}

	// Inline math off.
	calls = nil
	req.InlineMath = 0
	if err := p.run(context.Background(), req, collect); err != nil {
		t.Fatal(err)
	}
	for _, r := range calls[0].rs {
		if r.Kind == "inline_math" {
			t.Fatalf("inline math with InlineMath 0: %+v", r)
		}
	}
}

func TestRunCanceled(t *testing.T) {
	dir := t.TempDir()
	req := request{
		Lines: []string{"```mermaid", "graph TD", "  A-->B", "```"},
		Dir:   dir, CacheDir: filepath.Join(dir, "cache"), Cell: []int{8, 16}, WidthPx: 640, HeightPx: 480,
	}
	ctx, cancel := context.WithCancel(context.Background())
	var finals int
	err := (&plugin{}).run(ctx, req, func(rs []result, final bool) error {
		cancel() // canceled after the first (partial) send
		if final {
			finals++
		}
		return nil
	})
	if finals != 0 && err == nil {
		// The block may finish before the cancel is seen; both are fine,
		// but a canceled run must not report success without a final call.
		return
	}
	if err == nil {
		t.Fatal("no error and no final call")
	}
}

// A drawing outlives the job that started it, so a canceled job (a pause
// while typing) does not throw away a slow diagram.
func TestDrawSharedOutlivesCancel(t *testing.T) {
	dir := t.TempDir()
	req := request{Dir: dir, CacheDir: filepath.Join(dir, "cache"), Cell: []int{8, 16}, WidthPx: 640, HeightPx: 480}
	b := blocks.Block{Kind: blocks.Mermaid, Start: 1, End: 4, Source: "graph TD\n  A-->B"}
	st := render.Style{CellW: 8, CellH: 16, MaxW: 640, MaxH: 480}
	p := &plugin{}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if r := p.drawShared(ctx, req, st, b); !r.Pending && r.Path == "" {
		t.Fatalf("canceled wait: %+v", r)
	}
	// The drawing finishes anyway and lands in the cache.
	for i := 0; i < 100; i++ {
		if r, done := p.prepare(req, st, b); done {
			if r.Path == "" {
				t.Fatalf("cached result: %+v", r)
			}
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("never cached")
}

func TestFailureRemembered(t *testing.T) {
	dir := t.TempDir()
	req := request{Dir: dir, CacheDir: filepath.Join(dir, "cache"), Cell: []int{8, 16}, WidthPx: 640, HeightPx: 480}
	b := blocks.Block{Kind: blocks.Mermaid, Start: 1, End: 3, Source: "graph TD\n  A -->"}
	st := render.Style{CellW: 8, CellH: 16, MaxW: 640, MaxH: 480}
	p := &plugin{}
	if r := p.drawShared(context.Background(), req, st, b); r.Error == "" {
		t.Fatalf("want an error: %+v", r)
	}
	// The same block on other lines: answered from memory, without drawing.
	moved := b
	moved.Start, moved.End = 10, 12
	r, done := p.prepare(req, st, moved)
	if !done || r.Error == "" || r.Start != 10 {
		t.Fatalf("remembered: %+v %v", r, done)
	}
}

func TestImgWidthNarrows(t *testing.T) {
	st := blockStyle(render.Style{CellW: 8, MaxW: 640}, blocks.Block{Kind: blocks.Image, Width: 200, Indent: 2})
	if st.MaxW != 200 {
		t.Fatalf("MaxW %d", st.MaxW)
	}
}

// TestContract writes what "render" returns for a small document to
// ../test/contract.json (MDVIEW_UPDATE=1) or checks it is unchanged. The Vim
// tests read the same file into s:build_view, so a renamed field on either
// side fails a test.
func TestContract(t *testing.T) {
	dir := t.TempDir()
	png0, _ := os.Create(filepath.Join(dir, "a.png"))
	png.Encode(png0, image.NewRGBA(image.Rect(0, 0, 16, 16)))
	png0.Close()
	lines := []string{
		"# Title",
		"```mermaid", "graph TD", "  A-->B", "```",
		"text $x^2$ and ![a](a.png) here",
		"| ![a](a.png) | cell |",
		"> ![a](a.png)",
		"```mermaid", "graph TD", "  A -->", "```",
	}
	req := request{Lines: lines, Dir: dir, CacheDir: filepath.Join(dir, "cache"), Cell: []int{8, 16},
		WidthPx: 640, HeightPx: 480, InlineMath: 1}
	rs, err := (&plugin{}).renderAll(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	// Keep the fields, not the values that depend on the renderers.
	for i := range rs {
		if rs[i].Path != "" {
			rs[i].Key, rs[i].Path, rs[i].W, rs[i].H, rs[i].Rows = fmt.Sprintf("k%d", i), "/x", 16, 32, 2
		}
		if rs[i].Error != "" {
			rs[i].Error = "error"
		}
	}
	got, err := json.MarshalIndent(map[string]any{"lines": lines, "results": rs}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	golden := filepath.Join("..", "test", "contract.json")
	if os.Getenv("MDVIEW_UPDATE") != "" {
		if err := os.WriteFile(golden, append(got, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("%v (run with MDVIEW_UPDATE=1)", err)
	}
	if string(bytes.TrimSpace(want)) != string(got) {
		t.Fatalf("contract changed; check test/test_contract.vim and run with MDVIEW_UPDATE=1\n%s", got)
	}
}
