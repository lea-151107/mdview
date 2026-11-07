// Package imageload reads the images a Markdown document refers to: local
// files (PNG, JPEG, GIF, WebP, BMP, and SVG through rsvg-convert), data URLs
// and, when enabled, http(s) URLs. Based on gvmd's internal/imageload.
package imageload

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"image"
	_ "image/gif" // register decoders
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "golang.org/x/image/bmp"
	_ "golang.org/x/image/webp"
)

const (
	// MaxFileBytes bounds the size of an image file.
	MaxFileBytes = 50 << 20
	// MaxRemoteBytes bounds the size of a downloaded image.
	MaxRemoteBytes = 20 << 20
	// MaxPixels bounds the decoded size of an image, checked before
	// decoding so that a small file cannot expand into gigabytes.
	MaxPixels = 40_000_000
	// svgWidthPx is the width SVG images are rasterized at (then scaled
	// down to the window).
	svgWidthPx = 1600
	// remoteTimeout bounds one download.
	remoteTimeout = 10 * time.Second
	// svgTimeout bounds one rsvg-convert run.
	svgTimeout = 10 * time.Second
)

// Errors returned by Load.
var (
	ErrRemoteDisabled = errors.New("remote images are disabled (let g:mdview_remote = 1)")
	ErrTooLarge       = errors.New("image too large")
	ErrUnsupported    = errors.New("unsupported image format")
)

// Source is where an image comes from.
type Source struct {
	Dest   string // as written in the document
	Path   string // local file, or ""
	Remote bool   // an http(s) URL
	Data   bool   // a data: URL
}

// Resolve tells where dest (relative to dir) is. ok is false for a scheme
// mdview does not read.
func Resolve(dir, dest string) (s Source, ok bool) {
	s.Dest = dest
	switch {
	case strings.HasPrefix(dest, "data:"):
		s.Data = true
		return s, true
	case IsRemote(dest):
		s.Remote = true
		return s, true
	}
	p := dest
	if u, err := url.Parse(dest); err == nil && u.Scheme == "file" {
		p = u.Path
	} else if err == nil && len(u.Scheme) > 1 {
		return s, false
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
				p = u
			}
		}
	}
	s.Path = p
	return s, true
}

// IsRemote reports whether dest is an http(s) URL.
func IsRemote(dest string) bool {
	u, err := url.Parse(dest)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https")
}

// Stamp returns a string that changes when the image may have changed, for
// the cache key: the modification time and size of a file, the URL itself
// otherwise.
func (s Source) Stamp() (string, error) {
	if s.Path == "" {
		return s.Dest, nil
	}
	info, err := os.Stat(s.Path)
	if err != nil {
		return "", err
	}
	return s.Path + "/" + info.ModTime().UTC().Format(time.RFC3339Nano) + "/" + strconv.FormatInt(info.Size(), 10), nil
}

// Load reads and decodes the image. Remote images are fetched only when
// remote is true.
func Load(ctx context.Context, s Source, remote bool) (image.Image, error) {
	var data []byte
	var err error
	switch {
	case s.Data:
		data, err = decodeDataURL(s.Dest)
	case s.Remote:
		if !remote {
			return nil, ErrRemoteDisabled
		}
		data, err = fetch(ctx, s.Dest)
	default:
		data, err = readLimited(s.Path)
	}
	if err != nil {
		return nil, err
	}
	return decode(ctx, data)
}

func readLimited(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, MaxFileBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxFileBytes {
		return nil, fmt.Errorf("%w: over %d bytes", ErrTooLarge, MaxFileBytes)
	}
	return data, nil
}

// decodeDataURL decodes "data:[<type>][;base64],<data>".
func decodeDataURL(s string) ([]byte, error) {
	meta, payload, ok := strings.Cut(strings.TrimPrefix(s, "data:"), ",")
	if !ok {
		return nil, fmt.Errorf("%w: malformed data URL", ErrUnsupported)
	}
	if len(payload) > MaxFileBytes*4/3+4 {
		return nil, fmt.Errorf("%w: over %d bytes", ErrTooLarge, MaxFileBytes)
	}
	if strings.HasSuffix(meta, ";base64") {
		return base64.StdEncoding.DecodeString(payload)
	}
	p, err := url.PathUnescape(payload)
	return []byte(p), err
}

// fetch downloads an image, within remoteTimeout and MaxRemoteBytes.
func fetch(ctx context.Context, rawURL string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, remoteTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "mdview")
	req.Header.Set("Accept", "image/*")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("http status %s", resp.Status)
	}
	if resp.ContentLength > MaxRemoteBytes {
		return nil, fmt.Errorf("%w: %d bytes", ErrTooLarge, resp.ContentLength)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, MaxRemoteBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxRemoteBytes {
		return nil, fmt.Errorf("%w: over %d bytes", ErrTooLarge, MaxRemoteBytes)
	}
	return data, nil
}

func decode(ctx context.Context, data []byte) (image.Image, error) {
	if looksLikeSVG(data) {
		png, err := svgToPNG(ctx, data)
		if err != nil {
			return nil, fmt.Errorf("%w: SVG (%v)", ErrUnsupported, err)
		}
		data = png
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnsupported, err)
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || int64(cfg.Width)*int64(cfg.Height) > MaxPixels {
		return nil, fmt.Errorf("%w: %d×%d pixels", ErrTooLarge, cfg.Width, cfg.Height)
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnsupported, err)
	}
	return img, nil
}

// svgToPNG runs rsvg-convert. Its absence is reported as an error.
func svgToPNG(ctx context.Context, svg []byte) ([]byte, error) {
	bin, err := exec.LookPath("rsvg-convert")
	if err != nil {
		return nil, errors.New("rsvg-convert is not installed")
	}
	ctx, cancel := context.WithTimeout(ctx, svgTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "--format", "png", "--width", strconv.Itoa(svgWidthPx), "--keep-aspect-ratio")
	cmd.Stdin = bytes.NewReader(svg)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		if msg := strings.TrimSpace(errb.String()); msg != "" {
			return nil, fmt.Errorf("%v: %s", err, msg)
		}
		return nil, err
	}
	return out.Bytes(), nil
}

func looksLikeSVG(data []byte) bool {
	head := data[:min(len(data), 1024)]
	return bytes.Contains(head, []byte("<svg")) ||
		(bytes.HasPrefix(bytes.TrimSpace(head), []byte("<?xml")) && bytes.Contains(data[:min(len(data), 4096)], []byte("<svg")))
}
