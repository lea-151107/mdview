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
let s:script_version = 5

let s:images = {}     " cache key -> image id (image_add())
let s:popups = {}     " winid -> {src, gen, items: [{pid, anchor, mode}]}
let s:next_id = 1     " text property ids, unique over all buffers
let s:pruned = 0
let s:resize_timer = 0
let s:syncing = 0     " moving one of source and viewer to follow the other
let s:clear_timer = 0

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
  " Only text properties are needed; without images (s:images_enabled()) the
  " viewer shows the source of diagrams, math and images as text.
  if !has('textprop')
    call s:warn('this Vim cannot run mdview (needs +textprop)')
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
  highlight default link MdviewMath Special
  " Only attributes: combined with the colors of the markdown syntax.
  highlight default MdviewHeading term=bold cterm=bold gui=bold
  for [name, hl] in [['mdview_anchor', ''], ['mdview_anchor_end', ''],
        \ ['mdview_text', 'MdviewText'], ['mdview_error', 'MdviewError'],
        \ ['mdview_pending', 'MdviewPending'], ['mdview_math', 'MdviewMath']]
    if empty(prop_type_get(name))
      call prop_type_add(name, empty(hl) ? {} : #{highlight: hl})
    endif
  endfor
  if empty(prop_type_get('mdview_heading'))
    call prop_type_add('mdview_heading', #{highlight: 'MdviewHeading', combine: v:true})
  endif
  call s:init_table()
  call s:init_quote()
  call s:init_code()
  augroup mdview_global
    autocmd!
    autocmd WinClosed * call s:close_popups(str2nr(expand('<amatch>')))
    autocmd BufWinEnter,WinEnter,BufWinLeave * call timer_start(0, {-> s:sync_all()})
    autocmd WinScrolled * call s:on_scrolled()
    " VimResized: the terminal was resized; it comes at once, while WinResized
    " waits for the next key.
    autocmd WinResized,VimResized * call s:on_resized()
    autocmd ColorScheme * call s:refresh_all()
    autocmd OptionSet background call s:refresh_all()
    " The terminal's image protocol decides whether images are drawn.
    autocmd OptionSet imageprotocol call s:refresh_all()
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
  " The viewer is rewritten at every drawing: no undo history to pile up.
  setlocal undolevels=-1
  let b:mdview_source = src
  call setbufline(viewer, 1, getbufline(src, 1, '$'))
  setlocal nomodifiable nomodified
  call cursor(lnum, 1)
  nnoremap <buffer><silent> q <Cmd>call mdview#close()<CR>
  nnoremap <buffer><silent> <CR> <Cmd>call mdview#jump()<CR>
  execute 'augroup mdview_view_' . viewer
    autocmd!
    execute 'autocmd BufWipeout <buffer=' . viewer . '> call s:detach(' . src . ')'
    " The syntax was loaded again (it drops the code blocks' regions).
    execute 'autocmd Syntax <buffer=' . viewer . '> call s:code_syntax(' . viewer
          \ . ', get(s:state(' . src . '), "code", []), 1)'
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
        \ table_image_rows: get(g:, 'mdview_table_image_rows', 8),
        \ no_images: s:images_enabled() ? 0 : 1,
        \ }
  let state.width = info.width
  let state.height = info.height
  let state.cell = cell
  let state.cols = cols
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
" the last time with meta.final set. results (or a JSON file holding them):
" [{kind, start, end, key, path, w, h, rows, text, error, keep, indent,
" pending, col, col_end}], ordered by start. meta: {id, final, seq}; results
" of an older request are dropped.
function! mdview#apply(src, tick, results, ...) abort
  let results = a:results
  if type(results) == v:t_string
    " The binary passes the results as a file (a large argument of a channel
    " call is not freed by Vim). Read it and delete it.
    let path = results
    try
      let results = json_decode(join(readfile(path), "\n"))
    finally
      call delete(path)
    endtry
  endif
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
  let state.results = results
  let state.tick = a:tick
  call s:draw(a:src, state)
  " This runs from the binary's channel "call", after which Vim does not
  " update the screen by itself: without this the new lines and images only
  " show up at the next key press.
  redraw
endfunction

" Build the viewer's lines from the source and the results.
" Returns {lines, sig, map, rmap, anchors, props}: map[i] is the viewer line of
" source line i+1, rmap[j] the source line of viewer line j+1, sig[j] a
" signature of viewer line j+1 (its text, properties and image) used to update
" only the lines that changed.
"
" Results with the same start and end form a group (several images on one
" line). A group replaces its lines with its images (or text), unless it is
" kept (an image inside text): then the lines stay and the images follow.
" The images of a group go side by side while they fit opts.cols, each row of
" images as tall as its tallest. Headings add bold to their lines; inline
" math replaces part of a line. A table is laid out from its cells, with the
" images of its cells below it. opts: {cellw, cols, prev}; prev maps
" "kind:start" to an earlier image result, shown while a block is redrawn.
function! s:build_view(src, results, ...) abort
  let opts = extend(#{cellw: 8, cols: 80, prev: {}}, a:0 ? a:1 : {})
  let src_lines = getbufline(a:src, 1, '$')
  let n = len(src_lines)
  let groups = []
  let headings = {}   " source line -> 1
  let inline = {}     " source line -> [[col, col_end, text]]
  let quotes = {}     " source line -> [[col of '>' or -1, alert, title line]], outer first
  let codes = {}      " source line -> its code block's result
  for r in a:results
    if r.kind ==# 'code'
      for l in range(r.start, r.end)
        let codes[l] = r
      endfor
    elseif r.kind ==# 'quote'
      let alert = get(r, 'alert', '')
      for k in range(len(get(r, 'marks', [])))
        let l = r.start + k
        let quotes[l] = add(get(quotes, l, []), [r.marks[k], alert, k == 0 && !empty(alert)])
      endfor
    elseif r.kind ==# 'heading'
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
    elseif r.kind ==# 'table'
      if empty(groups) || r.start > groups[-1].end
        call add(groups, #{start: r.start, end: r.end, keep: 0, items: [], table: r})
      endif
    else
      if get(r, 'pending', 0) && has_key(opts.prev, s:prev_key(r))
        " Still drawing: keep showing the image it had.
        let r = extend(copy(opts.prev[s:prev_key(r)]),
              \ #{start: r.start, end: r.end, keep: get(r, 'keep', 0), indent: get(r, 'indent', 0)})
      endif
      if !empty(groups) && has_key(groups[-1], 'table')
            \ && r.start >= groups[-1].start && r.start <= groups[-1].end
        " An image in a cell: drawn in the cell (or, without one, below the
        " table).
        call add(groups[-1].items, has_key(r, 'cell') ? r
              \ : extend(copy(r), #{indent: get(groups[-1].table, 'indent', 0)}))
      elseif !empty(groups) && groups[-1].start == r.start && groups[-1].end == r.end
            \ && groups[-1].keep == get(r, 'keep', 0)
        call add(groups[-1].items, r)
      elseif empty(groups) || r.start > groups[-1].end
        call add(groups, #{start: r.start, end: r.end, keep: get(r, 'keep', 0), items: [r]})
      endif
    endif
  endfor

  " code: the syntax regions of code blocks, [[first, last, syntax, start]].
  let v = #{lines: [], sig: [], map: [], rmap: [], anchors: [], props: [], code: []}
  let cx = #{headings: headings, inline: inline, quotes: quotes, codes: codes,
        \ cols: opts.cols, ts: getbufvar(a:src, '&tabstop', 8)}
  let i = 1
  for g in groups
    while i < g.start && i <= n
      call s:copy_line(v, src_lines, i, cx)
      let i += 1
    endwhile
    let failed = filter(copy(g.items), {_, r -> empty(get(r, 'path', '')) && empty(get(r, 'text', []))})
    let first_line = src_lines[g.start - 1]
    " Rows that replace the lines (images, a table, messages) keep the
    " quote's bars ("│ │ "), so they go on beside them.
    let quote = s:quote_prefix(first_line, get(quotes, g.start, []), 1)
    if has_key(g, 'table')
      let cell_images = {}
      for r in g.items
        if has_key(r, 'cell') && !empty(get(r, 'path', ''))
          let c = r.cell[0] . ':' . r.cell[1]
          let cell_images[c] = extend(get(cell_images, c, {}), {r.cell[2]: r})
        endif
      endfor
      call s:add_table(v, g.table, first_line, opts, cell_images, quote)
    elseif g.keep || !empty(failed)
      for k in range(g.start, g.end)
        call s:copy_line(v, src_lines, k, cx)
      endfor
    else
      call extend(v.map, repeat([len(v.lines) + 1], g.end - g.start + 1))
    endif
    let images = filter(copy(g.items), {_, r -> !empty(get(r, 'path', '')) && !has_key(r, 'cell')})
    call s:add_images(v, images, has_key(g, 'table') ? g.end : g.start, quote, opts, first_line)
    for r in g.items
      " (An image of a cell being drawn shows its [alt] meanwhile.)
      if !empty(get(r, 'path', '')) || (has_key(r, 'cell') && get(r, 'pending', 0))
        continue
      endif
      let indent = quote[0] . repeat(' ', max([0,
            \ s:display_indent(first_line, get(r, 'indent', 0)) - strdisplaywidth(quote[0])]))
      if !empty(get(r, 'text', []))
        for t in r.text
          let line = empty(t) ? quote[0] : indent . t
          call s:add_line(v, line, r.start, quote[1]
                \ + (empty(t) ? [] : [[len(indent) + 1, 'mdview_text', len(t)]]))
        endfor
      else
        let pending = get(r, 'pending', 0)
        let msg = 'mdview: ' . (pending ? 'drawing…' : get(r, 'error', 'cannot draw'))
        call s:add_line(v, indent . msg, r.end, quote[1]
              \ + [[len(indent) + 1, pending ? 'mdview_pending' : 'mdview_error', len(msg)]])
      endif
    endfor
    let i = g.end + 1
  endfor
  while i <= n
    call s:copy_line(v, src_lines, i, cx)
    let i += 1
  endwhile
  return v
endfunction

" ---------------------------------------------------------------------------
" Quotes

" The title of each kind of GitHub alert (g:mdview_alert_titles overrides).
" Emoji that are two cells wide in Vim and in terminals alike (unlike ⓘ or ⚠,
" one cell in Vim but often drawn two cells wide).
let s:alert_titles = #{note: '📝 Note', tip: '💡 Tip', important: '❗ Important',
      \ warning: '⚡ Warning', caution: '⛔ Caution'}

function! s:init_quote() abort
  highlight default link MdviewQuote Comment
  highlight default link MdviewQuoteBar Comment
  highlight default MdviewAlertNote ctermfg=Blue guifg=#4493f8
  highlight default MdviewAlertTip ctermfg=Green guifg=#3fb950
  highlight default MdviewAlertImportant ctermfg=Magenta guifg=#ab7df8
  highlight default MdviewAlertWarning ctermfg=Yellow guifg=#d29922
  highlight default MdviewAlertCaution ctermfg=Red guifg=#f85149
  let types = [['mdview_quote', 'MdviewQuote'], ['mdview_quote_bar', 'MdviewQuoteBar']]
  for kind in keys(s:alert_titles)
    call add(types, ['mdview_alert_' . kind, 'MdviewAlert' . toupper(kind[0]) . kind[1:]])
  endfor
  for [name, hl] in types
    if empty(prop_type_get(name))
      call prop_type_add(name, #{highlight: hl, combine: v:true, priority: 20})
    endif
  endfor
endfunction

" The start of line up to its last quote mark, with the marks as bars:
" [text, props, end]. marks: the quote marks of the line ([[col, alert,
" title]], from s:build_view()); end is the byte after the last mark. With
" blank, the text between the marks (a list's marker) becomes spaces, for
" rows that go on beside the line.
function! s:quote_prefix(line, marks, blank) abort
  let bar = s:table_chars().v
  let text = ''
  let props = []
  let pos = 0
  for [c, alert; _] in a:marks
    if c < pos
      continue   " no mark on this line (-1)
    endif
    let text .= a:blank ? repeat(' ', s:display_indent(a:line, c) - strdisplaywidth(text))
          \ : strpart(a:line, pos, c - pos)
    call add(props, [len(text) + 1, empty(alert) ? 'mdview_quote_bar' : 'mdview_alert_' . alert, len(bar)])
    let text .= bar
    let pos = c + 1
  endfor
  return [text, props, pos]
endfunction

" ---------------------------------------------------------------------------
" Code blocks

" Language names of fences that differ from their Vim syntax ('' for none).
let s:code_aliases = {'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
      \ 'ts': 'typescript', 'tsx': 'typescriptreact', 'jsx': 'javascriptreact',
      \ 'py': 'python', 'python3': 'python', 'rb': 'ruby', 'bash': 'sh', 'shell': 'sh',
      \ 'shellscript': 'sh', 'yml': 'yaml', 'rs': 'rust', 'kt': 'kotlin', 'csharp': 'cs',
      \ 'c#': 'cs', 'c++': 'cpp', 'cxx': 'cpp', 'hpp': 'cpp', 'h': 'c', 'golang': 'go',
      \ 'viml': 'vim', 'vimscript': 'vim', 'pwsh': 'ps1', 'powershell': 'ps1',
      \ 'jsonc': 'json', 'json5': 'json', 'hs': 'haskell', 'ex': 'elixir', 'exs': 'elixir',
      \ 'pl': 'perl', 'makefile': 'make', 'patch': 'diff', 'latex': 'tex',
      \ 'objective-c': 'objc', 'objectivec': 'objc', 'md': '', 'markdown': ''}
let s:syntax_files = {}   " syntax name -> whether a syntax file exists

function! s:init_code() abort
  highlight default link MdviewCodeBorder Comment
  highlight default link MdviewCodeLang Title
  highlight default link MdviewCodeBlock markdownCode
  highlight default link mdviewCodePlain MdviewCodeBlock
  for [name, opts] in [['mdview_code_border', #{highlight: 'MdviewCodeBorder', priority: 10}],
        \ ['mdview_code_lang', #{highlight: 'MdviewCodeLang', priority: 20}]]
    if empty(prop_type_get(name))
      call prop_type_add(name, opts)
    endif
  endfor
endfunction

function! s:code_chars() abort
  if &ambiwidth ==# 'double'
    return #{tl: '+', bl: '+', h: '-', v: '|'}
  endif
  return #{tl: '╭', bl: '╰', h: '─', v: '│'}
endfunction

" The Vim syntax for the language of a fence, or '' (none, or no syntax
" file). g:mdview_fenced_languages (and g:markdown_fenced_languages) map
" names with "name=syntax".
function! s:code_syntax_name(lang) abort
  let name = tolower(a:lang)
  for e in get(g:, 'mdview_fenced_languages', []) + get(g:, 'markdown_fenced_languages', [])
    let [k, syn] = e =~# '=' ? split(e, '=', 1)[:1] : [e, e]
    if tolower(k) ==# name
      let name = syn
      break
    endif
  endfor
  let name = get(s:code_aliases, name, name)
  if name !~# '^[a-z0-9_]\+$' || name ==# 'markdown'
    return ''
  endif
  if !has_key(s:syntax_files, name)
    let s:syntax_files[name] = !empty(globpath(&runtimepath, 'syntax/' . name . '.vim', 0, 1))
  endif
  return s:syntax_files[name] ? name : ''
endfunction

" Expand the tabs of text (whose first column is a tab stop).
function! s:expand_tabs(text, ts) abort
  if stridx(a:text, "\t") < 0
    return a:text
  endif
  let out = ''
  let w = 0
  for c in split(a:text, '\zs')
    if c ==# "\t"
      let n = a:ts - w % a:ts
      let out .= repeat(' ', n)
      let w += n
    else
      let out .= c
      let w += strdisplaywidth(c)
    endif
  endfor
  return out
endfunction

" Copy line l of a code block (cx.codes): the fences become the top (with
" the language) and the bottom of a frame; the code keeps its text (tabs
" expanded), with the frame's bar and the bars of quotes before it as
" virtual text, so that the language's syntax sees the code alone. Returns
" 0 when the line is not known (left to s:copy_line()).
function! s:code_line(v, src_lines, l, cx) abort
  let r = a:cx.codes[a:l]
  let lang = get(r, 'lang', '')   " (left out when empty)
  let k = a:l - r.start
  let col = get(r.cols, k, -1)
  if col < 0 || r.cols[0] < 0
    return 0
  endif
  let src = a:src_lines[a:l - 1]
  let ch = s:code_chars()
  let marks = get(a:cx.quotes, a:l, [])
  call add(a:v.map, len(a:v.lines) + 1)
  if k == 0
    " The opening fence: the top with the language, after the quote and
    " list marks.
    let [t, props, qend] = s:quote_prefix(src, marks, 0)
    let t .= strpart(src, qend, col - qend)
    let rule = len(t)
    let t .= ch.tl . ch.h
    if !empty(lang)
      call add(props, [len(t) + 2, 'mdview_code_lang', len(lang)])
      let t .= ' ' . lang . ' '
    endif
    let t .= repeat(ch.h, max([3, a:cx.cols - strdisplaywidth(t)]))
    call add(props, [rule + 1, 'mdview_code_border', len(t) - rule])
    call s:add_line(a:v, t, a:l, props)
    return 1
  endif
  " The other lines go on at the column of the opening fence.
  let [pre, props, _] = s:quote_prefix(src, marks, 1)
  let pre .= repeat(' ', max([0, s:display_indent(a:src_lines[r.start - 1], r.cols[0])
        \ - strdisplaywidth(pre)]))
  if get(r, 'closed', 0) && a:l == r.end
    let t = pre . ch.bl
    let t .= repeat(ch.h, max([3, a:cx.cols - strdisplaywidth(t)]))
    call add(props, [len(pre) + 1, 'mdview_code_border', len(t) - len(pre)])
    call s:add_line(a:v, t, a:l, props)
    return 1
  endif
  " Code: the prefix as virtual texts, one per bar (each its own type) with
  " the spaces before it. Vim shows the virtual texts of a column by
  " priority, then in the order added: the quotes' bars (20) come before the
  " frame's (10), as they must.
  let vt = []
  let pos = 0
  for [c, type, n] in props
    call add(vt, [1, type, strpart(pre, pos, c - 1 + n - pos)])
    let pos = c - 1 + n
  endfor
  call add(vt, [1, 'mdview_code_border', strpart(pre, pos) . ch.v . ' '])
  call s:add_line(a:v, s:expand_tabs(strpart(src, col), a:cx.ts), a:l, vt)
  let lnum = len(a:v.lines)
  if !empty(a:v.code) && a:v.code[-1][3] == r.start && a:v.code[-1][1] == lnum - 1
    let a:v.code[-1][1] = lnum
  else
    call add(a:v.code, [lnum, lnum, s:code_syntax_name(lang), r.start])
  endif
  return 1
endfunction

" Give the code of the viewer the syntax of its language: a region on the
" lines of each code block ([[first, last, syntax, _]]), defined after the
" markdown syntax so that it wins. reset: the syntax was loaded again.
function! s:code_syntax(viewer, regions, ...) abort
  let wins = win_findbuf(a:viewer)
  if !empty(wins)
    call win_execute(wins[0], 'call s:code_syntax_here(a:regions, a:0 && a:1)')
  endif
endfunction

function! s:code_syntax_here(regions, reset) abort
  if !exists('b:current_syntax')
    return
  endif
  if a:reset
    let b:mdview_code_langs = {}
    let b:mdview_code_groups = []
  endif
  for g in get(b:, 'mdview_code_groups', [])
    execute 'silent! syntax clear' g
  endfor
  let groups = {}
  for [first, last, name; _] in a:regions
    let cluster = s:include_syntax(name)
    let group = empty(cluster) ? 'mdviewCodePlain' : 'mdviewCode_' . name
    execute printf('syntax region %s start=/\%%%dl^/ end=/\%%%dl$/ keepend%s',
          \ group, first, last, empty(cluster) ? '' : ' contains=@' . cluster)
    let groups[group] = 1
  endfor
  let b:mdview_code_groups = keys(groups)
  " The regions start at line numbers: find them from the top.
  syntax sync fromstart
endfunction

" Load the syntax name into the cluster @mdviewLang_{name}, once per buffer.
" Returns the cluster's name, or ''.
function! s:include_syntax(name) abort
  if empty(a:name)
    return ''
  endif
  if !exists('b:mdview_code_langs')
    let b:mdview_code_langs = {}
  endif
  if !has_key(b:mdview_code_langs, a:name)
    let cluster = 'mdviewLang_' . a:name
    let saved = b:current_syntax
    unlet b:current_syntax
    try
      execute 'silent syntax include @' . cluster . ' syntax/' . a:name . '.vim'
      let b:mdview_code_langs[a:name] = cluster
    catch
      let b:mdview_code_langs[a:name] = ''
    finally
      let b:current_syntax = saved
      syntax case match
    endtry
  endif
  return b:mdview_code_langs[a:name]
endfunction

" ---------------------------------------------------------------------------
" Tables

" The property type of each style of a table's text (see blocks.Span).
let s:table_styles = #{b: 'mdview_bold', i: 'mdview_italic', code: 'mdview_code',
      \ strike: 'mdview_strike', u: 'mdview_underline', link: 'mdview_link',
      \ image: 'mdview_image', math: 'mdview_math'}

function! s:init_table() abort
  highlight default link MdviewTable Normal
  highlight default link MdviewTableBorder Comment
  highlight default link MdviewCode String
  highlight default link MdviewLink Underlined
  highlight default link MdviewImage Special
  " Only attributes: combined with the colors under them.
  highlight default MdviewTableHeader term=bold cterm=bold gui=bold
  highlight default MdviewBold term=bold cterm=bold gui=bold
  highlight default MdviewItalic term=italic cterm=italic gui=italic
  highlight default MdviewStrike term=strikethrough cterm=strikethrough gui=strikethrough
  highlight default MdviewUnderline term=underline cterm=underline gui=underline
  " The whole line: Normal without the markdown syntax (which would
  " highlight the cells' text as Markdown again).
  if empty(prop_type_get('mdview_table'))
    call prop_type_add('mdview_table', #{highlight: 'MdviewTable', combine: v:false, priority: 10})
  endif
  for [name, hl] in [['mdview_table_border', 'MdviewTableBorder'],
        \ ['mdview_table_header', 'MdviewTableHeader'], ['mdview_bold', 'MdviewBold'],
        \ ['mdview_italic', 'MdviewItalic'], ['mdview_code', 'MdviewCode'],
        \ ['mdview_strike', 'MdviewStrike'], ['mdview_underline', 'MdviewUnderline'],
        \ ['mdview_link', 'MdviewLink'], ['mdview_image', 'MdviewImage']]
    if empty(prop_type_get(name))
      call prop_type_add(name, #{highlight: hl, combine: v:true, priority: 20})
    endif
  endfor
endfunction

" The characters a table is drawn with: box drawing, or ASCII when they would
" be two cells wide.
function! s:table_chars() abort
  if &ambiwidth ==# 'double'
    return #{h: '-', v: '|', tl: '+', tm: '+', tr: '+', ml: '+', mm: '+', mr: '+',
          \ bl: '+', bm: '+', br: '+'}
  endif
  return #{h: '─', v: '│', tl: '┌', tm: '┬', tr: '┐', ml: '├', mm: '┼', mr: '┤',
        \ bl: '└', bm: '┴', br: '┘'}
endfunction

" A cell's runs [[text, style], ...] as lines of characters [[char, style,
" width], ...], split at line breaks.
function! s:cell_lines(runs, ...) abort
  " a:1: nth image of the cell -> its drawn image result; a:2: cell width.
  let images = a:0 ? a:1 : {}
  let cellw = a:0 > 1 ? a:2 : 8
  let lines = [[]]
  let nth = 0
  for [text, style] in a:runs
    if text ==# "\n"
      call add(lines, [])
      continue
    endif
    if index(split(style, ','), 'image') >= 0
      let nth += 1
      if has_key(images, nth - 1)
        " A drawn image: on lines of its own, in place of its [alt].
        let r = images[nth - 1]
        call add(lines, #{img: r, w: (r.w + cellw - 1) / cellw, rows: max([1, r.rows])})
        call add(lines, [])
        continue
      endif
    endif
    for c in split(substitute(text, '[\t\r\n]', ' ', 'g'), '\zs')
      call add(lines[-1], [c, style, strdisplaywidth(c)])
    endfor
  endfor
  if empty(images)
    return lines
  endif
  " Drop the blank lines around the images (the spaces between them).
  let out = []
  for k in range(len(lines))
    let l = lines[k]
    if type(l) == v:t_list && empty(s:trim_chars(l))
          \ && (k == 0 || type(lines[k - 1]) == v:t_dict || k == len(lines) - 1
          \     || type(lines[k + 1]) == v:t_dict)
      continue
    endif
    call add(out, l)
  endfor
  return empty(out) ? [[]] : out
endfunction

function! s:chars_width(chars) abort
  let w = 0
  for c in a:chars
    let w += c[2]
  endfor
  return w
endfunction

" Characters a line does not start with, and those it does not end with.
let s:no_start = '、。，．・：；？！ー…‥）］｝」』】〉》〕ゃゅょっぁぃぅぇぉャュョッァィゥェォ'
let s:no_end = '（［｛「『【〈《〔'

" Where a line of characters may be broken before index k: at a space, and
" before or after a wide (CJK) character, but not before closing punctuation
" or after opening.
function! s:can_break(chars, k) abort
  if a:k <= 0
    return 0
  endif
  let [c, p] = [a:chars[a:k], a:chars[a:k - 1]]
  if c[0] ==# ' '
    return 1
  endif
  if stridx(s:no_start, c[0]) >= 0 || stridx(s:no_end, p[0]) >= 0
    return 0
  endif
  return c[2] > 1 || p[2] > 1
endfunction

function! s:trim_chars(chars) abort
  let [a, b] = [0, len(a:chars) - 1]
  while a <= b && a:chars[a][0] ==# ' '
    let a += 1
  endwhile
  while b >= a && a:chars[b][0] ==# ' '
    let b -= 1
  endwhile
  return a:chars[a : b]
endfunction

" Wrap a line of characters to width w: at the last place it may be broken,
" or anywhere in a word longer than w.
function! s:wrap_chars(chars, w) abort
  let out = []
  let cur = []
  let curw = 0
  let brk = -1
  for c in a:chars
    if empty(cur) && c[0] ==# ' '
      continue
    endif
    if curw + c[2] > a:w && !empty(cur)
      if s:can_break(cur + [c], len(cur))
        " Right before c.
        call add(out, s:trim_chars(cur))
        let cur = []
      elseif brk > 0
        call add(out, s:trim_chars(cur[: brk - 1]))
        let cur = s:trim_chars(cur[brk :])
      else
        call add(out, cur)
        let cur = []
      endif
      let curw = s:chars_width(cur)
      let brk = -1
      for k in range(1, max([0, len(cur) - 1]))
        if s:can_break(cur, k)
          let brk = k
        endif
      endfor
      if empty(cur) && c[0] ==# ' '
        continue
      endif
    endif
    call add(cur, c)
    let curw += c[2]
    if s:can_break(cur, len(cur) - 1)
      let brk = len(cur) - 1
    endif
  endfor
  if !empty(cur) || empty(out)
    call add(out, s:trim_chars(cur))
  endif
  return out
endfunction

" The column widths of a table: as wide as their cells, the widest narrowed
" one by one while the table is wider than avail (down to 3, or the cell,
" but not below the images in the column).
function! s:table_widths(cells, ncols, avail) abort
  let widths = repeat([1], a:ncols)
  let image_w = repeat([0], a:ncols)   " the widest image of each column
  for row in a:cells
    for j in range(min([len(row), a:ncols]))
      for l in row[j]
        if type(l) == v:t_dict
          let image_w[j] = max([image_w[j], l.w])
          let widths[j] = max([widths[j], l.w])
        else
          let widths[j] = max([widths[j], s:chars_width(l)])
        endif
      endfor
    endfor
  endfor
  " A column is not narrowed below its images: they cannot be scaled here.
  let least = map(copy(widths), {j, w -> max([min([w, 3]), image_w[j]])})
  let total = eval(join(widths, '+'))
  while total > a:avail
    let j = -1
    for k in range(a:ncols)
      if widths[k] > least[k] && (j < 0 || widths[k] > widths[j])
        let j = k
      endif
    endfor
    if j < 0
      break
    endif
    let widths[j] -= 1
    let total -= 1
  endwhile
  return widths
endfunction

" Add table result r to the viewer: lines boxed with s:table_chars(), its
" cells wrapped to fit opts.cols, and the source lines of its rows mapped to
" their first lines (the delimiter row to the line under the header).
function! s:add_table(v, r, first_line, opts, ...) abort
  " a:1: "row:col" -> {nth: drawn image result} of the images in cells.
  let images = a:0 ? a:1 : {}
  " a:2: the bars of the quote it is in (s:quote_prefix()).
  let [quote, qprops; _] = a:0 > 1 ? a:2 : ['', [], 0]
  let t = a:r.table
  let ch = s:table_chars()
  let ncols = max([len(t.align)] + map(copy(t.rows), 'len(v:val)'))
  let align = t.align + repeat([''], ncols - len(t.align))
  let indent = s:display_indent(a:first_line, get(a:r, 'indent', 0))
  let prefix = quote . repeat(' ', max([0, indent - strdisplaywidth(quote)]))
  let cells = map(copy(t.rows), {i, row -> map(copy(row),
        \ {j, c -> s:cell_lines(c, get(images, i . ':' . j, {}), a:opts.cellw)})})
  let widths = s:table_widths(cells, ncols,
        \ a:opts.cols - strdisplaywidth(prefix) - (ncols * 3 + 1))

  let Rule = {a, b, c -> a . join(map(copy(widths), {_, w -> repeat(ch.h, w + 2)}), b) . c}
  let Border = {line, src -> s:add_line(a:v, prefix . line, src, qprops
        \ + [[len(prefix) + 1, 'mdview_table', len(line)], [len(prefix) + 1, 'mdview_table_border', len(line)]])}
  let src_lines = t.lines
  let first = {}   " row index -> its first viewer line
  call Border(Rule(ch.tl, ch.tm, ch.tr), src_lines[0])
  for i in range(len(cells))
    let wrapped = []
    for j in range(ncols)
      let lines = []
      for l in get(cells[i], j, [[]])
        if type(l) == v:t_dict
          " An image: as many lines as it is tall.
          for k in range(l.rows)
            call add(lines, extend(copy(l), #{k: k}))
          endfor
        else
          call extend(lines, s:wrap_chars(l, widths[j]))
        endif
      endfor
      call add(wrapped, lines)
    endfor
    let first[i] = len(a:v.lines) + 1
    for k in range(max(map(copy(wrapped), 'len(v:val)')))
      let line = prefix
      let props = []
      let keys = []
      for j in range(ncols)
        call add(props, [len(line) + 1, 'mdview_table_border', len(ch.v)])
        let line .= ch.v . ' '
        let chars = get(wrapped[j], k, [])
        let img = {}
        if type(chars) == v:t_dict
          let img = chars
          let chars = map(range(img.w), {-> [' ', '', 1]})
        endif
        let pad = widths[j] - s:chars_width(chars)
        let left = align[j] ==# 'r' ? pad : align[j] ==# 'c' ? pad / 2 : 0
        let line .= repeat(' ', max([0, left]))
        let cell_start = len(line)
        if !empty(img)
          call add(keys, img.img.key . '@' . strdisplaywidth(line) . '#' . img.k)
          if img.k == 0
            let s:next_id += 1
            let first_lnum = len(a:v.lines) + 1
            call add(a:v.anchors, #{id: s:next_id, key: img.img.key, path: img.img.path,
                  \ w: img.img.w, h: img.img.h, first: first_lnum,
                  \ last: first_lnum + img.rows - 1, indent: strdisplaywidth(line)})
          endif
        endif
        " Runs of one style, as properties.
        let run = ''
        let run_start = len(line)
        for c in chars + [['', "\x01", 0]]
          if c[1] !=# run
            for s in split(run, ',')
              if has_key(s:table_styles, s) && len(line) > run_start
                call add(props, [run_start + 1, s:table_styles[s], len(line) - run_start])
              endif
            endfor
            let run = c[1]
            let run_start = len(line)
          endif
          let line .= c[0]
        endfor
        if i == 0 && len(line) > cell_start
          call add(props, [cell_start + 1, 'mdview_table_header', len(line) - cell_start])
        endif
        let line .= repeat(' ', max([0, pad - left])) . ' '
      endfor
      call add(props, [len(line) + 1, 'mdview_table_border', len(ch.v)])
      let line .= ch.v
      call insert(props, [len(prefix) + 1, 'mdview_table', len(line) - len(prefix)])
      call s:add_line(a:v, line, src_lines[i], qprops + props)
      if !empty(keys)
        " The images on the line are part of it, for the diff in s:draw().
        let a:v.sig[-1] .= "\x02" . join(keys, ',')
      endif
    endfor
    if i == 0
      let first[-1] = len(a:v.lines) + 1   " the delimiter row
      call Border(Rule(ch.ml, ch.mm, ch.mr), a:r.start + 1)
    endif
  endfor
  call Border(Rule(ch.bl, ch.bm, ch.br), src_lines[-1])

  " Each source line of the table maps to the row it belongs to.
  let rows = [[src_lines[0], first[0]], [a:r.start + 1, first[-1]]]
  for i in range(1, len(src_lines) - 1)
    call add(rows, [src_lines[i], first[i]])
  endfor
  for l in range(a:r.start, a:r.end)
    let to = rows[0][1]
    for [sl, vl] in rows
      if sl <= l
        let to = vl
      endif
    endfor
    call add(a:v.map, to)
  endfor
endfunction

" The key under which an image result is remembered while it is redrawn:
" by its block, and for one in a table cell by the cell and its place there.
function! s:prev_key(r) abort
  return a:r.kind . ':' . a:r.start . (has_key(a:r, 'cell') ? ':' . join(a:r.cell, ':') : '')
endfunction

" The display column of byte offset col in line (tabs expanded).
function! s:display_indent(line, col) abort
  return strdisplaywidth(strpart(a:line, 0, a:col))
endfunction

" Lay out images side by side in rows of opts.cols columns, each row of
" images on as many viewer lines as its tallest image. quote: the bars of the
" quote the images are in (s:quote_prefix()), at the start of each row.
function! s:add_images(v, images, src_line, quote, opts, first_line) abort
  let rows = []   " [[image, x], ...]
  let x = 0
  for r in a:images
    let indent = s:display_indent(a:first_line, get(r, 'indent', 0))
    let w = (r.w + a:opts.cellw - 1) / a:opts.cellw
    if empty(rows) || x + w > a:opts.cols - indent
      call add(rows, [])
      let x = 0
    endif
    call add(rows[-1], [r, x, indent])
    let x += w + 1
  endfor
  for row in rows
    let first = len(a:v.lines) + 1
    let height = max(map(copy(row), {_, it -> max([1, it[0].rows])}))
    let sig = 'img:' . join(map(copy(row), {_, it -> it[0].key . '@' . (it[1] + it[2])}), ',')
    for k in range(height)
      call s:add_line(a:v, a:quote[0], a:src_line, a:quote[1])
      let a:v.sig[-1] = sig . '#' . k . '/' . height . '|' . a:v.sig[-1]
    endfor
    for [r, x, indent] in row
      let s:next_id += 1
      call add(a:v.anchors, #{id: s:next_id, key: r.key, path: r.path, w: r.w, h: r.h,
            \ first: first, last: first + max([1, r.rows]) - 1, indent: indent + x})
    endfor
  endfor
endfunction

" Add a line with properties [[col, type, length]] (col 1-based). A length
" that is a string is the text of a virtual text property.
function! s:add_line(v, line, src_line, props) abort
  call add(a:v.lines, a:line)
  call add(a:v.rmap, a:src_line)
  let lnum = len(a:v.lines)
  for [c, type, len] in a:props
    call add(a:v.props, [lnum, type, len, c])
  endfor
  call add(a:v.sig, a:line . "\x01" . string(a:props))
endfunction

" Copy source line l to the viewer, with its quote marks drawn as bars, its
" inline math replaced (and highlighted), and bold when it is a heading. cx:
" {headings, inline, quotes} of s:build_view().
function! s:copy_line(v, src_lines, l, cx) abort
  let src = a:src_lines[a:l - 1]
  if has_key(a:cx.codes, a:l) && s:code_line(a:v, a:src_lines, a:l, a:cx)
    return
  endif
  let [t, props, pos] = s:quote_prefix(src, get(a:cx.quotes, a:l, []), 0)
  let body = -1   " where the text of a plain quote starts (shown dimmed)
  if has_key(a:cx.quotes, a:l)
    let [_, alert, title] = a:cx.quotes[a:l][-1]
    if title
      " The first line of an alert ("> [!NOTE]"): its title.
      let text = get(get(g:, 'mdview_alert_titles', {}), alert, get(s:alert_titles, alert, alert))
      let t .= ' '
      call extend(props, [[len(t) + 1, 'mdview_alert_' . alert, len(text)],
            \ [len(t) + 1, 'mdview_heading', len(text)]])
      call add(a:v.map, len(a:v.lines) + 1)
      call s:add_line(a:v, t . text, a:l, props)
      return
    endif
    let body = empty(alert) ? len(t) : -1
  endif
  for [c, e, text] in sort(copy(get(a:cx.inline, a:l, [])), {x, y -> x[0] - y[0]})
    if c < pos
      continue
    endif
    let t .= strpart(src, pos, c - pos)
    call add(props, [len(t) + 1, 'mdview_math', len(text)])
    let t .= text
    let pos = e
  endfor
  let t .= strpart(src, pos)
  if body >= 0 && len(t) > body
    call add(props, [body + 1, 'mdview_quote', len(t) - body])
  endif
  if has_key(a:cx.headings, a:l) && !empty(t)
    call insert(props, [1, 'mdview_heading', len(t)])
  endif
  call add(a:v.map, len(a:v.lines) + 1)
  call s:add_line(a:v, t, a:l, props)
endfunction

" Draw the results into the viewer, changing only the lines whose signature
" changed: the lines (with their properties and popups) before and after the
" change stay as they are, so the images there are not sent to the terminal
" again.
function! s:draw(src, state) abort
  let viewer = a:state.viewer
  " Where each viewer window is, as a source line, to come back to it.
  let views = {}
  for win in win_findbuf(viewer)
    let info = getwininfo(win)[0]
    let views[win] = #{top: get(a:state.rmap, info.topline - 1, 1),
          \ cur: get(a:state.rmap, getcurpos(win)[1] - 1, 1)}
  endfor
  let prev = get(a:state, 'prev', {})
  let v = s:build_view(a:src, a:state.results,
        \ #{cellw: get(a:state, 'cell', [8, 16])[0], cols: get(a:state, 'cols', 80), prev: prev})
  " Remember the images, for blocks that are redrawn later.
  for r in a:state.results
    if !empty(get(r, 'path', ''))
      let prev[s:prev_key(r)] = r
    endif
  endfor
  let a:state.prev = prev

  let old_sig = get(a:state, 'sig', [])
  if empty(old_sig)
    let old_sig = map(getbufline(viewer, 1, '$'), {_, l -> 'initial'})
  endif
  let old_anchors = get(a:state, 'anchors', [])
  let [p, q] = s:unchanged(old_sig, v.sig, old_anchors, v.anchors)
  let oldn = len(old_sig)
  let newn = len(v.sig)
  let delta = newn - oldn

  let moved = 0
  if p + q < max([oldn, newn]) || oldn != newn
    call setbufvar(viewer, '&modifiable', 1)
    if p == 0 && q == 0
      silent call deletebufline(viewer, 1, '$')
      call setbufline(viewer, 1, v.lines)
    else
      if oldn - q > p
        silent call deletebufline(viewer, p + 1, oldn - q)
      endif
      if newn - q > p
        call appendbufline(viewer, p, v.lines[p : newn - q - 1])
      endif
    endif
    for [lnum, type, len, col] in v.props
      if lnum > p && lnum <= newn - q
        call prop_add(lnum, col, type(len) == v:t_string
              \ ? #{bufnr: viewer, type: type, text: len}
              \ : #{bufnr: viewer, type: type, length: len})
      endif
    endfor
    call setbufvar(viewer, '&modifiable', 0)
    call setbufvar(viewer, '&modified', 0)
  endif

  " Anchors: the unchanged ones keep their ids, properties and popups (moved
  " by delta after the change); those in the changed lines are new.
  let kept_before = filter(copy(old_anchors), {_, a -> a.last <= p})
  let kept_after = filter(copy(old_anchors), {_, a -> a.first > oldn - q})
  let removed = filter(copy(old_anchors), {_, a -> a.last > p && a.first <= oldn - q})
  let added = filter(copy(v.anchors), {_, a -> a.first > p && a.last <= newn - q})
  for a in kept_after
    let a.first += delta
    let a.last += delta
  endfor
  for a in added
    call prop_add(a.first, 1, #{bufnr: viewer, type: 'mdview_anchor', id: a.id, length: 0})
    call prop_add(a.last, 1, #{bufnr: viewer, type: 'mdview_anchor_end', id: a.id, length: 0})
  endfor
  let a:state.anchors = kept_before + added + kept_after
  if get(a:state, 'code', []) != v.code
    call s:code_syntax(viewer, v.code)
  endif
  let a:state.code = v.code
  let a:state.sig = v.sig
  let a:state.map = v.map
  let a:state.rmap = v.rmap
  if empty(get(a:state, 'gen', 0))
    let a:state.gen = 1
  endif

  " Popups of the windows that have them: close the removed, add the new.
  let removed_ids = {}
  for a in removed
    let removed_ids[a.id] = 1
  endfor
  for [win, pp] in items(s:popups)
    if pp.src != a:src || pp.gen != a:state.gen
      continue
    endif
    for it in filter(copy(pp.items), {_, it -> has_key(removed_ids, it.anchor.id)})
      call popup_close(it.pid)
    endfor
    call filter(pp.items, {_, it -> !has_key(removed_ids, it.anchor.id)})
    for a in added
      let it = s:popup_for(str2nr(win), a)
      if !empty(it)
        call add(pp.items, it)
      endif
    endfor
  endfor
  let moved = !empty(removed) || !empty(added) || (delta != 0 && !empty(kept_after))

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
  if moved
    call s:schedule_clear()
  endif
endfunction

" The numbers of leading and trailing lines whose signatures are the same,
" not splitting an image (an image that is only partly unchanged is redrawn).
function! s:unchanged(old, new, old_anchors, new_anchors) abort
  let oldn = len(a:old)
  let newn = len(a:new)
  let p = 0
  while p < oldn && p < newn && a:old[p] ==# a:new[p]
    let p += 1
  endwhile
  let q = 0
  while q < oldn - p && q < newn - p && a:old[oldn - 1 - q] ==# a:new[newn - 1 - q]
    let q += 1
  endwhile
  let changed = 1
  while changed
    let changed = 0
    for [anchors, n] in [[a:old_anchors, oldn], [a:new_anchors, newn]]
      for a in anchors
        if a.first <= p && a.last > p
          let p = a.first - 1
          let changed = 1
        endif
        if a.first <= n - q && a.last > n - q
          let q = n - a.last
          let changed = 1
        endif
      endfor
    endfor
  endwhile
  return [p, q]
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

" With g:mdview_sync_back, scrolling the viewer scrolls the source too (the
" other way of s:follow; s:syncing keeps them from chasing each other). Only
" the source's view moves, not its cursor.
function! s:follow_back(src, win) abort
  let state = s:state(a:src)
  if !get(g:, 'mdview_sync_back', 0) || empty(state) || state.here || s:syncing
        \ || win_getid() != a:win
    return
  endif
  let info = getwininfo(a:win)[0]
  let top = get(state.rmap, info.topline - 1, 1)
  let s:syncing = 1
  try
    for win in win_findbuf(a:src)
      call win_execute(win, 'call s:set_topline(' . top . ')')
    endfor
  finally
    let s:syncing = 0
  endtry
endfunction

" Scroll the current window so that line top is at the top, keeping the
" cursor where it is when it stays visible.
function! s:set_topline(top) abort
  let view = winsaveview()
  let view.topline = a:top
  let lnum = line('.')
  let bot = a:top + winheight(0) - 1
  if lnum < a:top || lnum > bot
    let view.lnum = lnum < a:top ? a:top : bot
  endif
  call winrestview(view)
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
  setlocal filetype=markdown
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
    let it = s:popup_for(a:win, a)
    if !empty(it)
      call add(items, it)
    endif
  endfor
  let s:popups[a:win] = #{src: a:src, gen: a:state.gen, items: items,
        \ top: getwininfo(a:win)[0].topline}
endfunction

" A popup showing the image of anchor a in window win, as an item of
" s:popups ({pid, anchor, mode, img}), or {} when the image cannot be loaded.
function! s:popup_for(win, a) abort
  let img = s:image_id(a:a)
  if img < 0
    return {}
  endif
  let mode = s:mode(a:win, a:a)
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
        \ }, s:popup_opts(a:win, a:a, mode))
  try
    return #{pid: popup_create('', opts), anchor: a:a, mode: mode, img: img}
  catch
    call s:warn(v:exception)
    return {}
  endtry
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
  for [win, p] in items(s:popups)
    call s:update_modes(str2nr(win))
    let top = get(getwininfo(str2nr(win)), 0, #{topline: p.top}).topline
    if top != p.top
      let p.top = top
      if !empty(p.items)
        call s:schedule_clear()
      endif
      call s:follow_back(p.src, str2nr(win))
    endif
  endfor
endfunction

" A terminal keeps the pixels of a sixel image until the cells under it are
" written again, and Vim only writes the cells that changed. When the images
" move (a scroll, a new drawing), the old pixels stay behind, and the popup's
" background may cover the new ones. Clearing the screen (:redraw!) wipes the
" old pixels and makes Vim send every visible image again. Done once shortly
" after the last move.
function! s:schedule_clear() abort
  if !s:clear_enabled()
    return
  endif
  call timer_stop(s:clear_timer)
  let s:clear_timer = timer_start(30, {-> s:clear_now()})
endfunction

function! s:clear_now() abort
  " Only when a window shows images.
  if empty(filter(values(s:popups), {_, p -> !empty(p.items)}))
    return
  endif
  redraw!
endfunction

" Whether to draw diagrams, math and images. g:mdview_images: 1 always (when
" Vim can show images), 0 never, -1 (default) when the terminal has an image
" protocol (v:imagebackend is set and not "none"; it is empty before Vim
" chose one, as in -es). Otherwise their source is shown.
function! s:images_enabled() abort
  if !has('image') || !has('image_popup') || !has('popupwin')
    return 0
  endif
  let v = get(g:, 'mdview_images', -1)
  if v >= 0
    return v ? 1 : 0
  endif
  let backend = get(v:, 'imagebackend', '')
  return !empty(backend) && backend !=# 'none'
endfunction

" g:mdview_clear_redraw: 1 on, 0 off, -1 (default) only with sixel, the
" backend that leaves the old pixels behind.
function! s:clear_enabled() abort
  let v = get(g:, 'mdview_clear_redraw', -1)
  if v >= 0
    return v
  endif
  return exists('v:imagebackend') && v:imagebackend ==# 'sixel'
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

" Draw again when a viewer's size changed.
function! s:on_resized() abort
  call timer_stop(s:resize_timer)
  let s:resize_timer = timer_start(300, {-> s:resized()})
endfunction

function! s:resized() abort
  for src in s:sources()
    let state = s:state(src)
    let wins = win_findbuf(state.viewer)
    if !empty(wins) && (winwidth(wins[0]) != get(state, 'width', -1)
          \ || winheight(wins[0]) != get(state, 'height', -1))
      " Images fit the width, and their height is capped by the window's.
      call mdview#refresh(src)
    endif
  endfor
endfunction
