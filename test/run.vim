" Tests of autoload/mdview.vim that need neither the Go binary nor a terminal
" that shows images. Run: vim -Nu NONE -i NONE -es -S test/run.vim
" (make test-vim). Exits with status 1 when a test fails.

set nocompatible
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
