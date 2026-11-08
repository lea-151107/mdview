package main

import (
	"os"
	"regexp"
	"strconv"
	"testing"

	"github.com/Shougo/goda.vim/sdk"
)

// The binary says the version of the Vim script it goes with.
var _ sdk.ScriptVersioner = (*plugin)(nil)

// TestScriptVersion checks that scriptVersion is that of autoload/mdview.vim,
// which goda.vim compares when it starts the binary.
func TestScriptVersion(t *testing.T) {
	b, err := os.ReadFile("../autoload/mdview.vim")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^let s:script_version = (\d+)`).FindSubmatch(b)
	if m == nil {
		t.Fatal("no s:script_version in autoload/mdview.vim")
	}
	v, _ := strconv.Atoi(string(m[1]))
	if v != scriptVersion {
		t.Errorf("s:script_version = %d, scriptVersion = %d", v, scriptVersion)
	}
	if got := (&plugin{}).ScriptVersion(); got != scriptVersion {
		t.Errorf("ScriptVersion() = %d, want %d", got, scriptVersion)
	}
}
