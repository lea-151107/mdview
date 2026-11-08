" The results the Go side returns (test/contract.json, written by
" TestContract in go/main_test.go) drawn by s:build_view: the field names on
" both sides agree.

function! Test_contract() abort
  let c = json_decode(join(readfile(fnamemodify(expand('<script>'), ':p:h') . '/contract.json'), "\n"))
  let src = Src(c.lines)
  let v = S('build_view')(src, c.results, #{cellw: 8, cols: 80})
  call assert_equal([
        \ '# Title',
        \ '', '',
        \ 'text x² and ![a](a.png) here', '', '',
        \ '┌────┬──────┐', '│    │ cell │', '│    │      │', '├────┼──────┤', '│ y  │    b │',
        \ '└────┴──────┘',
        \ '│', '│',
        \ '╭─ mermaid ' . repeat('─', 69), 'graph TD', '  A -->', '╰' . repeat('─', 79),
        \ 'mdview: error',
        \ '│ 💡 Tip', '│ - │ t',
        \ '╭─ go ' . repeat('─', 74), '        x := 1', '╰' . repeat('─', 79),
        \ '│ ' . repeat('─', 78),
        \ ], v.lines)
  call assert_equal(['mdview_alert_tip', 'mdview_bold', 'mdview_code_border',
        \ 'mdview_code_lang', 'mdview_error', 'mdview_heading',
        \ 'mdview_math', 'mdview_quote', 'mdview_quote_bar', 'mdview_rule',
        \ 'mdview_table', 'mdview_table_border', 'mdview_table_header'],
        \ uniq(sort(map(copy(v.props), 'v:val[1]'))))
  " mermaid, the image in text, the one in a table cell (inside its
  " borders), the one in a quote.
  call assert_equal([[2, 3, 0], [5, 6, 0], [8, 9, 2], [13, 14, 2]],
        \ map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
  " The code of the broken mermaid and of the go block, for their syntax.
  call assert_equal([[16, 17, 'mermaid'], [23, 23, 'go']], map(copy(v.code), 'v:val[:2]'))
endfunction
