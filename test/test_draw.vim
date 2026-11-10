" s:draw() and mdview#apply(): only the changed lines are rewritten, and
" results of an old request are dropped.

function! s:img(start, end, key, rows) abort
  return #{kind: 'image', start: a:start, end: a:end, key: a:key, path: '/nonexistent/' . a:key,
        \ w: 8, h: 16 * a:rows, rows: a:rows}
endfunction

function! Test_draw_updates_only_changed_lines() abort
  let [src, viewer] = Viewer(['# A', '![a](a.png)', 'text', '![b](b.png)', 'end'])
  let state = getbufvar(src, 'mdview')
  let state.results = [#{kind: 'heading', start: 1, end: 1}, s:img(2, 2, 'a', 2), s:img(4, 4, 'b', 3)]
  call S('draw')(src, state)
  call assert_equal(['# A', '', '', 'text', '', '', '', 'end'], getbufline(viewer, 1, '$'))
  let ids = map(copy(state.anchors), 'v:val.id')
  call assert_equal(1, len(prop_list(1, #{bufnr: viewer, types: ['mdview_heading']})))

  " Change the text between the images: the images keep their anchors (ids),
  " the second one moves down by one line.
  call setbufline(src, 3, ['text', 'more'])
  call appendbufline(src, 3, [])
  call setbufline(src, 1, ['# A', '![a](a.png)', 'text', 'more', '![b](b.png)', 'end'])
  let state.results = [#{kind: 'heading', start: 1, end: 1}, s:img(2, 2, 'a', 2), s:img(5, 5, 'b', 3)]
  call S('draw')(src, state)
  call assert_equal(['# A', '', '', 'text', 'more', '', '', '', 'end'], getbufline(viewer, 1, '$'))
  call assert_equal(ids, map(copy(state.anchors), 'v:val.id'))
  call assert_equal([[2, 3], [6, 8]], map(copy(state.anchors), {_, a -> [a.first, a.last]}))
  " The heading's property on the unchanged first line is still there.
  call assert_equal(1, len(prop_list(1, #{bufnr: viewer, types: ['mdview_heading']})))
  " Anchor properties are where the anchors say.
  call assert_equal([2, 6], map(prop_list(1, #{bufnr: viewer, end_lnum: -1, types: ['mdview_anchor']}), 'v:val.lnum'))
endfunction

function! Test_draw_changed_image_gets_new_anchor() abort
  let [src, viewer] = Viewer(['![a](a.png)', 'x'])
  let state = getbufvar(src, 'mdview')
  let state.results = [s:img(1, 1, 'a', 2)]
  call S('draw')(src, state)
  let id = state.anchors[0].id
  let state.results = [s:img(1, 1, 'a2', 2)]
  call S('draw')(src, state)
  call assert_notequal(id, state.anchors[0].id)
  call assert_equal(1, len(prop_list(1, #{bufnr: viewer, end_lnum: -1, types: ['mdview_anchor']})))
endfunction

function! Test_apply_drops_old_requests() abort
  let [src, viewer] = Viewer(['# A', 'b'])
  let state = getbufvar(src, 'mdview')
  let state.req_id = 2
  let tick = getbufvar(src, 'changedtick')
  " An older request: dropped.
  call mdview#apply(src, tick, [#{kind: 'heading', start: 2, end: 2}], #{id: 1, final: 1})
  call assert_equal([], state.results)
  " A partial result for a changed buffer: dropped without asking again.
  call mdview#apply(src, tick - 1, [#{kind: 'heading', start: 1, end: 1}], #{id: 2, final: 0})
  call assert_equal([], state.results)
  " The current one: drawn.
  call mdview#apply(src, tick, [#{kind: 'heading', start: 1, end: 1}], #{id: 2, final: 1})
  call assert_equal(1, len(state.results))
  call assert_equal(1, len(prop_list(1, #{bufnr: viewer, types: ['mdview_heading']})))
endfunction

" The right bar of a code line: a virtual text after the line, the spaces
" before it as padding (not highlighted, not text).
function! Test_draw_code_right_bar() abort
  let [src, viewer] = Viewer(['```', 'x', '```'])
  let state = getbufvar(src, 'mdview')
  let state.cols = 20
  let state.results = [#{kind: 'code', start: 1, end: 3, cols: [0, 0, 0], closed: 1}]
  call S('draw')(src, state)
  let after = filter(prop_list(2, #{bufnr: viewer, types: ['mdview_code_border']}),
        \ {_, p -> p.col == 0})
  call assert_equal(1, len(after))
  call assert_equal(['│', 16], [after[0].text, after[0].text_padding_left])
  call assert_equal('x', getbufline(viewer, 2)[0])
endfunction
