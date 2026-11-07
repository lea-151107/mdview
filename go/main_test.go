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
