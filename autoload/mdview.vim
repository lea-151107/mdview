" mdview - a viewer for Markdown with mermaid, math and images drawn.
"
" :Mdview opens a read-only viewer buffer for the current Markdown buffer (the
" source), to the right or in the same window. The source itself is left
" alone.
"
" The Go binary (bin/mdview, a goda.vim plugin) finds the blocks of the
" source, draws them into raw RGB files and calls mdview#apply() with the
" results. The viewer gets the source's lines, with each drawn block replaced
" by as many empty lines as its image is tall, and a popup showing the image
" over those lines. The popup is anchored to a text property on the last of
" them (or on the first while the last is below the window), so it follows
" scrolling and is clipped at the window's edges.

let s:root = expand('<sfile>:p:h:h')
" Must equal scriptVersion in go/main.go.
let s:script_version = 2

let s:images = {}     " cache key -> image id (image_add())
let s:popups = {}     " winid -> {src, gen, items: [{pid, anchor, mode}]}
let s:next_id = 1     " text property ids, unique over all buffers
let s:pruned = 0
let s:resize_timer = 0
let s:syncing = 0     " moving one of source and viewer to follow the other

function! s:bin() abort
  return expand(get(g:, 'mdview_bin', s:root . '/bin/mdview'))
endfunction

function! s:cache_dir() abort
  let default = (empty($XDG_CACHE_HOME) ? expand('~/.cache') : $XDG_CACHE_HOME) . '/mdview'
  return expand(get(g:, 'mdview_cache_dir', default))
endfunction

function! s:has_goda() abort
  return !empty(globpath(&runtimepath, 'autoload/goda.vim', 0, 1))
endfunction

function! s:warn(msg) abort
  echohl WarningMsg
  echomsg 'mdview: ' . a:msg
  echohl None
endfunction

