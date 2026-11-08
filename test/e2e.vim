" End-to-end test with a real Vim, goda.vim and the binary: run by
" go/e2e_test.go (go test), which gives the paths in $MDVIEW_E2E_*. Writes
" "ok", or what failed, to $MDVIEW_E2E_RESULT.

set nocompatible noswapfile
let s:errors = []

function! s:check(cond, msg) abort
  if !a:cond
    call add(s:errors, a:msg)
  endif
endfunction

" Wait (up to 20 s) until cond (an expression) is true; the replies of the
" binary come meanwhile.
function! s:wait(cond) abort
  for _ in range(400)
    if eval(a:cond)
      return 1
    endif
    sleep 50m
  endfor
  return 0
endfunction

function! s:viewer_lines() abort
  for b in range(1, bufnr('$'))
    if bufname(b) =~# '^mdview://'
      return getbufline(b, 1, '$')
    endif
  endfor
  return []
endfunction

function! s:drawn() abort
  let text = join(s:viewer_lines(), "\n")
  return text =~# '┌' && text =~# '╭'
endfunction

try
  execute 'set runtimepath^=' . fnameescape(expand('<sfile>:p:h:h')) . ','
        \ . fnameescape($MDVIEW_E2E_GODA)
  runtime plugin/mdview.vim
  let g:mdview_bin = $MDVIEW_E2E_BIN
  let g:mdview_cache_dir = $MDVIEW_E2E_CACHE
  let g:mdview_images = 0

  let src = $MDVIEW_E2E_CACHE . '/t.md'
  call writefile(['# 見出し', '', '| a | b |', '|---|---|', '| 1 | 2 |', '',
        \ '```go', 'func main() {}', '```'], src)
  execute 'edit' fnameescape(src)
  Mdview
  call s:check(s:wait('s:drawn()'), 'not drawn: ' . string(s:viewer_lines())
        \ . ' ' . string(goda#log('mdview')))

  " A binary of another version is refused, and goda.vim says to build it
  " again.
  call goda#stop('mdview')
  call goda#register('mdview', g:mdview_bin, #{version: 0})
  let err = ''
  try
    call goda#request('mdview', 'prune', $MDVIEW_E2E_CACHE, 30.0)
  catch
    let err = v:exception
  endtry
  call s:check(err =~# 'build the binary again', 'version error: ' . err)

  " The build registers the plugin again: the start that failed is tried
  " again, and the viewer is drawn again.
  silent call mdview#build()
  let err = ''
  try
    call goda#request('mdview', 'prune', $MDVIEW_E2E_CACHE, 30.0)
  catch
    let err = v:exception
  endtry
  call s:check(err ==# '', 'after the build: ' . err)
  call s:check(s:wait('s:drawn()'), 'not drawn after the build')

  " Without the binary, the start (of the binary g:mdview_bin says now) says
  " to build it.
  call goda#stop('mdview')
  let g:mdview_bin = $MDVIEW_E2E_CACHE . '/no-such-binary'
  let err = ''
  try
    call goda#request('mdview', 'prune', $MDVIEW_E2E_CACHE, 30.0)
  catch
    let err = v:exception
  endtry
  call s:check(err =~# 'does not exist yet; build it with :MdviewBuild', 'no binary: ' . err)
catch
  call add(s:errors, v:exception . ' at ' . v:throwpoint)
endtry

call writefile(empty(s:errors) ? ['ok'] : s:errors, $MDVIEW_E2E_RESULT)
qall!
