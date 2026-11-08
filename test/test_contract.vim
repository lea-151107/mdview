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
        \ '>', '>',
        \ '```mermaid', 'graph TD', '  A -->', '```', 'mdview: error',
        \ ], v.lines)
  call assert_equal(['mdview_bold', 'mdview_error', 'mdview_heading',
        \ 'mdview_math', 'mdview_table', 'mdview_table_border', 'mdview_table_header'],
        \ uniq(sort(map(copy(v.props), 'v:val[1]'))))
  " mermaid, the image in text, the one in a table cell (inside its
  " borders), the one in a quote.
  call assert_equal([[2, 3, 0], [5, 6, 0], [8, 9, 2], [13, 14, 2]],
        \ map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
endfunction