function! s:init() abort
  if get(s:, 'initialized', 0)
    return 1
  endif
  if !has('popupwin') || !has('textprop') || !has('image') || !has('image_popup')
    call s:warn('this Vim cannot show images (needs +popupwin +textprop +image +image_popup)')
    return 0
  endif
  if !s:has_goda()
    call s:warn('goda.vim is not in ''runtimepath''')
    return 0
  endif
  call goda#register('mdview', s:bin(), #{version: s:script_version})
  highlight default link MdviewText Normal
  highlight default link MdviewError ErrorMsg
  highlight default link MdviewPending Comment
  " Only attributes: combined with the colors of the markdown syntax.
  highlight default MdviewHeading term=bold cterm=bold gui=bold
  for [name, hl] in [['mdview_anchor', ''], ['mdview_anchor_end', ''],
        \ ['mdview_text', 'MdviewText'], ['mdview_error', 'MdviewError'],
        \ ['mdview_pending', 'MdviewPending']]
    if empty(prop_type_get(name))
      call prop_type_add(name, empty(hl) ? {} : #{highlight: hl})
    endif
  endfor
  if empty(prop_type_get('mdview_heading'))
    call prop_type_add('mdview_heading', #{highlight: 'MdviewHeading', combine: v:true})
  endif
  augroup mdview_global
    autocmd!
    autocmd WinClosed * call s:close_popups(str2nr(expand('<amatch>')))
    autocmd BufWinEnter,WinEnter,BufWinLeave * call timer_start(0, {-> s:sync_all()})
    autocmd WinScrolled * call s:on_scrolled()
    autocmd WinResized * call s:on_resized()
    autocmd ColorScheme * call s:refresh_all()
    autocmd OptionSet background call s:refresh_all()
    if exists('##TermResponseAll')
      autocmd TermResponseAll background,foreground call s:on_term_colors()
    endif
  augroup END
  let s:initialized = 1
  return 1
endfunction

" ---------------------------------------------------------------------------
" Sources and viewers

" The source buffer of bufnr: itself, or the source of a viewer.
function! s:source_of(bufnr) abort
  let src = getbufvar(a:bufnr, 'mdview_source', 0)
  return src > 0 ? src : a:bufnr
endfunction

" The state of a source with an open viewer, or {}.
function! s:state(src) abort
  let state = getbufvar(a:src, 'mdview', {})
  if empty(state) || !bufexists(state.viewer)
    return {}
  endif
  return state
endfunction

function! mdview#complete(arglead, cmdline, pos) abort
  return filter(['right', 'here'], {_, v -> v =~# '^' . a:arglead})
endfunction

" :Mdview [right|here]: open the viewer of the current buffer, or close it
" when it is open (or when the current buffer is a viewer).
function! mdview#open(...) abort
  let where = a:0 && !empty(a:1) ? a:1 : get(g:, 'mdview_open', 'right')
  if index(['right', 'here'], where) < 0
    call s:warn('unknown place: ' . where . ' (right or here)')
    return
  endif
  let src = s:source_of(bufnr('%'))
  if !empty(s:state(src))
    call mdview#close(src)
    return
  endif
  if !empty(&l:buftype)
    call s:warn('not a file buffer')
    return
  endif
  if !s:init()
    return
  endif

  let name = 'mdview://' . (empty(bufname(src)) ? '[No Name ' . src . ']' : fnamemodify(bufname(src), ':p'))
  if bufexists(name)
    silent! execute 'bwipeout!' bufnr(name)
  endif
  let lnum = line('.')
  let state = #{viewer: 0, results: [], map: [], rmap: [], gen: 0, tick: -1,
        \ here: where ==# 'here', bufhidden: getbufvar(src, '&bufhidden')}
  if where ==# 'here'
    " The source stays loaded (with its changes) while the viewer is shown.
    call setbufvar(src, '&bufhidden', 'hide')
    enew
  else
    vertical botright new
  endif
  let viewer = bufnr('%')
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  silent execute 'file' fnameescape(name)
  call s:set_markdown_filetype()
  setlocal nofoldenable nonumber norelativenumber nolist signcolumn=no
  setlocal wrap linebreak conceallevel=2
  let b:mdview_source = src
  call setbufline(viewer, 1, getbufline(src, 1, '$'))
  setlocal nomodifiable nomodified
  call cursor(lnum, 1)
  nnoremap <buffer><silent> q <Cmd>call mdview#close()<CR>
  nnoremap <buffer><silent> <CR> <Cmd>call mdview#jump()<CR>
  execute 'augroup mdview_view_' . viewer
    autocmd!
    execute 'autocmd BufWipeout <buffer=' . viewer . '> call s:detach(' . src . ')'
    execute 'autocmd CursorMoved <buffer=' . viewer . '> call s:follow_back(' . src . ')'
  augroup END

  let state.viewer = viewer
  let state.map = range(1, line('$'))
  let state.rmap = range(1, line('$'))
  call setbufvar(src, 'mdview', state)
  execute 'augroup mdview_src_' . src
    autocmd!
    execute 'autocmd BufWritePost <buffer=' . src . '> call mdview#refresh(' . src . ')'
    execute 'autocmd TextChanged,TextChangedI <buffer=' . src . '> call s:on_changed(' . src . ')'
    execute 'autocmd CursorMoved,CursorMovedI <buffer=' . src . '> call s:follow(' . src . ')'
    execute 'autocmd BufWipeout <buffer=' . src . '> call mdview#close(' . src . ')'
  augroup END
  if where ==# 'right'
    wincmd p
  endif
  call mdview#refresh(src)
endfunction

" Close the viewer of a source (default: the current buffer's).
function! mdview#close(...) abort
  let src = a:0 ? a:1 : s:source_of(bufnr('%'))
  let state = s:state(src)
  if empty(state)
    return
  endif
  let viewer = state.viewer
  if state.here && bufexists(src)
    " Put the source back in the windows showing the viewer, at the line the
    " viewer was at.
    for win in win_findbuf(viewer)
      let vl = getcurpos(win)[1]
      let sl = get(state.rmap, vl - 1, 1)
      call win_execute(win, 'buffer ' . src . ' | call cursor(' . sl . ', 1)')
    endfor
  endif
  if bufexists(viewer)
    for win in win_findbuf(viewer)
      if winnr('$') > 1
        call win_execute(win, 'close')
      endif
    endfor
    silent! execute 'bwipeout!' viewer
  endif
  call s:detach(src)
endfunction

" Forget the viewer of src: popups, autocommands and state.
function! s:detach(src) abort
  let state = getbufvar(a:src, 'mdview', {})
  if empty(state)
    return
  endif
  call timer_stop(get(state, 'timer', 0))
  for [win, p] in items(s:popups)
    if p.src == a:src
      call s:close_popups(str2nr(win))
    endif
  endfor
  execute 'augroup mdview_src_' . a:src
    autocmd!
  augroup END
  execute 'augroup! mdview_src_' . a:src
  if exists('#mdview_view_' . state.viewer)
    execute 'augroup mdview_view_' . state.viewer
      autocmd!
    augroup END
    execute 'augroup! mdview_view_' . state.viewer
  endif
  if bufexists(a:src)
    if state.here
      call setbufvar(a:src, '&bufhidden', state.bufhidden)
    endif
    call setbufvar(a:src, 'mdview', {})
  endif
  call timer_start(0, {-> s:discard_unused()})
endfunction

" Ask the binary to draw the source; it calls mdview#apply() when done.
function! mdview#refresh(...) abort
  let src = a:0 ? a:1 : s:source_of(bufnr('%'))
  let state = s:state(src)
  if empty(state) || !s:init()
    return
  endif
  if !executable(s:bin())
    call s:warn('the binary is not built: run :MdviewBuild')
    return
  endif
  let wins = win_findbuf(state.viewer)
  if empty(wins)
    return
  endif
  let win = wins[0]
  let cell = s:cell_pixels()
  let info = getwininfo(win)[0]
  let cols = info.width - info.textoff
  let width_px = cols * cell[0]
  let max_width = get(g:, 'mdview_max_width', 0)
  if max_width > 0
    let width_px = min([width_px, max_width * cell[0]])
  endif
  let rows = max([1, info.height - 2])
  let max_height = get(g:, 'mdview_max_height', 0)
  if max_height > 0
    let rows = min([rows, max_height])
  endif
  let [bg, fg] = s:colors()
  let dir = empty(bufname(src)) ? getcwd() : fnamemodify(bufname(src), ':p:h')
  let s:req_id = get(s:, 'req_id', 0) + 1
  let state.req_id = s:req_id
  call timer_stop(get(state, 'timer', 0))
  let req = #{
        \ id: s:req_id,
        \ bufnr: src,
        \ tick: getbufvar(src, 'changedtick'),
        \ lines: getbufline(src, 1, '$'),
        \ dir: dir,
        \ cache_dir: s:cache_dir(),
        \ cell: cell,
        \ width_px: width_px,
        \ height_px: rows * cell[1],
        \ bg: bg,
        \ fg: fg,
        \ math_size: get(g:, 'mdview_math_size', 0) * 1.0,
        \ mermaid_scale: get(g:, 'mdview_mermaid_scale', 0) * 1.0,
        \ font: expand(get(g:, 'mdview_font', '')),
        \ font_index: get(g:, 'mdview_font_index', 0),
        \ font_bold: expand(get(g:, 'mdview_font_bold', '')),
        \ font_bold_index: get(g:, 'mdview_font_bold_index', 0),
        \ inline_math: get(g:, 'mdview_inline_math', 1) ? 1 : 0,
        \ remote: get(g:, 'mdview_remote', 0) ? 1 : 0,
        \ }
  let state.width = info.width
  let state.colors = [bg, fg]
  try
    if !s:pruned
      let s:pruned = 1
      call goda#notify('mdview', 'prune', s:cache_dir(), get(g:, 'mdview_cache_days', 30) * 1.0)
    endif
    call goda#notify('mdview', 'render', req)
  catch
    call s:warn(v:exception)
  endtry
endfunction

function! mdview#build() abort
  if !executable('go')
    call s:warn('go is not installed')
    return
  endif
  let bin = s:bin()
  let s:build_out = []
  echomsg 'mdview: building ' . bin . ' ...'
  let s:build_job = job_start(['go', 'build', '-o', bin, '.'], #{
        \ cwd: s:root . '/go',
        \ out_cb: {ch, msg -> add(s:build_out, msg)},
        \ err_cb: {ch, msg -> add(s:build_out, msg)},
        \ exit_cb: function('s:build_done', [bin]),
        \ })
endfunction

function! s:build_done(bin, job, status) abort
  if a:status != 0
    echohl ErrorMsg
    echomsg 'mdview: build failed'
    for l in s:build_out
      echomsg l
    endfor
    echohl None
    return
  endif
  if s:has_goda() && goda#is_running('mdview')
    call goda#stop('mdview')
  endif
  echomsg 'mdview: built ' . a:bin
  call s:refresh_all()
endfunction

function! mdview#log() abort
  if !s:has_goda()
    return []
  endif
  return goda#log('mdview')
endfunction

function! mdview#clear_cache() abort
  let dir = s:cache_dir()
  for f in glob(dir . '/*.rgb', 0, 1) + glob(dir . '/*.json', 0, 1)
    call delete(f)
  endfor
  echomsg 'mdview: cleared ' . dir
endfunction

" ---------------------------------------------------------------------------
" Results from the binary

" Called by the binary, several times per request: first with what is ready
" at once (blocks still being drawn have pending set), then as blocks finish,
" the last time with meta.final set. results: [{kind, start, end, key, path,
" w, h, rows, text, error, keep, indent, pending, col, col_end}], ordered by
" start. meta: {id, final}; results of an older request are dropped.
function! mdview#apply(src, tick, results, ...) abort
  let state = s:state(a:src)
  if empty(state)
    return
  endif
  let meta = a:0 ? a:1 : #{id: get(state, 'req_id', 0), final: 1}
  if meta.id != get(state, 'req_id', 0)
    return
  endif
  if getbufvar(a:src, 'changedtick') != a:tick
    " Changed while drawing: ask again, but not forever while typing.
    if meta.final
      let state.retry = get(state, 'retry', 0) + 1
      if state.retry <= 3
        call mdview#refresh(a:src)
      endif
    endif
    return
  endif
  if meta.final
    let state.retry = 0
  endif
  let state.results = a:results
  let state.tick = a:tick
  call s:draw(a:src, state)
endfunction

" Build the viewer's lines from the source and the results.
" Returns {lines, map, rmap, anchors, props}: map[i] is the viewer line of
" source line i+1, rmap[j] the source line of viewer line j+1.
"
" Results with the same start and end form a group (several images on one
" line). A group replaces its lines with its images (or text), unless it is
" kept (an image inside text): then the lines stay and the images follow.
" Headings only add bold to their lines; inline math replaces part of a line.
function! s:build_view(src, results) abort
  let src_lines = getbufline(a:src, 1, '$')
  let n = len(src_lines)
  let groups = []
  let headings = {}   " source line -> 1
  let inline = {}     " source line -> [[col, col_end, text]]
  for r in a:results
    if r.kind ==# 'heading'
      for l in range(r.start, r.end)
        let headings[l] = 1
      endfor
    elseif r.kind ==# 'inline_math'
      if !empty(get(r, 'text', []))
        if !has_key(inline, r.start)
          let inline[r.start] = []
        endif
        call add(inline[r.start], [r.col, r.col_end, r.text[0]])
      endif
    elseif !empty(groups) && groups[-1].start == r.start && groups[-1].end == r.end
          \ && groups[-1].keep == get(r, 'keep', 0)
      call add(groups[-1].items, r)
    elseif empty(groups) || r.start > groups[-1].end
      call add(groups, #{start: r.start, end: r.end, keep: get(r, 'keep', 0), items: [r]})
    endif
  endfor

  let v = #{lines: [], map: [], rmap: [], anchors: [], props: []}
  let i = 1
  for g in groups
    while i < g.start && i <= n
      call s:copy_line(v, src_lines, i, headings, inline)
      let i += 1
    endwhile
    let failed = filter(copy(g.items), {_, r -> empty(get(r, 'path', '')) && empty(get(r, 'text', []))})
    if g.keep || !empty(failed)
      for k in range(g.start, g.end)
        call s:copy_line(v, src_lines, k, headings, inline)
      endfor
    else
      call extend(v.map, repeat([len(v.lines) + 1], g.end - g.start + 1))
    endif
    for r in g.items
      let indent = repeat(' ', get(r, 'indent', 0))
      if !empty(get(r, 'path', ''))
        let first = len(v.lines) + 1
        let rows = max([1, r.rows])
        call extend(v.lines, repeat([''], rows))
        call extend(v.rmap, repeat([r.start], rows))
        let s:next_id += 1
        call add(v.anchors, #{id: s:next_id, key: r.key, path: r.path, w: r.w, h: r.h,
              \ first: first, last: first + rows - 1, indent: get(r, 'indent', 0)})
      elseif !empty(get(r, 'text', []))
        for t in r.text
          call add(v.lines, empty(t) ? '' : indent . t)
          call add(v.rmap, r.start)
          if !empty(t)
            call add(v.props, [len(v.lines), 'mdview_text', len(indent . t)])
          endif
        endfor
      else
        let pending = get(r, 'pending', 0)
        let msg = indent . 'mdview: ' . (pending ? 'drawing…' : get(r, 'error', 'cannot draw'))
        call add(v.lines, msg)
        call add(v.rmap, r.end)
        call add(v.props, [len(v.lines), pending ? 'mdview_pending' : 'mdview_error', len(msg)])
      endif
    endfor
    let i = g.end + 1
  endfor
  while i <= n
    call s:copy_line(v, src_lines, i, headings, inline)
    let i += 1
  endwhile
  return v
endfunction

" Copy source line l to the viewer, with its inline math replaced and bold
" when it is a heading.
function! s:copy_line(v, src_lines, l, headings, inline) abort
  let t = a:src_lines[a:l - 1]
  " Replace from the right so the byte columns stay valid.
  for [c, e, text] in sort(copy(get(a:inline, a:l, [])), {x, y -> y[0] - x[0]})
    let t = strpart(t, 0, c) . text . strpart(t, e)
  endfor
  call add(a:v.lines, t)
  call add(a:v.map, len(a:v.lines))
  call add(a:v.rmap, a:l)
  if has_key(a:headings, a:l) && !empty(t)
    call add(a:v.props, [len(a:v.lines), 'mdview_heading', len(t)])
  endif
endfunction

function! s:draw(src, state) abort
  let viewer = a:state.viewer
  " Where each viewer window is, as a source line, to come back to it.
  let views = {}
  for win in win_findbuf(viewer)
    let info = getwininfo(win)[0]
    let views[win] = #{top: get(a:state.rmap, info.topline - 1, 1),
          \ cur: get(a:state.rmap, getcurpos(win)[1] - 1, 1)}
  endfor
  for [win, p] in items(s:popups)
    if p.src == a:src
      call s:close_popups(str2nr(win))
    endif
  endfor

  let v = s:build_view(a:src, a:state.results)
  call setbufvar(viewer, '&modifiable', 1)
  silent call deletebufline(viewer, 1, '$')
  call setbufline(viewer, 1, v.lines)
  for [lnum, type, len] in v.props
    call prop_add(lnum, 1, #{bufnr: viewer, type: type, length: len})
  endfor
  for a in v.anchors
    call prop_add(a.first, 1, #{bufnr: viewer, type: 'mdview_anchor', id: a.id, length: 0})
    call prop_add(a.last, 1, #{bufnr: viewer, type: 'mdview_anchor_end', id: a.id, length: 0})
  endfor
  call setbufvar(viewer, '&modifiable', 0)
  call setbufvar(viewer, '&modified', 0)
  let a:state.map = v.map
  let a:state.rmap = v.rmap
  let a:state.anchors = v.anchors
  let a:state.gen += 1

  for [win, pos] in items(views)
    let top = get(v.map, pos.top - 1, 1)
    let cur = get(v.map, pos.cur - 1, 1)
    call win_execute(str2nr(win), 'call winrestview(#{topline: ' . top . ', lnum: ' . cur . ', col: 0})')
  endfor
  call s:sync(a:src)
  if bufnr('%') == a:src
    call s:follow(a:src)
  endif
  call s:discard_unused()
endfunction

" ---------------------------------------------------------------------------
" Following the source's cursor

function! s:follow(src) abort
  let state = s:state(a:src)
  if empty(state) || bufnr('%') != a:src || state.here || s:syncing
    return
  endif
  let vl = get(state.map, line('.') - 1, get(state.map, -1, 1))
  let s:syncing = 1
  try
    for win in win_findbuf(state.viewer)
      let height = winheight(win)
      let off = min([winline() - 1, height - 1])
      let top = max([1, vl - off])
      call win_execute(win, 'call winrestview(#{topline: ' . top . ', lnum: ' . vl . ', col: 0})')
      call s:update_modes(win)
    endfor
  finally
    let s:syncing = 0
  endtry
endfunction

" With g:mdview_sync_back, moving in the viewer moves the source too (the
" other way of s:follow; s:syncing keeps them from chasing each other).
function! s:follow_back(src) abort
  let state = s:state(a:src)
  if !get(g:, 'mdview_sync_back', 0) || empty(state) || state.here || s:syncing
        \ || bufnr('%') != state.viewer
    return
  endif
  let sl = get(state.rmap, line('.') - 1, 1)
  let s:syncing = 1
  try
    for win in win_findbuf(a:src)
      let off = min([winline() - 1, winheight(win) - 1])
      call win_execute(win, 'call winrestview(#{topline: ' . max([1, sl - off]) . ', lnum: ' . sl . ', col: 0})')
    endfor
  finally
    let s:syncing = 0
  endtry
endfunction

" <CR> in the viewer: go to the source line of the cursor line.
function! mdview#jump() abort
  let src = get(b:, 'mdview_source', 0)
  let state = s:state(src)
  if empty(state)
    return
  endif
  let sl = get(state.rmap, line('.') - 1, 1)
  if state.here
    " Closing puts the source back at the line the viewer's cursor is on.
    call mdview#close(src)
    return
  endif
  let wins = win_findbuf(src)
  if empty(wins)
    execute 'leftabove vertical sbuffer' src
  else
    call win_gotoid(wins[0])
  endif
  call cursor(sl, 1)
endfunction

" Edited: draw again after g:mdview_update_delay ms without changes.
function! s:on_changed(src) abort
  let state = s:state(a:src)
  if empty(state) || !get(g:, 'mdview_live', 1)
    return
  endif
  call timer_stop(get(state, 'timer', 0))
  let state.timer = timer_start(get(g:, 'mdview_update_delay', 500),
        \ {-> mdview#refresh(a:src)})
endfunction

" filetype=markdown for the viewer, with g:mdview_fenced_languages as the
" fenced code languages when the user has not set g:markdown_fenced_languages.
function! s:set_markdown_filetype() abort
  let langs = get(g:, 'mdview_fenced_languages', [])
  if empty(langs) || !empty(get(g:, 'markdown_fenced_languages', []))
    setlocal filetype=markdown
    return
  endif
  let saved = exists('g:markdown_fenced_languages') ? g:markdown_fenced_languages : v:null
  let g:markdown_fenced_languages = langs
  try
    setlocal filetype=markdown
  finally
    if saved is v:null
      unlet! g:markdown_fenced_languages
    else
      let g:markdown_fenced_languages = saved
    endif
  endtry
endfunction

" ---------------------------------------------------------------------------
" Popups

function! s:sync_all() abort
  for win in keys(s:popups)
    let w = str2nr(win)
    let state = s:state(s:popups[win].src)
    if win_id2win(w) == 0 || empty(state) || winbufnr(w) != state.viewer
      call s:close_popups(w)
    endif
  endfor
  for b in getbufinfo(#{bufloaded: 1})
    if !empty(s:state(b.bufnr))
      call s:sync(b.bufnr)
    endif
  endfor
endfunction

" Make sure every window showing the viewer of src has the popups of its
" current drawing.
function! s:sync(src) abort
  let state = s:state(a:src)
  if empty(state) || state.gen == 0
    return
  endif
  for win in win_findbuf(state.viewer)
    let p = get(s:popups, win, {})
    if empty(p) || p.src != a:src || p.gen != state.gen
      call s:close_popups(win)
      call s:make_popups(win, a:src, state)
    endif
  endfor
endfunction

" Which anchor a popup uses: 'end' (bottom of the image on its last line;
" the top is clipped when it scrolls past the window's top) unless the last
" line is below the window, then 'start'.
function! s:mode(win, a) abort
  let info = getwininfo(a:win)[0]
  if a:a.last > info.botline && a:a.first >= info.topline
    return 'start'
  endif
  return 'end'
endfunction

function! s:popup_opts(win, a, mode) abort
  return a:mode ==# 'start'
        \ ? #{textprop: 'mdview_anchor', textpropid: a:a.id, textpropwin: a:win,
        \     pos: 'topleft', line: -1, col: get(a:a, 'indent', 0)}
        \ : #{textprop: 'mdview_anchor_end', textpropid: a:a.id, textpropwin: a:win,
        \     pos: 'botleft', line: 1, col: get(a:a, 'indent', 0)}
endfunction

function! s:make_popups(win, src, state) abort
  let items = []
  for a in get(a:state, 'anchors', [])
    let img = s:image_id(a)
    if img < 0
      continue
    endif
    let mode = s:mode(a:win, a)
    let opts = extend(#{
          \ image: #{id: img},
          \ posinvert: 0,
          \ clipwindow: 1,
          \ fixed: 1,
          \ wrap: 0,
          \ zindex: 20,
          \ padding: [0, 0, 0, 0],
          \ border: [0, 0, 0, 0],
          \ scrollbar: 0,
          \ }, s:popup_opts(a:win, a, mode))
    try
      call add(items, #{pid: popup_create('', opts), anchor: a, mode: mode, img: img})
    catch
      call s:warn(v:exception)
    endtry
  endfor
  let s:popups[a:win] = #{src: a:src, gen: a:state.gen, items: items}
endfunction

function! s:update_modes(win) abort
  let p = get(s:popups, a:win, {})
  for it in get(p, 'items', [])
    let mode = s:mode(a:win, it.anchor)
    if mode !=# it.mode
      let it.mode = mode
      " popup_setoptions() drops the image of a popup when its text property
      " changes, so give it again.
      call popup_setoptions(it.pid, extend(s:popup_opts(a:win, it.anchor, mode),
            \ #{image: #{id: it.img}}))
    endif
  endfor
endfunction

function! s:on_scrolled() abort
  for win in keys(s:popups)
    call s:update_modes(str2nr(win))
  endfor
endfunction

function! s:close_popups(win) abort
  let p = get(s:popups, a:win, {})
  if empty(p)
    return
  endif
  for it in p.items
    call popup_close(it.pid)
  endfor
  call remove(s:popups, a:win)
endfunction

function! s:image_id(a) abort
  let id = get(s:images, a:a.key, -1)
  if id >= 0
    return id
  endif
  try
    let data = readblob(a:a.path)
    if len(data) != a:a.w * a:a.h * 3
      throw 'bad image file ' . a:a.path
    endif
    let id = image_add(#{data: data, width: a:a.w, height: a:a.h})
  catch
    call s:warn(v:exception)
    return -1
  endtry
  let s:images[a:a.key] = id
  return id
endfunction

" Discard the images no viewer uses any more. Popups keep their own
" reference, so this is safe while they are open.
function! s:discard_unused() abort
  let used = {}
  for b in getbufinfo()
    let state = getbufvar(b.bufnr, 'mdview', {})
    for a in get(state, 'anchors', [])
      let used[a.key] = 1
    endfor
  endfor
  for key in keys(s:images)
    if !has_key(used, key)
      silent! call image_discard(s:images[key])
      call remove(s:images, key)
    endif
  endfor
endfunction

" ---------------------------------------------------------------------------
" Environment

function! s:cell_pixels() abort
  let c = get(g:, 'mdview_cell_pixels', [])
  if len(c) == 2
    return c
  endif
  let c = getcellpixels()
  if len(c) == 2 && c[0] > 0 && c[1] > 0
    return c
  endif
  return [8, 16]
endfunction

" [bg, fg] as [r, g, b] lists.
function! s:colors() abort
  let bg = get(g:, 'mdview_bg', [])
  if len(bg) != 3
    let bg = s:hl_rgb('bg')
  endif
  if len(bg) != 3
    let bg = getbgcolor()
  endif
  if len(bg) != 3
    let bg = &background ==# 'dark' ? [0, 0, 0] : [255, 255, 255]
  endif
  let fg = get(g:, 'mdview_fg', [])
  if len(fg) != 3
    let fg = s:hl_rgb('fg')
  endif
  if len(fg) != 3
    let fg = s:osc_rgb(get(v:, 'termrfgresp', ''))
  endif
  if len(fg) != 3
    let luma = bg[0] * 299 + bg[1] * 587 + bg[2] * 114
    let fg = luma < 128000 ? [220, 220, 220] : [30, 30, 30]
  endif
  return [bg, fg]
endfunction

" The color of Normal as [r, g, b]: its GUI color in the GUI or with
" 'termguicolors', else its cterm color number. [] when it has none (the
" terminal's default color).
function! s:hl_rgb(what) abort
  let id = synIDtrans(hlID('Normal'))
  if has('gui_running') || &termguicolors
    let c = synIDattr(id, a:what . '#', 'gui')
    if c =~# '^#\x\{6}$'
      return [str2nr(c[1:2], 16), str2nr(c[3:4], 16), str2nr(c[5:6], 16)]
    endif
    return []
  endif
  let n = synIDattr(id, a:what, 'cterm')
  if n =~# '^\d\+$' && str2nr(n) < 256
    return s:xterm_rgb(str2nr(n))
  endif
  return []
endfunction

" The RGB of an xterm 256-color number (the 16 basic colors as xterm's).
function! s:xterm_rgb(n) abort
  let basic = [[0, 0, 0], [205, 0, 0], [0, 205, 0], [205, 205, 0],
        \ [0, 0, 238], [205, 0, 205], [0, 205, 205], [229, 229, 229],
        \ [127, 127, 127], [255, 0, 0], [0, 255, 0], [255, 255, 0],
        \ [92, 92, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255]]
  if a:n < 16
    return basic[a:n]
  elseif a:n < 232
    let v = [0, 95, 135, 175, 215, 255]
    let i = a:n - 16
    return [v[i / 36], v[(i / 6) % 6], v[i % 6]]
  endif
  let g = 8 + (a:n - 232) * 10
  return [g, g, g]
endfunction

" Parse an OSC 10/11 response ("...rgb:RRRR/GGGG/BBBB...").
function! s:osc_rgb(resp) abort
  let m = matchlist(a:resp, 'rgb:\(\x\+\)/\(\x\+\)/\(\x\+\)')
  if empty(m)
    return []
  endif
  return map(m[1:3], {_, h -> str2nr(h, 16) * 255 / (pow(16, len(h))->float2nr() - 1)})
endfunction

function! s:sources() abort
  return filter(map(getbufinfo(#{bufloaded: 1}), {_, b -> b.bufnr}),
        \ {_, b -> !empty(s:state(b))})
endfunction

function! s:refresh_all() abort
  for src in s:sources()
    call mdview#refresh(src)
  endfor
endfunction

" Draw again with the terminal's colors once it has told them.
function! s:on_term_colors() abort
  let colors = s:colors()
  for src in s:sources()
    if get(s:state(src), 'colors', []) != colors
      call mdview#refresh(src)
    endif
  endfor
endfunction

" Draw again when a viewer's width changed (the images fit the width).
function! s:on_resized() abort
  call timer_stop(s:resize_timer)
  let s:resize_timer = timer_start(300, {-> s:resized()})
endfunction

function! s:resized() abort
  for src in s:sources()
    let state = s:state(src)
    let wins = win_findbuf(state.viewer)
    if !empty(wins) && winwidth(wins[0]) != get(state, 'width', -1)
      call mdview#refresh(src)
    endif
  endfor
endfunction
