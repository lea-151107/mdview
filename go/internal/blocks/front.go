package blocks

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// The front matter of a document is not parsed as YAML or TOML: its
// top-level keys are found line by line, and their values are shown as
// written (a nested value on its lines).

var (
	// A top-level YAML key: "key: value", the key plain or quoted.
	yamlKey = regexp.MustCompile(`^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#'"\-][^:]*?)[ \t]*:(?:[ \t]+(.*?))?[ \t]*$`)
	// A TOML key: "key = value", the key bare, quoted or dotted.
	tomlKey = regexp.MustCompile(`^[ \t]*((?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*')` +
		`(?:[ \t]*\.[ \t]*(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*'))*)[ \t]*=[ \t]*(.*?)[ \t]*$`)
	// A TOML table header: "[table]" or "[[array]]".
	tomlTable = regexp.MustCompile(`^[ \t]*\[\[?[ \t]*([^\[\]]+?)[ \t]*\]\]?[ \t]*(?:#.*)?$`)
	// A YAML block scalar's header: "|" or ">", with its indicators.
	blockScalar = regexp.MustCompile(`^([|>])[-+0-9]*(?:[ \t]+#.*)?$`)
	bareURL     = regexp.MustCompile(`^https?://\S+$`)
)

// entry is a top-level key of the front matter: its line (1-based), the
// value on that line, and the lines after it that go on with it (with
// their line numbers).
type entry struct {
	key   string
	line  int
	value string
	rest  []string
	lines []int
}

// frontMatter returns the front matter at the top of lines ("---" … "---"
// or "..." for YAML, "+++" … "+++" for TOML): the line of its closing fence
// and its keys and values as a table without a header.
func frontMatter(lines []string) (int, *TableData, bool) {
	if len(lines) < 2 {
		return 0, nil, false
	}
	toml := false
	closers := []string{"---", "..."}
	switch strings.TrimRight(lines[0], " \t") {
	case "---":
	case "+++":
		toml = true
		closers = []string{"+++"}
	default:
		return 0, nil, false
	}
	end := 0
	for i := 1; i < len(lines) && end == 0; i++ {
		l := strings.TrimRight(lines[i], " \t")
		for _, c := range closers {
			if l == c {
				end = i + 1
			}
		}
	}
	if end == 0 {
		return 0, nil, false
	}
	var es []entry
	if toml {
		es = tomlEntries(lines[1:end-1], 2)
	} else {
		es = yamlEntries(lines[1:end-1], 2)
	}
	if len(es) == 0 {
		return 0, nil, false
	}
	t := &TableData{Align: []string{"", ""}, NoHeader: true}
	for _, e := range es {
		t.Rows = append(t.Rows, [][]Span{{{Text: e.key, Style: "b", Line: e.line}}, e.spans(toml)})
		t.Lines = append(t.Lines, e.line)
	}
	return end, t, true
}

// yamlEntries returns the top-level keys of YAML lines, the first on line
// first.
func yamlEntries(lines []string, first int) []entry {
	var es []entry
	for i, l := range lines {
		l = strings.ReplaceAll(l, "\t", "    ")
		n := first + i
		switch {
		case strings.HasPrefix(l, "#"):
			// A comment.
		case l == "" || l[0] == ' ' || l == "-" || strings.HasPrefix(l, "- "):
			if len(es) > 0 {
				es[len(es)-1].add(l, n)
			}
		default:
			if m := yamlKey.FindStringSubmatch(l); m != nil {
				es = append(es, entry{key: unquote(m[1]), line: n, value: m[2]})
			} else if len(es) > 0 {
				es[len(es)-1].add(l, n)
			}
		}
	}
	return es
}

// tomlEntries returns the keys of TOML lines (those of a table with its
// name before them), the first on line first.
func tomlEntries(lines []string, first int) []entry {
	var es []entry
	table := ""
	for i, l := range lines {
		l = strings.ReplaceAll(l, "\t", "    ")
		n := first + i
		if len(es) > 0 && tomlOpen(es[len(es)-1]) {
			// A multi-line array or string goes on.
			es[len(es)-1].add(l, n)
			continue
		}
		t := strings.TrimSpace(l)
		switch {
		case t == "" || strings.HasPrefix(t, "#"):
		case tomlTable.MatchString(l):
			table = tomlTable.FindStringSubmatch(l)[1] + "."
		default:
			if m := tomlKey.FindStringSubmatch(l); m != nil {
				es = append(es, entry{key: table + m[1], line: n, value: m[2]})
			} else if len(es) > 0 {
				es[len(es)-1].add(l, n)
			}
		}
	}
	return es
}

