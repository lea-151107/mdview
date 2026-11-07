package main

import (
	"context"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"
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
