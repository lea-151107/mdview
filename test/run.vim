" Tests of autoload/mdview.vim that need neither the Go binary nor a terminal
" that shows images. Run: vim -Nu NONE -i NONE -es -S test/run.vim
" (make test-vim). Exits with status 1 when a test fails.

set nocompatible noswapfile
let s:dir = expand('<sfile>:p:h')
execute 'set runtimepath^=' . fnameescape(fnamemodify(s:dir, ':h'))
runtime autoload/mdview.vim
let s:sid = getscriptinfo(#{name: 'autoload/mdview.vim'})[0].sid
function! S(name) abort
  return function('<SNR>' . s:sid . '_' . a:name)
endfunction

" A source buffer holding lines; returns its number.
function! Src(lines) abort
  enew!
  setlocal buftype=nofile
  call setline(1, a:lines)
  return bufnr('%')
endfunction

" The property types s:init() would add (it needs +image and goda.vim).
for s:t in ['mdview_anchor', 'mdview_anchor_end', 'mdview_text', 'mdview_error',
      \ 'mdview_pending', 'mdview_math', 'mdview_heading']
  if empty(prop_type_get(s:t))
    call prop_type_add(s:t, {})
  endif
endfor
call S('init_table')()
call S('init_quote')()
call S('init_code')()

" A source buffer and a viewer for it, with the state mdview#open() makes.
function! Viewer(lines) abort
  let src = Src(a:lines)
  new
  setlocal buftype=nofile
  let viewer = bufnr('%')
  call setline(1, a:lines)
  let b:mdview_source = src
  wincmd p
  call setbufvar(src, 'mdview', #{viewer: viewer, results: [], map: range(1, len(a:lines)),
        \ rmap: range(1, len(a:lines)), gen: 0, tick: -1, here: 0, bufhidden: '', req_id: 1})
  return [src, viewer]
endfunction

let s:failed = 0
let s:out = []
for s:file in glob(s:dir . '/test_*.vim', 0, 1)
  execute 'source' fnameescape(s:file)
endfor
for s:name in sort(filter(map(split(execute('function /^Test_'), "\n"),
      \ {_, l -> matchstr(l, 'Test_\w\+')}), '!empty(v:val)'))
  let v:errors = []
  try
    call call(s:name, [])
  catch
    call add(v:errors, s:name . ': ' . v:exception . ' at ' . v:throwpoint)
  endtry
  if empty(v:errors)
    call add(s:out, 'ok   ' . s:name)
  else
    let s:failed += 1
    call add(s:out, 'FAIL ' . s:name)
    call extend(s:out, map(copy(v:errors), {_, e -> '     ' . e}))
  endif
endfor
call add(s:out, s:failed ? s:failed . ' failed' : 'all passed')
call writefile(s:out, '/dev/stdout')
if s:failed
  cquit!
endif
qall!
