" Links in the viewer: where they are, where they go, and going to a heading.

function! Test_link_in_text() abort
  let F = S('link_in_text')
  let t = '## [a b](x.md#h "t") <https://x.y> <me@x.y> see http://z.example/p, ok'
  call assert_equal('x.md#h', F(t, 4))
  call assert_equal('x.md#h', F(t, 20))
  call assert_equal('', F(t, 1))
  call assert_equal('https://x.y', F(t, stridx(t, 'x.y') + 1))
  call assert_equal('mailto:me@x.y', F(t, stridx(t, 'me@') + 1))
  " A bare URL without the punctuation after it.
  call assert_equal('http://z.example/p', F(t, stridx(t, 'z.ex') + 1))
  call assert_equal('', F(t, stridx(t, ', ok') + 1))
  call assert_equal('a b.md', F('[x](<a b.md>)', 2))
  " An image is a link to its file.
  call assert_equal('i.png', F('![alt](i.png)', 3))
endfunction

function! Test_link_at() abort
  let [src, viewer] = Viewer(['see the title', '[raw](r.md)'])
  let state = getbufvar(src, 'mdview')
  let state.links = {'1': [[5, 14, '#title']]}
  let F = S('link_at')
  call assert_equal('', F(state, 1, 4))
  call assert_equal('#title', F(state, 1, 5))
  call assert_equal('#title', F(state, 1, 13))
  call assert_equal('', F(state, 1, 14))
  " A line shown as its source.
  call assert_equal('r.md', F(state, 2, 2))
  execute 'bwipeout!' viewer
endfunction

function! Test_link_target() abort
  let dir = tempname()
  call mkdir(dir . '/sub', 'p')
  for f in ['a.md', 'b.txt', 'c.png', 'sub/d e.md']
    call writefile([], dir . '/' . f)
  endfor
  let src = Src(['x'])
  execute 'file' fnameescape(dir . '/doc.md')
  let F = {url -> S('link_target')(src, url)}
  call assert_equal(#{kind: 'anchor', target: '', id: '見出し'}, F('#%E8%A6%8B%E5%87%BA%E3%81%97'))
  call assert_equal(#{kind: 'open', target: 'https://x.y/#a', id: ''}, F('https://x.y/#a'))
  call assert_equal(#{kind: 'open', target: 'mailto:me@x.y', id: ''}, F('mailto:me@x.y'))
  call assert_equal(#{kind: 'doc', target: dir . '/a.md', id: 'sec'}, F('a.md#sec'))
  call assert_equal(#{kind: 'doc', target: dir . '/a.md', id: ''}, F('./sub/../a.md'))
  call assert_equal(#{kind: 'doc', target: dir . '/sub/d e.md', id: ''}, F('sub/d%20e.md'))
  call assert_equal(#{kind: 'doc', target: dir . '/a.md', id: ''}, F('file://' . dir . '/a.md'))
  call assert_equal(#{kind: 'edit', target: dir . '/b.txt', id: ''}, F('b.txt'))
  call assert_equal(#{kind: 'open', target: dir . '/c.png', id: ''}, F('c.png'))
  call assert_equal('open', F('sub').kind)
  call assert_equal(#{kind: 'missing', target: dir . '/no.md', id: ''}, F('no.md'))
  call assert_equal(#{kind: 'anchor', target: '', id: 'h'}, F('?x#h'))
  bwipeout!
  call delete(dir, 'rf')
endfunction

function! Test_find_heading() abort
  let state = #{results: [#{kind: 'heading', start: 3, end: 3, id: 'intro'},
        \ #{kind: 'para', start: 5, end: 5}, #{kind: 'heading', start: 7, end: 7, id: 'Custom'}]}
  let F = S('find_heading')
  call assert_equal(3, F(state, 'intro'))
  call assert_equal(7, F(state, 'custom'))
  call assert_equal(0, F(state, 'none'))
endfunction

function! Test_goto_anchor() abort
  let lines = map(range(1, 40), 'v:val == 30 ? "## h" : "x"')
  let [src, viewer] = Viewer(lines)
  let state = getbufvar(src, 'mdview')
  let state.results = [#{kind: 'heading', start: 30, end: 30, id: 'h'}]
  call S('goto_anchor')(src, state, 'h')
  " The source (with the viewer following it) and the viewer at the heading.
  call assert_equal(30, line('.'))
  call assert_equal(30, getcurpos(bufwinid(viewer))[1])
  " Where they were is in the jump list.
  call assert_equal(1, getpos("''")[1])
  call S('goto_anchor')(src, state, '')
  call assert_equal(1, line('.'))
  call S('goto_anchor')(src, state, 'none')
  call assert_equal(1, line('.'))
  execute 'bwipeout!' viewer
endfunction

function! Test_build_view_links() abort
  let src = Src(['a [bb cc](u) d', '', '| [x](v) |', '|--|'])
  let para = #{kind: 'para', start: 1, end: 1, col: 0,
        \ spans: [['a ', '', 1], ['bb cc', 'link', 1, 'u'], [' d', '', 1]]}
  let table = #{kind: 'table', start: 3, end: 4, indent: 0,
        \ table: #{align: [''], rows: [[[['x', 'link', 0, 'v']]]], lines: [3]}}
  let v = S('build_view')(src, [para, table], #{cellw: 8, cols: 80})
  call assert_equal({'1': [[3, 8, 'u']], '4': [[5, 6, 'v']]}, v.links)
  " Wrapped: the link on each of its lines.
  let v = S('build_view')(src, [para], #{cellw: 8, cols: 10})
  call assert_equal(['a bb cc d'], v.lines[0 : 0])
  let v = S('build_view')(src, [extend(copy(para),
        \ #{spans: [['aaaaaaa ', '', 1], ['bb cc', 'link', 1, 'u'], [' d', '', 1]]})], #{cellw: 8, cols: 10})
  call assert_equal(['aaaaaaa bb', 'cc d'], v.lines[0 : 1])
  call assert_equal({'1': [[9, 11, 'u']], '2': [[1, 3, 'u']]}, v.links)
endfunction

function! Test_back_in_document() abort
  let lines = map(range(1, 40), 'v:val == 30 ? "## h" : "x"')
  let [src, viewer] = Viewer(lines)
  let state = getbufvar(src, 'mdview')
  let state.results = [#{kind: 'heading', start: 30, end: 30, id: 'h'}]
  call win_gotoid(bufwinid(viewer))
  call cursor(5, 1)
  call S('open_link')(src, state, '#h')
  call assert_equal(30, getcurpos(bufwinid(src))[1])
  call assert_equal(1, len(state.history))
  " <BS>: back to the line of the link, in the source and the viewer.
  call mdview#back()
  call assert_equal(5, getcurpos(bufwinid(src))[1])
  call assert_equal(5, line('.'))
  call assert_equal([], state.history)
  " A heading that is not there is not a place to come back from.
  call S('open_link')(src, state, '#none')
  call assert_equal([], state.history)
  execute 'bwipeout!' viewer
endfunction
