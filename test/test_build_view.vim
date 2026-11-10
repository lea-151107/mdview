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
  let v = S('build_view')(src, [#{kind: 'quote', start: 1, end: 1, marks: [0]},
        \ extend(copy(r), #{start: 1, end: 1, indent: 2}),
        \ extend(copy(r), #{start: 2, end: 2, indent: 2})])
  " Image rows inside a quote keep its bar; the tab counts as display columns.
  call assert_equal(['│', '│', '', ''], v.lines)
  call assert_equal([[1, 'mdview_quote_bar', 3, 1], [2, 'mdview_quote_bar', 3, 1]], v.props)
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
  let v = S('build_view')(src, [#{kind: 'quote', start: 1, end: 3, marks: [0, 0, 0]}, r])
  call assert_equal(['│ ┌───┐', '│ │ a │', '│ ├───┤', '│ │ x │', '│ │ y │', '│ └───┘'], v.lines)
  call assert_equal(repeat([['mdview_quote_bar', 3, 1]], 6),
        \ map(filter(copy(v.props), 'v:val[3] == 1 && v:val[1] =~# "quote"'), 'v:val[1:3]'))
  call assert_equal([2, 3, 4], v.map)
endfunction

" The front matter's table: keys and values, without a header.
function! Test_build_view_table_no_header() abort
  let src = Src(['---', 'title: 設計メモ', 'tags:', '- vim', '- md', 'url: https://x.y', '---', 'text'])
  let r = s:table(1, 7, ['', ''], [2, 3, 6], [
        \ [[['title', 'b']], [['設計メモ', '']]],
        \ [[['tags', 'b']], [['- vim', ''], ["\n", ''], ['- md', '']]],
        \ [[['url', 'b']], [['https://x.y', 'link', 0, 'https://x.y']]]])
  let r.table.no_header = 1
  let v = S('build_view')(src, [r])
  call assert_equal([
        \ '┌───────┬─────────────┐',
        \ '│ title │ 設計メモ    │',
        \ '│ tags  │ - vim       │',
        \ '│       │ - md        │',
        \ '│ url   │ https://x.y │',
        \ '└───────┴─────────────┘',
        \ 'text'], v.lines)
  " The fences map to the borders.
  call assert_equal([1, 2, 3, 3, 3, 5, 6, 7], v.map)
  call assert_equal([1, 2, 3, 3, 6, 7, 8], v.rmap)
  call assert_equal([], filter(copy(v.props), {_, p -> p[1] ==# 'mdview_table_header'}))
  call assert_equal(3, len(filter(copy(v.props), {_, p -> p[1] ==# 'mdview_bold'})))
  call assert_equal({5: [[15, 26, 'https://x.y']]}, v.links)
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
  let quote = #{kind: 'quote', start: 1, end: 3, marks: [0, 0, 0]}
  let v = S('build_view')(src, [quote, r, p, q], #{cellw: 8, cols: 80})
  call assert_equal([
        \ '│ ┌───┬───────┐',
        \ '│ │ a │ b     │',
        \ '│ ├───┼───────┤',
        \ '│ │ x │       │',
        \ '│ │   │       │',
        \ '│ │   │ t     │',
        \ '│ │   │       │',
        \ '│ └───┴───────┘',
        \ 'z'], v.lines)
  " The images stack in the cell: the anchors are at its column.
  call assert_equal([[4, 5, 8, 'kp'], [7, 7, 8, 'kq']],
        \ map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent, a.key]}))
  call assert_equal([2, 3, 4, 9], v.map)
  " An image that changes changes its lines.
  let q2 = extend(copy(q), #{key: 'kq2'})
  let v2 = S('build_view')(src, [quote, r, p, q2], #{cellw: 8, cols: 80})
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

" Quotes: the '>' become bars, the text of a plain quote is dimmed, and an
" alert's first line becomes its title.
function! Test_build_view_quote() abort
  let src = Src(['> a', '>', '> > b', 'lazy', '- > c', '', '> [!NOTE]', '> d'])
  let v = S('build_view')(src, [
        \ #{kind: 'quote', start: 1, end: 4, marks: [0, 0, 0, -1]},
        \ #{kind: 'quote', start: 3, end: 4, marks: [2, -1]},
        \ #{kind: 'quote', start: 5, end: 5, marks: [2]},
        \ #{kind: 'quote', start: 7, end: 8, marks: [0, 0], alert: 'note'}])
  call assert_equal(['│ a', '│', '│ │ b', 'lazy', '- │ c', '', '│ 📝 Note', '│ d'], v.lines)
  call assert_equal(range(1, 8), v.map)
  let props = {}
  for [l, type, len, col] in v.props
    let props[l] = add(get(props, l, []), [col, type, len])
  endfor
  call assert_equal([[1, 'mdview_quote_bar', 3], [4, 'mdview_quote', 2]], props[1])
  call assert_equal([[1, 'mdview_quote_bar', 3]], props[2])
  call assert_equal([[1, 'mdview_quote_bar', 3], [5, 'mdview_quote_bar', 3], [8, 'mdview_quote', 2]], props[3])
  call assert_equal([[1, 'mdview_quote', 4]], props[4])
  call assert_equal([[3, 'mdview_quote_bar', 3], [6, 'mdview_quote', 2]], props[5])
  call assert_equal([[1, 'mdview_alert_note', 3], [5, 'mdview_alert_note', len('📝 Note')],
        \ [5, 'mdview_heading', len('📝 Note')]], props[7])
  " The text of an alert is not dimmed.
  call assert_equal([[1, 'mdview_alert_note', 3]], props[8])
  " The titles can be changed.
  let g:mdview_alert_titles = #{note: 'NOTE'}
  try
    call assert_equal('│ NOTE', S('build_view')(src, [#{kind: 'quote', start: 7, end: 8,
          \ marks: [0, 0], alert: 'note'}]).lines[6])
  finally
    unlet g:mdview_alert_titles
  endtry
endfunction

function! Test_build_view_quote_ambiwidth_double() abort
  let src = Src(['> a'])
  set ambiwidth=double
  try
    let v = S('build_view')(src, [#{kind: 'quote', start: 1, end: 1, marks: [0]}])
  finally
    set ambiwidth=single
  endtry
  call assert_equal(['| a'], v.lines)
endfunction

" A mermaid in a list in a quote: its rows keep the bar, not the list's mark.
function! Test_build_view_quote_list_image() abort
  let src = Src(['- > ```mermaid', '  > graph TD', '  > ```'])
  let v = S('build_view')(src, [#{kind: 'quote', start: 1, end: 3, marks: [2, 2, 2]},
        \ #{kind: 'mermaid', start: 1, end: 3, key: 'k', path: '/p', w: 8, h: 32, rows: 2, indent: 4}])
  call assert_equal(['  │', '  │'], v.lines[:1])
  call assert_equal([[1, 2, 4]], map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
endfunction

" Code blocks: the fences become a frame, the code keeps its text with the
" bar as virtual text.
function! Test_build_view_code() abort
  let src = Src(['```go', "func f() {", "\tx := 1", '', '}', '```', 'after'])
  let v = S('build_view')(src, [#{kind: 'code', start: 1, end: 6, lang: 'go',
        \ cols: [0, 0, 0, 0, 0, 0], closed: 1}], #{cellw: 8, cols: 20})
  call assert_equal(['╭─ go ' . repeat('─', 13) . '╮', 'func f() {', '        x := 1', '', '}',
        \ '╰' . repeat('─', 18) . '╯', 'after'], v.lines)
  call assert_equal(range(1, 7), v.map)
  " The code's bars: before it, and after it at the right edge (column 20,
  " under the top's corner), the spaces before it its padding.
  call assert_equal([[1, 'mdview_code_lang', 2, 8], [1, 'mdview_code_border', len(v.lines[0]), 1],
        \ [2, 'mdview_code_border', '│ ', 1], [2, 'mdview_code_border', repeat(' ', 7) . '│', 0],
        \ [3, 'mdview_code_border', '│ ', 1], [3, 'mdview_code_border', repeat(' ', 3) . '│', 0],
        \ [4, 'mdview_code_border', '│ ', 1], [4, 'mdview_code_border', repeat(' ', 17) . '│', 0],
        \ [5, 'mdview_code_border', '│ ', 1], [5, 'mdview_code_border', repeat(' ', 16) . '│', 0],
        \ [6, 'mdview_code_border', len(v.lines[5]), 1]], v.props)
  for l in range(2, 5)
    call assert_equal(20, s:shown_width(v, l), 'line ' . l)
  endfor
  call assert_equal([[2, 5, 'go', 1]], v.code)
endfunction

" In a quote and a list: the frame goes on after the bars of the quote and at
" the column of the opening fence; no language, not closed.
function! Test_build_view_code_in_quote_and_list() abort
  let src = Src(['> - ```', '>   x', '>  y'])
  let v = S('build_view')(src, [#{kind: 'quote', start: 1, end: 3, marks: [0, 0, 0]},
        \ #{kind: 'code', start: 1, end: 3, cols: [4, 4, 3]}], #{cellw: 8, cols: 20})
  call assert_equal(['│ - ╭' . repeat('─', 14) . '╮', 'x', 'y'], v.lines)
  call assert_equal([[2, 'mdview_quote_bar', '│', 1], [2, 'mdview_code_border', '   │ ', 1],
        \ [2, 'mdview_code_border', repeat(' ', 12) . '│', 0]],
        \ filter(copy(v.props), 'v:val[0] == 2'))
  call assert_equal(20, s:shown_width(v, 2))
  call assert_equal([[2, 3, '', 1]], v.code)
  " Vim shows the virtual texts of a column by priority: the quotes' bars
  " must come before the frame's.
  for t in ['mdview_quote_bar', 'mdview_alert_note']
    call assert_true(prop_type_get(t).priority > prop_type_get('mdview_code_border').priority, t)
  endfor
endfunction

" A mermaid that is not drawn shows its code in a frame; one that is drawn
" does not.
function! Test_build_view_code_of_mermaid() abort
  let src = Src(['```mermaid', 'graph TD', '```'])
  let code = #{kind: 'code', start: 1, end: 3, lang: 'mermaid', cols: [0, 0, 0], closed: 1}
  let v = S('build_view')(src, [#{kind: 'mermaid', start: 1, end: 3, error: 'x'}, code], #{cellw: 8, cols: 20})
  call assert_equal(['╭─ mermaid ' . repeat('─', 8) . '╮', 'graph TD', '╰' . repeat('─', 18) . '╯', 'mdview: x'], v.lines)
  let v = S('build_view')(src, [#{kind: 'mermaid', start: 1, end: 3, key: 'k', path: '/p',
        \ w: 8, h: 16, rows: 1}, code], #{cellw: 8, cols: 20})
  call assert_equal([''], v.lines)
  call assert_equal([], v.code)
endfunction

function! Test_build_view_code_ambiwidth_double() abort
  let src = Src(['```', 'x', '```'])
  set ambiwidth=double
  try
    let v = S('build_view')(src, [#{kind: 'code', start: 1, end: 3, cols: [0, 0, 0],
          \ closed: 1}], #{cellw: 8, cols: 6})
  finally
    set ambiwidth=single
  endtry
  call assert_equal(['+----+', 'x', '+----+'], v.lines)
  call assert_equal('| ', v.props[1][2])
  call assert_equal('  |', v.props[2][2])
  " A long line is wrapped in the frame, marked with >.
  set ambiwidth=double
  try
    let v = S('build_view')(Src(['```', 'abcd', '```']), [#{kind: 'code', start: 1, end: 3,
          \ cols: [0, 0, 0], closed: 1}], #{cellw: 8, cols: 7})
  finally
    set ambiwidth=single
  endtry
  call assert_equal(['+-----+', 'abc', 'd', '+-----+'], v.lines)
  call assert_equal('| >', v.props[3][2])
endfunction

" The display width of viewer line l with its virtual texts.
function! s:shown_width(v, l) abort
  let w = strdisplaywidth(a:v.lines[a:l - 1])
  for [lnum, _, text, _] in filter(copy(a:v.props), {_, p -> p[0] == a:l && type(p[2]) == v:t_string})
    let w += strdisplaywidth(text)
  endfor
  return w
endfunction

" A line longer than the frame: wrapped in it, between characters (a wide
" one not cut), the lines after the first marked; each with the right bar
" at the right edge.
function! Test_build_view_code_wrapped() abort
  let src = Src(['```go', 'abcdefghijklmnopqrstu', 'あいうえおかきくけ', 'x', '```'])
  let v = S('build_view')(src, [#{kind: 'code', start: 1, end: 5, lang: 'go',
        \ cols: [0, 0, 0, 0, 0], closed: 1}], #{cellw: 8, cols: 12})
  " 12 columns: 8 for the code ("│ " and " │"), 7 after the mark.
  call assert_equal(['abcdefgh', 'ijklmno', 'pqrstu', 'あいうえ', 'おかき', 'くけ', 'x'], v.lines[1 : 7])
  call assert_equal(['│ ', '│ ↪', '│ ↪', '│ ', '│ ↪', '│ ↪', '│ '],
        \ map(range(2, 8), {_, l -> filter(copy(v.props), {_, p -> p[0] == l && p[3] == 1})[0][2]}))
  for l in range(2, 8)
    call assert_equal(12, s:shown_width(v, l), 'line ' . l)
  endfor
  " Each source line maps to its first viewer line; the wrapped lines to it.
  call assert_equal([1, 2, 5, 8, 9], v.map)
  call assert_equal([1, 2, 2, 2, 3, 3, 3, 4, 5], v.rmap)
  call assert_equal([[2, 8, 'go', 1]], map(copy(v.code), 'v:val[: 2] + [v:val[3]]'))
endfunction

function! Test_code_syntax_name() abort
  let Name = S('code_syntax_name')
  call assert_equal('vim', Name('vim'))
  call assert_equal('vim', Name('VimScript'))
  call assert_equal('javascript', Name('js'))
  call assert_equal('cpp', Name('c++'))
  call assert_equal('', Name('markdown'))
  call assert_equal('', Name('no-such-language'))
  call assert_equal('', Name('nosuchlanguage'))
  let g:mdview_fenced_languages = ['foo=vim']
  try
    call assert_equal('vim', Name('foo'))
  finally
    unlet g:mdview_fenced_languages
  endtry
endfunction

" The regions give the code its language's syntax, and none of markdown's.
function! Test_code_syntax() abort
  syntax enable
  try
    call Src(['# x', 'let x = 1', '# y', 'z'])
    setlocal filetype=markdown
    call S('code_syntax_here')([[2, 3, 'vim', 1], [4, 4, '', 4]], 0)
    call assert_match('^vim', synIDattr(synID(2, 1, 1), 'name'))
    call assert_equal('mdviewCode_vim', synIDattr(synstack(3, 1)[0], 'name'))
    call assert_equal('mdviewCodePlain', synIDattr(synID(4, 1, 1), 'name'))
    call assert_match('^markdown', synIDattr(synID(1, 1, 1), 'name'))
    " Drawn again: the old regions go.
    call S('code_syntax_here')([[1, 1, '', 1]], 0)
    call assert_equal('mdviewCodePlain', synIDattr(synID(1, 1, 1), 'name'))
    call assert_notequal('mdviewCode_vim', synIDattr(get(synstack(3, 1), 0, 0), 'name'))
  finally
    syntax off
  endtry
endfunction

" Thematic breaks: a line across the viewer, after the quote's bar.
function! Test_build_view_rule() abort
  let src = Src(['a', '---', '> ***', '- x', '', '  ___'])
  let results = [#{kind: 'rule', start: 2, end: 2, col: 0},
        \ #{kind: 'quote', start: 3, end: 3, marks: [0]}, #{kind: 'rule', start: 3, end: 3, col: 2},
        \ #{kind: 'rule', start: 6, end: 6, col: 2}]
  let v = S('build_view')(src, results, #{cellw: 8, cols: 10})
  call assert_equal(['a', repeat('─', 10), '│ ' . repeat('─', 8), '- x', '', '  ' . repeat('─', 8)], v.lines)
  call assert_equal(range(1, 6), v.map)
  call assert_equal([[2, 'mdview_rule', 30, 1], [3, 'mdview_quote_bar', 3, 1],
        \ [3, 'mdview_rule', 24, 5], [6, 'mdview_rule', 24, 3]], v.props)
  set ambiwidth=double
  try
    let v = S('build_view')(src, results[:0], #{cellw: 8, cols: 10})
  finally
    set ambiwidth=single
  endtry
  call assert_equal(repeat('-', 10), v.lines[1])
endfunction

" s:add_para(): a paragraph's spans [text, style, line] laid out.
function! s:para(start, end, col, spans) abort
  return #{kind: 'para', start: a:start, end: a:end, col: a:col, spans: a:spans}
endfunction

" Joined and wrapped (no line starting with 。), styles as properties, each
" source line mapped to the viewer line of its first character.
function! Test_build_view_para() abort
  let src = Src(['これは **太字** と', '続きの行です。', 'next'])
  let r = s:para(1, 2, 0, [['これは ', '', 1], ['太字', 'b', 1], [' と', '', 1], ['続きの行です。', '', 2]])
  let v = S('build_view')(src, [r], #{cellw: 8, cols: 14})
  call assert_equal(['これは 太字 と', '続きの行です。', 'next'], v.lines)
  call assert_equal([1, 2, 3], v.map)
  call assert_equal([1, 2, 3], v.rmap)
  call assert_equal([[1, 'mdview_bold', 6, 11]], v.props)
  call assert_equal([[1, 2, '-', 1]], v.code)
  " Narrower: 。 does not start a line; line 2's text starts on viewer line 2.
  let v = S('build_view')(src, [r], #{cellw: 8, cols: 12})
  call assert_equal(['これは 太字', 'と続きの行で', 'す。', 'next'], v.lines)
  call assert_equal([1, 2, 4], v.map)
  call assert_equal([1, 1, 2, 3], v.rmap)
endfunction

" In a list in a quote: the marks on the first line, spaces and the bar on
" the others, the text dimmed; a hard break; two paragraphs, one region.
function! Test_build_view_para_in_quote_and_list() abort
  let src = Src(['> - aaa bbb ccc', '>   ddd', '', '> x'])
  let v = S('build_view')(src, [#{kind: 'quote', start: 1, end: 4, marks: [0, 0, -1, 0]},
        \ s:para(1, 2, 4, [['aaa bbb ccc ', '', 1], ["\n", '', 1], ['ddd', '', 2]]),
        \ s:para(4, 4, 2, [['x', '', 4]])], #{cellw: 8, cols: 14})
  call assert_equal(['│ - aaa bbb', '│   ccc', '│   ddd', '', '│ x'], v.lines)
  call assert_equal([1, 3, 4, 5], v.map)
  call assert_equal([[1, 'mdview_quote_bar', 3, 1], [1, 'mdview_quote', 7, 7],
        \ [2, 'mdview_quote_bar', 3, 1], [2, 'mdview_quote', 3, 7]], v.props[:3])
  call assert_equal([[1, 5, '-', 1]], v.code)
endfunction

" An image in text goes below its whole paragraph; an alert's title line
" stays a title.
function! Test_build_view_para_image_and_alert() abort
  let src = Src(['a', 'b ![p](p.png) c', '', '> [!NOTE]', '> d'])
  let img = #{kind: 'image', start: 2, end: 2, keep: 1, key: 'k', path: '/p', w: 8, h: 16, rows: 1}
  let v = S('build_view')(src, [s:para(1, 2, 0, [['a ', '', 1], ['b ', '', 2], ['[p]', 'image', 2], [' c', '', 2]]),
        \ img, #{kind: 'quote', start: 4, end: 5, marks: [0, 0], alert: 'note'},
        \ s:para(4, 5, 2, [['[!NOTE] ', '', 4], ['d', '', 5]])], #{cellw: 8, cols: 20})
  call assert_equal(['a b [p] c', '', '', '│ 📝 Note', '│ d'], v.lines)
  call assert_equal([[2, 2, 0]], map(copy(v.anchors), {_, a -> [a.first, a.last, a.indent]}))
  call assert_equal([1, 1, 3, 4, 5], v.map)
endfunction

" An image alone on a line inside a paragraph replaces that line: the
" paragraph is shown line by line, as before.
function! Test_build_view_para_with_image_line() abort
  let src = Src(['a', '![p](p.png)', 'c'])
  let img = #{kind: 'image', start: 2, end: 2, key: 'k', path: '/p', w: 8, h: 16, rows: 1}
  let v = S('build_view')(src, [s:para(1, 3, 0, [['a ', '', 1], ['[p] ', 'image', 2], ['c', '', 3]]), img])
  call assert_equal(['a', '', 'c'], v.lines)
  call assert_equal([], v.code)
endfunction

" A paragraph's region has no syntax: markdown does not conceal its text.
function! Test_code_syntax_plain() abort
  syntax enable
  try
    call Src(['*x*'])
    setlocal filetype=markdown
    call S('code_syntax_here')([[1, 1, '-', 1]], 0)
    call assert_equal('mdviewPlain', synIDattr(synID(1, 1, 1), 'name'))
    call assert_equal('mdviewPlain', synIDattr(synID(1, 2, 1), 'name'))
  finally
    syntax off
  endtry
endfunction
