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

function! Test_build_view_group_side_by_side() abort
  let src = Src(['![a](a.png) ![b](b.png)', 'z'])
  let r = #{kind: 'image', start: 1, end: 1, key: 'k', path: '/p', w: 80, h: 16, rows: 1}
  " Both fit 80 columns (10 + 1 + 10): one row, as tall as the taller.
  let v = S('build_view')(src, [copy(r), extend(copy(r), #{rows: 2})], #{cellw: 8, cols: 80})
  call assert_equal(['', '', 'z'], v.lines)
  call assert_equal([[1, 1, 0], [1, 2, 11]], map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
  call assert_equal([1, 3], v.map)
  " Too wide for 15 columns: two rows.
  let v = S('build_view')(src, [copy(r), extend(copy(r), #{rows: 2})], #{cellw: 8, cols: 15})
  call assert_equal(['', '', '', 'z'], v.lines)
  call assert_equal([[1, 1, 0], [2, 3, 0]], map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
endfunction

function! Test_build_view_quote_and_tab_indent() abort
  let src = Src(['> ![a](a.png)', "-\t![b](b.png)"])
  let r = #{kind: 'image', key: 'k', path: '/p', w: 8, h: 32, rows: 2}
  let v = S('build_view')(src, [extend(copy(r), #{start: 1, end: 1, indent: 2}),
        \ extend(copy(r), #{start: 2, end: 2, indent: 2})])
  " Image rows inside a quote keep its mark; the tab counts as display columns.
  call assert_equal(['>', '>', '', ''], v.lines)
  call assert_equal([2, &tabstop], map(copy(v.anchors), 'v:val.indent'))
endfunction

function! Test_build_view_pending_keeps_previous_image() abort
  let src = Src(['```mermaid', 'graph TD', '```'])
  let old = #{kind: 'mermaid', start: 1, end: 3, key: 'old', path: '/old', w: 8, h: 32, rows: 2}
  let v = S('build_view')(src, [#{kind: 'mermaid', start: 1, end: 3, pending: 1}],
        \ #{prev: {'mermaid:1': old}})
  call assert_equal(['', ''], v.lines)
  call assert_equal('old', v.anchors[0].key)
endfunction

function! Test_build_view_error_keeps_source() abort
  let src = Src(['```mermaid', 'bad', '```'])
  let v = S('build_view')(src, [#{kind: 'mermaid', start: 1, end: 3, error: 'oops'}])
  call assert_equal(['```mermaid', 'bad', '```', 'mdview: oops'], v.lines)
  call assert_equal([1, 2, 3], v.map)
  call assert_equal([1, 2, 3, 3], v.rmap)
  call assert_equal([[4, 'mdview_error', 12, 1]], v.props)
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
  " The heading is bold; each replaced formula is highlighted where it ended
  " up (byte columns after the replacement).
  call assert_equal([[1, 'mdview_heading', 3, 1], [2, 'mdview_math', 3, 3],
        \ [2, 'mdview_math', 4, 11]], v.props)
  call assert_equal([1, 2], v.map)
endfunction

" A table result as the Go side returns it.
function! s:table(start, end, align, lines, rows, ...) abort
  return #{kind: 'table', start: a:start, end: a:end, indent: a:0 ? a:1 : 0,
        \ table: #{align: a:align, lines: a:lines, rows: a:rows}}
endfunction

function! Test_build_view_table() abort
  let src = Src(['x', '| 左 | b |', '|:-:|--:|', '| **太字** | 1 |', '| c |', 'y'])
  let r = s:table(2, 5, ['c', 'r'], [2, 4, 5], [
        \ [[['左', '']], [['b', '']]],
        \ [[['太字', 'b']], [['1', '']]],
        \ [[['c', '']], []]])
  let v = S('build_view')(src, [r])
  call assert_equal(['x',
        \ '┌──────┬───┐',
        \ '│  左  │ b │',
        \ '├──────┼───┤',
        \ '│ 太字 │ 1 │',
        \ '│  c   │   │',
        \ '└──────┴───┘',
        \ 'y'], v.lines)
  " Header, delimiter and rows map to their lines; the borders to the rows
  " next to them.
  call assert_equal([1, 3, 4, 5, 6, 8], v.map)
  call assert_equal([1, 2, 2, 3, 4, 5, 5, 6], v.rmap)
  let props = filter(copy(v.props), {_, p -> p[0] == 5})
  call assert_equal([[5, 'mdview_table', len(v.lines[4]), 1], [5, 'mdview_table_border', 3, 1],
        \ [5, 'mdview_bold', 6, 5], [5, 'mdview_table_border', 3, 12],
        \ [5, 'mdview_table_border', 3, 18]], props)
  " The header is bold.
  call assert_equal(2, len(filter(copy(v.props), {_, p -> p[1] ==# 'mdview_table_header'})))
endfunction

function! Test_build_view_table_wrap() abort
  let src = Src(['| a | b |', '|---|---|', '| 長い日本語のセル | one two three |'])
  let r = s:table(1, 3, ['', ''], [1, 3], [
        \ [[['a', '']], [['b', '']]],
        \ [[['長い日本語のセル', '']], [['one two three', '']]]])
  let v = S('build_view')(src, [r], #{cellw: 8, cols: 20})
  call assert_equal([
        \ '┌────────┬─────────┐',
        \ '│ a      │ b       │',
        \ '├────────┼─────────┤',
        \ '│ 長い日 │ one two │',
        \ '│ 本語の │ three   │',
        \ '│ セル   │         │',
        \ '└────────┴─────────┘'], v.lines)
  call assert_true(max(map(copy(v.lines), 'strdisplaywidth(v:val)')) <= 20)
  call assert_equal([2, 3, 4], v.map)
endfunction

function! Test_build_view_table_line_break_and_quote() abort
  let src = Src(['> | a |', '> |---|', '> | x<br>y |'])
  let r = s:table(1, 3, [''], [1, 3], [[[['a', '']]], [[['x', ''], ["\n", ''], ['y', '']]]], 2)
  let v = S('build_view')(src, [r])
  call assert_equal(['> ┌───┐', '> │ a │', '> ├───┤', '> │ x │', '> │ y │', '> └───┘'], v.lines)
  call assert_equal([2, 3, 4], v.map)
endfunction

function! Test_build_view_table_image_below() abort
  " An image without a cell (not from the Go side today) goes below.
  let src = Src(['| ![a](a.png) |', '|---|', 'z'])
  let r = s:table(1, 2, [''], [1], [[[['[a]', 'image']]]])
  let img = #{kind: 'image', start: 1, end: 1, keep: 1, key: 'k', path: '/p', w: 8, h: 32, rows: 2, indent: 2}
  let v = S('build_view')(src, [r, img])
  call assert_equal(['┌─────┐', '│ [a] │', '├─────┤', '└─────┘', '', '', 'z'], v.lines)
  call assert_equal([[5, 6, 0]], map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
  call assert_equal([2, 3, 7], v.map)
endfunction

function! Test_build_view_table_image_in_cell() abort
  let src = Src(['> | a | b |', '> |--:|---|', '> | x | ![p](p.png) t ![q](q.png) |', 'z'])
  let r = s:table(1, 3, ['r', ''], [1, 3], [
        \ [[['a', '']], [['b', '']]],
        \ [[['x', '']], [['[p]', 'image'], [' t ', ''], ['[q]', 'image']]]], 2)
  " p is 5 cells wide and 2 rows; q 3 cells and 1 row.
  let p = #{kind: 'image', start: 3, end: 3, keep: 1, key: 'kp', path: '/p', w: 40, h: 32, rows: 2, cell: [1, 1, 0]}
  let q = #{kind: 'image', start: 3, end: 3, keep: 1, key: 'kq', path: '/q', w: 24, h: 16, rows: 1, cell: [1, 1, 1]}
  let v = S('build_view')(src, [r, p, q], #{cellw: 8, cols: 80})
  call assert_equal([
        \ '> ┌───┬───────┐',
        \ '> │ a │ b     │',
        \ '> ├───┼───────┤',
        \ '> │ x │       │',
        \ '> │   │       │',
        \ '> │   │ t     │',
        \ '> │   │       │',
        \ '> └───┴───────┘',
        \ 'z'], v.lines)
  " The images stack in the cell: the anchors are at its column.
  call assert_equal([[4, 5, 8, 'kp'], [7, 7, 8, 'kq']],
        \ map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent, a.key]}))
  call assert_equal([2, 3, 4, 9], v.map)
  " An image that changes changes its lines.
  let q2 = extend(copy(q), #{key: 'kq2'})
  let v2 = S('build_view')(src, [r, p, q2], #{cellw: 8, cols: 80})
  call assert_equal(v.sig[:5], v2.sig[:5])
  call assert_notequal(v.sig[6], v2.sig[6])
endfunction

function! Test_build_view_table_image_in_cell_narrow() abort
  " The column of an image is not narrowed below it.
  let src = Src(['| a | b |', '|---|---|', '| long long text | ![p](p.png) |'])
  let r = s:table(1, 3, ['', ''], [1, 3], [
        \ [[['a', '']], [['b', '']]],
        \ [[['long long text', '']], [['[p]', 'image']]]])
  let p = #{kind: 'image', start: 3, end: 3, keep: 1, key: 'kp', path: '/p', w: 80, h: 16, rows: 1, cell: [1, 1, 0]}
  let v = S('build_view')(src, [r, p], #{cellw: 8, cols: 20})
  call assert_equal('┌─────┬────────────┐', v.lines[0])
  call assert_equal([[4, 4, 8]], map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
endfunction

function! Test_build_view_table_image_pending_shows_alt() abort
  let src = Src(['| ![p](p.png) |', '|---|'])
  let r = s:table(1, 2, [''], [1], [[[['[p]', 'image']]]])
  let p = #{kind: 'image', start: 1, end: 1, keep: 1, pending: 1, cell: [0, 0, 0]}
  let v = S('build_view')(src, [r, p])
  call assert_equal(['┌─────┐', '│ [p] │', '├─────┤', '└─────┘'], v.lines)
  call assert_equal([], v.anchors)
  " With an image from before, that one shows meanwhile.
  let old = #{kind: 'image', start: 1, end: 1, keep: 1, key: 'old', path: '/o', w: 8, h: 16, rows: 1, cell: [0, 0, 0]}
  let v = S('build_view')(src, [r, p], #{prev: {'image:1:0:0:0': old}})
  call assert_equal(['┌───┐', '│   │', '├───┤', '└───┘'], v.lines)
  call assert_equal(['old'], map(copy(v.anchors), 'v:val.key'))
endfunction
