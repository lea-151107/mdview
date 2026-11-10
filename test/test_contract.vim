" The results the Go side returns (test/contract.json, written by
" TestContract in go/main_test.go) drawn by s:build_view: the field names on
" both sides agree.

function! Test_contract() abort
  let c = json_decode(join(readfile(fnamemodify(expand('<script>'), ':p:h') . '/contract.json'), "\n"))
  let src = Src(c.lines)
  let v = S('build_view')(src, c.results, #{cellw: 8, cols: 80})
  call assert_equal([
        \ '┌───────┬───┐', '│ title │ T │', '└───────┴───┘',
        \ '# Title',
        \ '', '',
        \ 'text x² and [a] here', '', '',
        \ '┌────┬──────┐', '│    │ cell │', '│    │      │', '├────┼──────┤', '│ y  │    b │',
        \ '└────┴──────┘',
        \ '│', '│',
        \ '╭─ mermaid ' . repeat('─', 68) . '╮', 'graph TD', '  A -->', '╰' . repeat('─', 78) . '╯',
        \ 'mdview: error',
        \ '│ 💡 Tip', '│ - │ t',
        \ '╭─ go ' . repeat('─', 73) . '╮', '        x := 1', '╰' . repeat('─', 78) . '╯',
        \ '│ ' . repeat('─', 78),
        \ 'see the title and https://x.y',
        \ '┌──────┐', '│ cell │', '├──────┤', '└──────┘',
        \ ], v.lines)
  call assert_equal(['mdview_alert_tip', 'mdview_bold', 'mdview_code_border',
        \ 'mdview_code_lang', 'mdview_error', 'mdview_heading', 'mdview_image',
        \ 'mdview_link', 'mdview_math', 'mdview_quote', 'mdview_quote_bar', 'mdview_rule',
        \ 'mdview_table', 'mdview_table_border', 'mdview_table_header'],
        \ uniq(sort(map(copy(v.props), 'v:val[1]'))))
  " mermaid, the image in text, the one in a table cell (inside its
  " borders), the one in a quote.
  call assert_equal([[5, 6, 0], [8, 9, 0], [11, 12, 2], [16, 17, 2]],
        \ map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
  " The syntax regions: the front matter's table, the paragraphs and tables
  " (none; the first table joined with the paragraph above it across the
  " image's blank lines), the code of the broken mermaid and of the go block.
  call assert_equal([[1, 3, '-'], [7, 15, '-'], [19, 20, 'mermaid'], [24, 24, '-'], [26, 26, 'go'], [29, 33, '-']],
        \ map(copy(v.code), 'v:val[:2]'))
  " The links of a paragraph and of a table cell, where they are shown.
  call assert_equal({'29': [[5, 14, '#title'], [19, 30, 'https://x.y']], '31': [[5, 9, 'b.md']]}, v.links)
endfunction
