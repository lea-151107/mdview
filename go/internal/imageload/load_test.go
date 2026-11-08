package imageload

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"golang.org/x/image/bmp"
)

func pngBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, w, h))); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func load(t *testing.T, dir, dest string, remote bool) (image.Image, error) {
	t.Helper()
	s, ok := Resolve(dir, dest)
	if !ok {
		t.Fatalf("Resolve(%q) not ok", dest)
	}
	return Load(context.Background(), s, remote)
}

func TestBMP(t *testing.T) {
	dir := t.TempDir()
	var b bytes.Buffer
	if err := bmp.Encode(&b, image.NewRGBA(image.Rect(0, 0, 5, 3))); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "a.bmp"), b.Bytes(), 0o644)
	img, err := load(t, dir, "a.bmp", false)
	if err != nil || img.Bounds().Dx() != 5 {
		t.Fatalf("%v %v", img, err)
	}
}

func TestSVG(t *testing.T) {
	if _, err := exec.LookPath("rsvg-convert"); err != nil {
		t.Skip("no rsvg-convert")
	}
	dir := t.TempDir()
	svg := `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="red"/></svg>`
	os.WriteFile(filepath.Join(dir, "a.svg"), []byte(svg), 0o644)
	img, err := load(t, dir, "a.svg", false)
	if err != nil || img.Bounds().Dx() != 20 || img.Bounds().Dy() != 10 {
		t.Fatalf("%v %v", img, err)
	}
}

func TestDataURL(t *testing.T) {
	dest := "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngBytes(t, 4, 2))
	img, err := load(t, "", dest, false)
	if err != nil || img.Bounds().Dx() != 4 {
		t.Fatalf("%v %v", img, err)
	}
}

func TestRemote(t *testing.T) {
	data := pngBytes(t, 6, 6)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/big" {
			w.Write(make([]byte, MaxRemoteBytes+10))
			return
		}
		w.Write(data)
	}))
	defer srv.Close()
	if _, err := load(t, "", srv.URL+"/a.png", false); !errors.Is(err, ErrRemoteDisabled) {
		t.Fatalf("disabled: %v", err)
	}
	img, err := load(t, "", srv.URL+"/a.png", true)
	if err != nil || img.Bounds().Dx() != 6 {
		t.Fatalf("%v %v", img, err)
	}
	if _, err := load(t, "", srv.URL+"/big", true); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("big: %v", err)
	}
}

func TestResolve(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "my pic.png"), pngBytes(t, 1, 1), 0o644)
	s, ok := Resolve(dir, "my%20pic.png")
	if !ok || s.Path != filepath.Join(dir, "my pic.png") {
		t.Fatalf("%+v %v", s, ok)
	}
	if _, ok := Resolve(dir, "ftp://x/y.png"); ok {
		t.Fatal("ftp accepted")
	}
	if s, ok := Resolve(dir, "https://x/y.png"); !ok || !s.Remote {
		t.Fatalf("https: %+v", s)
	}
	st1, _ := s.Stamp()
	if st1 == "" {
		t.Fatal("empty stamp")
	}
}