// tomlOpen reports whether the value of e goes on to the next line: a
// multi-line string, or an array or inline table not closed yet.
func tomlOpen(e entry) bool {
	s := strings.Join(append([]string{e.value}, e.rest...), "\n")
	for _, q := range []string{`"""`, `'''`} {
		if strings.Count(s, q)%2 == 1 {
			return true
		}
	}
	depth := 0
	var quote byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case quote != 0:
			if c == '\\' && quote == '"' {
				i++
			} else if c == quote || c == '\n' {
				quote = 0
			}
		case c == '"' || c == '\'':
			quote = c
		case c == '#':
			// A comment, to the end of the line.
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case c == '[' || c == '{':
			depth++
		case c == ']' || c == '}':
			depth--
		}
	}
	return depth > 0
}

// add adds line l (line n) to the value of e.
func (e *entry) add(l string, n int) {
	e.rest = append(e.rest, l)
	e.lines = append(e.lines, n)
}

// spans returns the value of e as the runs of a table cell: a value on one
// line without its quotes or comment (a URL as a link), a longer one as its
// lines, without the indent they share (the rest of it kept, as no-break
// spaces that the cell does not trim).
func (e entry) spans(toml bool) []Span {
	// (Blank lines at the end are not part of it.)
	rest, lines := e.rest, e.lines
	for len(rest) > 0 && strings.TrimSpace(rest[len(rest)-1]) == "" {
		rest, lines = rest[:len(rest)-1], lines[:len(lines)-1]
	}
	if len(rest) == 0 {
		v := plainValue(e.value)
		switch {
		case v == "":
			return []Span{}
		case bareURL.MatchString(v):
			return []Span{{Text: v, Style: "link", Line: e.line, URL: v}}
		}
		return []Span{{Text: v, Line: e.line}}
	}
	indent := -1
	for _, l := range rest {
		if t := strings.TrimLeft(l, " "); t != "" && (indent < 0 || len(l)-len(t) < indent) {
			indent = len(l) - len(t)
		}
	}
	var out []Span
	add := func(text string, n int) {
		if len(out) > 0 {
			out = append(out, Span{Text: "\n", Line: n})
		}
		if t := strings.TrimLeft(text, " "); t != text {
			text = strings.Repeat(" ", len(text)-len(t)) + t
		}
		if text != "" {
			out = append(out, Span{Text: text, Line: n})
		}
	}
	m := blockScalar.FindStringSubmatch(e.value)
	switch {
	case !toml && m != nil && m[1] == ">":
		// Folded: the lines of a paragraph are joined by spaces (not between
		// wide characters, as in a paragraph).
		para, pline := "", 0
		for i, l := range rest {
			l = strings.TrimSpace(l)
			switch {
			case l == "":
				if para != "" {
					add(para, pline)
				}
				para = ""
			case para == "":
				para, pline = l, lines[i]
			default:
				last, _ := utf8.DecodeLastRuneInString(para)
				if first, _ := utf8.DecodeRuneInString(l); !isWide(last) || !isWide(first) {
					para += " "
				}
				para += l
			}
		}
		if para != "" {
			add(para, pline)
		}
		return out
	case toml || m == nil:
		if v := e.value; v != "" {
			if !toml {
				v = plainValue(v)
			}
			add(v, e.line)
		}
	}
	for i, l := range rest {
		if len(l) >= indent && indent > 0 {
			l = l[indent:]
		}
		add(strings.TrimRight(l, " "), lines[i])
	}
	return out
}

// plainValue returns a value on one line without its quotes, or without
// the comment after it.
func plainValue(v string) string {
	if strings.HasPrefix(v, `"`) || strings.HasPrefix(v, `'`) {
		if s, rest, ok := cutQuoted(v); ok {
			if r := strings.TrimSpace(rest); r == "" || strings.HasPrefix(r, "#") {
				return s
			}
		}
		return v
	}
	if strings.HasPrefix(v, "#") {
		return ""
	}
	for _, c := range []string{" #", "\t#"} {
		if i := strings.Index(v, c); i >= 0 {
			v = v[:i]
		}
	}
	return strings.TrimSpace(v)
}

// unquote returns a key without its quotes.
func unquote(k string) string {
	if s, rest, ok := cutQuoted(k); ok && rest == "" {
		return s
	}
	return k
}

// cutQuoted returns the text of the quoted string v starts with: in double
// quotes (with \" and \\), or in single quotes (with a doubled quote for
// one). And what follows it.
func cutQuoted(v string) (string, string, bool) {
	q := v[0]
	var b strings.Builder
	for i := 1; i < len(v); i++ {
		c := v[i]
		switch {
		case q == '"' && c == '\\' && i+1 < len(v) && (v[i+1] == '"' || v[i+1] == '\\'):
			i++
			b.WriteByte(v[i])
		case q == '\'' && c == '\'' && i+1 < len(v) && v[i+1] == '\'':
			i++
			b.WriteByte('\'')
		case c == q:
			return b.String(), v[i+1:], true
		default:
			b.WriteByte(c)
		}
	}
	return "", "", false
}
