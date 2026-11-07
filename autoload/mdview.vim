" mdview - draw mermaid, math and images inside Markdown buffers.
"
" The Go binary (bin/mdview, a goda.vim plugin) finds the blocks of a buffer,
" draws them into raw RGB files and calls mdview#apply() with the results.
" Here each block gets:
"   - blank virtual lines (text properties) as tall as its image,
"   - a popup showing the image, anchored to a text property so that it
"     follows scrolling,
"   - a closed manual fold over its source, opened while the cursor is in it.
" Images on a line of their own are shown below that line and not folded.

let s:root = expand('<sfile>:p:h:h')
" Must equal scriptVersion in go/main.go.
let s:script_version = 1

let s:images = {}     " cache key -> image id (image_add())
let s:popups = {}     " winid -> {bufnr, gen, ids}
let s:next_id = 1     " text property ids, unique over all buffers
let s:pruned = 0
let s:resize_timer = 0

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
  for [name, hl] in [['mdview_pad', ''], ['mdview_anchor', ''],
        \ ['mdview_text', 'MdviewText'], ['mdview_error', 'MdviewError']]
    if empty(prop_type_get(name))
      call prop_type_add(name, empty(hl) ? {} : #{highlight: hl})
    endif
  endfor
  augroup mdview_global
    autocmd!
    autocmd WinClosed * call s:close_popups(str2nr(expand('<amatch>')))
    autocmd BufWinEnter,WinEnter,BufWinLeave * call timer_start(0, {-> s:sync_all()})
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
" Commands

function! mdview#enable(...) abort
  let bufnr = a:0 ? a:1 : bufnr('%')
  if !s:init()
    return
  endif
  if !empty(getbufvar(bufnr, 'mdview', {}))
    call mdview#refresh(bufnr)
    return
  endif
  call setbufvar(bufnr, 'mdview', #{results: [], gen: 0, tick: -1})
  execute 'augroup mdview_buf_' . bufnr
    autocmd!
    execute 'autocmd BufWritePost <buffer=' . bufnr . '> call mdview#refresh(' . bufnr . ')'
    execute 'autocmd CursorMoved,CursorMovedI <buffer=' . bufnr . '> call s:on_cursor()'
    execute 'autocmd BufWipeout <buffer=' . bufnr . '> call s:forget(' . bufnr . ')'
  augroup END
  " Not at once: FileType runs while the buffer is still being set up.
  call timer_start(0, {-> mdview#refresh(bufnr)})
endfunction

function! mdview#disable(...) abort
  let bufnr = a:0 ? a:1 : bufnr('%')
  if empty(getbufvar(bufnr, 'mdview', {}))
    return
  endif
  call s:clear(bufnr)
  for win in win_findbuf(bufnr)
    call win_execute(win, 'call s:restore_folds()')
  endfor
  execute 'augroup mdview_buf_' . bufnr
    autocmd!
  augroup END
  execute 'augroup! mdview_buf_' . bufnr
  call setbufvar(bufnr, 'mdview', {})
  call s:discard_unused()
endfunction

function! mdview#toggle() abort
  if empty(get(b:, 'mdview', {}))
    call mdview#enable()
  else
    call mdview#disable()
  endif
endfunction

function! mdview#is_enabled(...) abort
  return !empty(getbufvar(a:0 ? a:1 : bufnr('%'), 'mdview', {}))
endfunction

" Ask the binary to draw the buffer; it calls mdview#apply() when done.
function! mdview#refresh(...) abort
  let bufnr = a:0 ? a:1 : bufnr('%')
  if !mdview#is_enabled(bufnr) || !s:init()
    return
  endif
  if !executable(s:bin())
    call s:warn('the binary is not built: run :MdviewBuild')
    return
  endif
  let wins = win_findbuf(bufnr)
  if empty(wins)
    return
  endif
  let win = index(wins, win_getid()) >= 0 ? win_getid() : wins[0]
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
  let dir = fnamemodify(bufname(bufnr), ':p:h')
  if empty(bufname(bufnr))
    let dir = getcwd()
  endif
  let req = #{
        \ bufnr: bufnr,
        \ tick: getbufvar(bufnr, 'changedtick'),
        \ lines: getbufline(bufnr, 1, '$'),
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
        \ }
  let state = getbufvar(bufnr, 'mdview')
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

" Called by the binary. results: [{kind, start, end, key, path, w, h, rows,
" text, error}], ordered by start.
function! mdview#apply(bufnr, tick, results) abort
  if !bufexists(a:bufnr) || !mdview#is_enabled(a:bufnr)
    return
  endif
  let state = getbufvar(a:bufnr, 'mdview')
  if getbufvar(a:bufnr, 'changedtick') != a:tick
    " Changed while drawing: the line numbers may be stale. Ask again, but
    " not forever while the user keeps typing.
    let state.retry = get(state, 'retry', 0) + 1
    if state.retry <= 3
      call mdview#refresh(a:bufnr)
    endif
    return
  endif
  let state.retry = 0
  let state.results = a:results
  let state.tick = a:tick
  call s:draw(a:bufnr)
endfunction

function! s:draw(bufnr) abort
  call s:clear(a:bufnr)
  let state = getbufvar(a:bufnr, 'mdview')
  let state.gen += 1
  let state.folds = []
  let last = getbufinfo(a:bufnr)[0].linecount
  let folded = {}
  for r in state.results
    if r.kind !=# 'image' && (!empty(get(r, 'path', '')) || !empty(get(r, 'text', [])))
      let folded[r.start] = 1
    endif
  endfor
  for r in state.results
    let r.id = s:next_id
    let s:next_id += 1
    let has_image = !empty(get(r, 'path', ''))
    let lines = []
    let hl = 'mdview_pad'
    if has_image
      let lines = repeat([' '], r.rows)
    elseif !empty(get(r, 'text', []))
      let lines = map(copy(r.text), {_, v -> empty(v) ? ' ' : v})
      let hl = 'mdview_text'
    elseif !empty(get(r, 'error', ''))
      let lines = ['mdview: ' . r.error]
      let hl = 'mdview_error'
    endif
    let fold = r.kind !=# 'image' && hl !=# 'mdview_error'
    " Where the virtual lines go: above the line after the block, unless that
    " line is folded itself (hidden) or there is none; then below its last line.
    let below_next = r.end + 1
    if r.kind ==# 'image' || r.end >= last || has_key(folded, below_next)
      let r.place = 'below'
      let r.anchor = r.end
      if fold && r.kind !=# 'image'
        if r.end - 1 >= r.start
          call add(state.folds, [r.start, r.end - 1])
        endif
      endif
    else
      let r.place = 'above'
      let r.anchor = below_next
      if fold
        call add(state.folds, [r.start, r.end])
      endif
    endif
    for l in lines
      call prop_add(r.anchor, 0, #{bufnr: a:bufnr, type: hl, text: l,
            \ text_align: r.place, text_wrap: 'truncate'})
    endfor
    if has_image
      call prop_add(r.anchor, 1, #{bufnr: a:bufnr, type: 'mdview_anchor',
            \ id: r.id, length: 0})
    endif
  endfor
  call s:sync(a:bufnr)
  call s:discard_unused()
endfunction

" Remove everything drawn for bufnr: text properties, popups and folds.
function! s:clear(bufnr) abort
  if !bufexists(a:bufnr)
    return
  endif
  for t in ['mdview_pad', 'mdview_anchor', 'mdview_text', 'mdview_error']
    call prop_remove(#{type: t, bufnr: a:bufnr, all: 1})
  endfor
  for [win, p] in items(s:popups)
    if p.bufnr == a:bufnr
      call s:close_popups(str2nr(win))
    endif
  endfor
  for win in win_findbuf(a:bufnr)
    if getwinvar(win, 'mdview_gen', -1) >= 0
      call win_execute(win, 'silent! normal! zE')
      call setwinvar(win, 'mdview_gen', -1)
    endif
  endfor
endfunction

function! s:forget(bufnr) abort
  for [win, p] in items(s:popups)
    if p.bufnr == a:bufnr
      call s:close_popups(str2nr(win))
    endif
  endfor
  call timer_start(0, {-> s:discard_unused()})
endfunction

" ---------------------------------------------------------------------------
" Windows: popups and folds

function! s:sync_all() abort
  for win in keys(s:popups)
    let w = str2nr(win)
    if win_id2win(w) == 0 || winbufnr(w) != s:popups[win].bufnr
      call s:close_popups(w)
    endif
  endfor
  for b in getbufinfo(#{bufloaded: 1})
    if mdview#is_enabled(b.bufnr) && !empty(b.windows)
      call s:sync(b.bufnr)
    endif
  endfor
endfunction

" Make sure every window showing bufnr has the popups and folds of its
" current drawing.
function! s:sync(bufnr) abort
  let state = getbufvar(a:bufnr, 'mdview', {})
  if empty(state) || state.gen == 0
    return
  endif
  for win in win_findbuf(a:bufnr)
    let p = get(s:popups, win, {})
    if empty(p) || p.bufnr != a:bufnr || p.gen != state.gen
      call s:close_popups(win)
      call s:make_popups(win, a:bufnr, state)
    endif
    if getwinvar(win, 'mdview_gen', -1) != state.gen
      call win_execute(win, 'call s:make_folds(' . a:bufnr . ')')
    endif
  endfor
endfunction

function! s:make_popups(win, bufnr, state) abort
  let ids = []
  for r in a:state.results
    if empty(get(r, 'path', ''))
      continue
    endif
    let img = s:image_id(r)
    if img < 0
      continue
    endif
    let opts = #{
          \ image: #{id: img},
          \ textprop: 'mdview_anchor',
          \ textpropid: r.id,
          \ textpropwin: a:win,
          \ pos: r.place ==# 'above' ? 'botleft' : 'topleft',
          \ line: 0,
          \ col: 0,
          \ posinvert: 0,
          \ clipwindow: 1,
          \ fixed: 1,
          \ wrap: 0,
          \ zindex: 20,
          \ padding: [0, 0, 0, 0],
          \ border: [0, 0, 0, 0],
          \ scrollbar: 0,
          \ }
    try
      call add(ids, popup_create('', opts))
    catch
      call s:warn(v:exception)
    endtry
  endfor
  let s:popups[a:win] = #{bufnr: a:bufnr, gen: a:state.gen, ids: ids}
endfunction

function! s:close_popups(win) abort
  let p = get(s:popups, a:win, {})
  if empty(p)
    return
  endif
  for id in p.ids
    call popup_close(id)
  endfor
  call remove(s:popups, a:win)
endfunction

function! s:image_id(r) abort
  let id = get(s:images, a:r.key, -1)
  if id >= 0
    return id
  endif
  try
    let data = readblob(a:r.path)
    if len(data) != a:r.w * a:r.h * 3
      throw 'bad image file ' . a:r.path
    endif
    let id = image_add(#{data: data, width: a:r.w, height: a:r.h})
  catch
    call s:warn(v:exception)
    return -1
  endtry
  let s:images[a:r.key] = id
  return id
endfunction

" Discard the images no buffer uses any more. Popups keep their own
" reference, so this is safe while they are open.
function! s:discard_unused() abort
  let used = {}
  for b in getbufinfo()
    let state = getbufvar(b.bufnr, 'mdview', {})
    for r in get(state, 'results', [])
      if !empty(get(r, 'key', ''))
        let used[r.key] = 1
      endif
    endfor
  endfor
  for key in keys(s:images)
    if !has_key(used, key)
      silent! call image_discard(s:images[key])
      call remove(s:images, key)
    endif
  endfor
endfunction

" Runs in the window (win_execute()).
function! s:make_folds(bufnr) abort
  let state = getbufvar(a:bufnr, 'mdview')
  if !exists('w:mdview_saved')
    let w:mdview_saved = #{fdm: &l:foldmethod, fen: &l:foldenable,
          \ fdt: &l:foldtext, fml: &l:foldminlines, fdl: &l:foldlevel,
          \ fcs: &l:fillchars}
  endif
  setlocal foldmethod=manual foldenable foldminlines=0 foldlevel=0
  setlocal foldtext=mdview#foldtext()
  let &l:fillchars = (empty(&l:fillchars) ? &g:fillchars : &l:fillchars)
        \ ->substitute('\%(^\|,\)fold:[^,]*', '', '') . ',fold: '
  let &l:fillchars = substitute(&l:fillchars, '^,', '', '')
  silent! normal! zE
  let cur = line('.')
  for [s, e] in get(state, 'folds', [])
    execute s . ',' . e . 'fold'
    if s <= cur && cur <= e
      execute s . 'foldopen'
    endif
  endfor
  let w:mdview_gen = state.gen
endfunction

function! s:restore_folds() abort
  silent! normal! zE
  if exists('w:mdview_saved')
    let s = w:mdview_saved
    let &l:foldmethod = s.fdm
    let &l:foldenable = s.fen
    let &l:foldtext = s.fdt
    let &l:foldminlines = s.fml
    let &l:foldlevel = s.fdl
    let &l:fillchars = s.fcs
    unlet w:mdview_saved
  endif
  silent! unlet w:mdview_gen
endfunction

function! mdview#foldtext() abort
  let state = get(b:, 'mdview', {})
  let kind = 'block'
  for r in get(state, 'results', [])
    if r.start == v:foldstart
      let kind = r.kind
      break
    endif
  endfor
  let n = v:foldend - v:foldstart + 1
  return printf('%s %s (%d line%s)', get(g:, 'mdview_fold_marker', '▸'), kind, n, n == 1 ? '' : 's')
endfunction

" Open the fold of the block under the cursor, close the others.
function! s:on_cursor() abort
  if getwinvar(0, 'mdview_gen', -1) < 0
    return
  endif
  let lnum = line('.')
  let prev = get(w:, 'mdview_lastline', lnum)
  let w:mdview_lastline = lnum
  if foldclosed(lnum) != -1
    let fe = foldclosedend(lnum)
    let col = col('.')
    execute lnum . 'foldopen'
    if prev > fe
      " Came up from below: start at the bottom of the block.
      call cursor(fe, col)
      let w:mdview_lastline = fe
    endif
    let w:mdview_open = 1
  elseif get(w:, 'mdview_open', 0) && foldlevel(lnum) == 0
    silent! %foldclose
    let w:mdview_open = 0
  endif
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

" Draw again with the terminal's colors once it has told them.
function! s:on_term_colors() abort
  let colors = s:colors()
  for b in getbufinfo(#{bufloaded: 1})
    let state = getbufvar(b.bufnr, 'mdview', {})
    if !empty(state) && get(state, 'colors', []) != colors
      call mdview#refresh(b.bufnr)
    endif
  endfor
endfunction

function! s:refresh_all() abort
  for b in getbufinfo(#{bufloaded: 1})
    if mdview#is_enabled(b.bufnr)
      call mdview#refresh(b.bufnr)
    endif
  endfor
endfunction

" Redraw buffers whose window width changed (the images fit the width).
function! s:on_resized() abort
  call timer_stop(s:resize_timer)
  let s:resize_timer = timer_start(300, {-> s:resized()})
endfunction

function! s:resized() abort
  for b in getbufinfo(#{bufloaded: 1})
    let state = getbufvar(b.bufnr, 'mdview', {})
    if empty(state) || empty(b.windows)
      continue
    endif
    if winwidth(b.windows[0]) != get(state, 'width', -1)
      call mdview#refresh(b.bufnr)
    endif
  endfor
endfunction
