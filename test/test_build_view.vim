" s:build_view(): the viewer's lines, line maps, anchors and properties.

function! Test_build_view_plain() abort
  let src = Src(['a', 'b'])
  let v = S('build_view')(src, [])
  call assert_equal(['a', 'b'], v.lines)
  call assert_equal([1, 2], v.map)
  call assert_equal([1, 2], v.rmap)
  call assert_equal([], v.anchors)
endfunction

function! Test_build_view_block_replaced() abort
  let src = Src(['x', '```mermaid', 'graph TD', '```', 'y'])
  let v = S('build_view')(src, [#{kind: 'mermaid', start: 2, end: 4,
        \ key: 'k', path: '/p', w: 8, h: 48, rows: 3, indent: 2}])
  call assert_equal(['x', '', '', '', 'y'], v.lines)
  " The block's three source lines all map to the image's first line.
  call assert_equal([1, 2, 2, 2, 5], v.map)
  call assert_equal([1, 2, 2, 2, 5], v.rmap)
  call assert_equal(1, len(v.anchors))
  call assert_equal([2, 4, 2], [v.anchors[0].first, v.anchors[0].last, v.anchors[0].indent])
endfunction

function! Test_build_view_kept_image() abort
  let src = Src(['see ![a](a.png) here', 'next'])
  let v = S('build_view')(src, [#{kind: 'image', start: 1, end: 1, keep: 1,
        \ key: 'k', path: '/p', w: 8, h: 32, rows: 2}])
  call assert_equal(['see ![a](a.png) here', '', '', 'next'], v.lines)
  call assert_equal([1, 4], v.map)
  call assert_equal([1, 1, 1, 2], v.rmap)
  call assert_equal([2, 3], [v.anchors[0].first, v.anchors[0].last])
endfunction

function! Test_build_view_group_on_one_line() abort
  let src = Src(['![a](a.png) ![b](b.png)', 'z'])
  let r = #{kind: 'image', start: 1, end: 1, key: 'k', path: '/p', w: 8, h: 16, rows: 1}
  let v = S('build_view')(src, [copy(r), extend(copy(r), #{rows: 2})])
  call assert_equal(['', '', '', 'z'], v.lines)
  call assert_equal([[1, 1], [2, 3]], map(copy(v.anchors), {_, a -> [a.first, a.last]}))
  call assert_equal([1, 4], v.map)
endfunction

function! Test_build_view_error_keeps_source() abort
  let src = Src(['```mermaid', 'bad', '```'])
  let v = S('build_view')(src, [#{kind: 'mermaid', start: 1, end: 3, error: 'oops'}])
  call assert_equal(['```mermaid', 'bad', '```', 'mdview: oops'], v.lines)
  call assert_equal([1, 2, 3], v.map)
  call assert_equal([1, 2, 3, 3], v.rmap)
  call assert_equal([[4, 'mdview_error', 12]], v.props)
endfunction

function! Test_build_view_text_fallback() abort
  let src = Src(['$$', '\frac{a}{b}', '$$'])
  let v = S('build_view')(src, [#{kind: 'math', start: 1, end: 3, text: ['a', '─', 'b'], indent: 1}])
  call assert_equal([' a', ' ─', ' b'], v.lines)
  call assert_equal([1, 1, 1], v.map)
  call assert_equal(['mdview_text', 'mdview_text', 'mdview_text'], map(copy(v.props), 'v:val[1]'))
endfunction

function! Test_build_view_headings_and_inline_math() abort
  let src = Src(['# T', 'a $x^2$ and $y_1$ b'])
  let v = S('build_view')(src, [
        \ #{kind: 'heading', start: 1, end: 1},
        \ #{kind: 'inline_math', start: 2, end: 2, col: 2, col_end: 7, text: ['x²']},
        \ #{kind: 'inline_math', start: 2, end: 2, col: 12, col_end: 17, text: ['y₁']},
        \ ])
  call assert_equal(['# T', 'a x² and y₁ b'], v.lines)
  call assert_equal([[1, 'mdview_heading', 3]], v.props)
  call assert_equal([1, 2], v.map)
endfunction
