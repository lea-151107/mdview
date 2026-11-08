// Package cache stores rendered images as raw RGB files that Vim reads with
// readblob(). Each entry is <key>.rgb plus <key>.json holding its size.
package cache

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Entry is a stored image.
type Entry struct {
	Path string `json:"-"`
	W    int    `json:"w"`
	H    int    `json:"h"`
}

// Key hashes parts into a file name. Parts are separated so that ("ab","c")
// and ("a","bc") differ.
func Key(parts ...string) string {
	h := sha256.New()
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))[:32]
}

// Load returns the entry for key, if there is one.
func Load(dir, key string) (Entry, bool) {
	data, err := os.ReadFile(filepath.Join(dir, key+".json"))
	if err != nil {
		return Entry{}, false
	}
	var e Entry
	if json.Unmarshal(data, &e) != nil || e.W <= 0 || e.H <= 0 {
		return Entry{}, false
	}
	e.Path = filepath.Join(dir, key+".rgb")
	st, err := os.Stat(e.Path)
	if err != nil || st.Size() != int64(e.W*e.H*3) {
		return Entry{}, false
	}
	now := time.Now()
	_ = os.Chtimes(e.Path, now, now) // keep it out of Prune
	return e, true
}

// Store writes rgb (w × h × 3 bytes) under key.
func Store(dir, key string, rgb []byte, w, h int) (Entry, error) {
	if len(rgb) != w*h*3 {
		return Entry{}, errors.New("cache: size mismatch")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Entry{}, err
	}
	e := Entry{Path: filepath.Join(dir, key+".rgb"), W: w, H: h}
	if err := writeAtomic(e.Path, rgb); err != nil {
		return Entry{}, err
	}
	meta, _ := json.Marshal(e)
	if err := writeAtomic(filepath.Join(dir, key+".json"), meta); err != nil {
		return Entry{}, err
	}
	return e, nil
}

func writeAtomic(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// Prune removes entries not used for longer than age.
func Prune(dir string, age time.Duration) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	limit := time.Now().Add(-age)
	stale := time.Now().Add(-time.Hour)
	for _, de := range ents {
		name := de.Name()
		if strings.HasPrefix(name, ".results-") || strings.HasPrefix(name, ".tmp-") {
			// Results Vim never read (it was closed), or a write cut short.
			if info, err := de.Info(); err == nil && info.ModTime().Before(stale) {
				os.Remove(filepath.Join(dir, name))
			}
			continue
		}
		if !strings.HasSuffix(name, ".rgb") {
			continue
		}
		info, err := de.Info()
		if err != nil || info.ModTime().After(limit) {
			continue
		}
		base := strings.TrimSuffix(name, ".rgb")
		os.Remove(filepath.Join(dir, name))
		os.Remove(filepath.Join(dir, base+".json"))
	}
}
