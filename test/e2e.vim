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
        \ '```go', 'func main() {}', '```', '', '[二つ目へ](#二つ目) と [次へ](u.md#sec)', '',
        \ '## 二つ目'], src)
  execute 'edit' fnameescape(src)
  Mdview
  call s:check(s:wait('s:drawn()'), 'not drawn: ' . string(s:viewer_lines())
        \ . ' ' . string(goda#log('mdview')))

  " Links: to another document's heading (its viewer in place of this one),
  " back, and to a heading of the document.
  call writefile(['# U', '', 'text', '', '## Sec', '', '[戻る](t.md)'], $MDVIEW_E2E_CACHE . '/u.md')
  let nwin = winnr('$')
  let vwin = win_getid(winnr('l'))
  call win_gotoid(vwin)
  call search('次へ')
  call mdview#jump()
  call s:check(s:wait('join(s:viewer_lines()) =~# "戻る"'), 'no viewer of u.md: ' . string(s:viewer_lines()))
  call s:check(bufname(winbufnr(vwin)) =~# 'u\.md$', 'the viewer of u.md elsewhere: ' . bufname(winbufnr(vwin)))
  call s:check(winnr('$') == nwin && win_getid() == vwin, 'windows: ' . winnr('$') . ' ' . win_getid())
  " (Once drawn: the heading is known from the results.)
  let uwin = get(win_findbuf(bufnr('u.md')), 0, 0)
  call s:check(uwin > 0 && s:wait('getcurpos(' . uwin . ')[1] == 5'), 'not at ## Sec: ' . string(getcurpos(uwin)))
  call search('戻る')
  call mdview#jump()
  call s:check(s:wait('s:drawn()'), 'not back: ' . string(s:viewer_lines()))
  call search('二つ目へ')
  call mdview#jump()
  let twin = get(win_findbuf(bufnr('t.md')), 0, 0)
  call s:check(twin > 0 && getcurpos(twin)[1] == 13, 'not at ## 二つ目: ' . string(getcurpos(twin)))
  " <BS>: back to the link to ## 二つ目, then to u.md where 戻る was.
  call s:check(maparg('<BS>', 'n') ==# '<Cmd>call mdview#back()<CR>', 'no <BS>: ' . maparg('<BS>', 'n'))
  call mdview#back()
  call s:check(getcurpos(twin)[1] == 11, 'not back at the link: ' . string(getcurpos(twin)))
  call mdview#back()
  let uwin = get(win_findbuf(bufnr('u.md')), 0, 0)
  call s:check(uwin > 0 && s:wait('getcurpos(' . uwin . ')[1] == 7'), 'not back in u.md: ' . string(getcurpos(uwin)))
  call s:check(bufname(winbufnr(vwin)) =~# 'u\.md$' && winnr('$') == nwin, 'the viewer of u.md: ' . bufname(winbufnr(vwin)))
  " And back to t.md, at the link to u.md.
  call mdview#back()
  let twin = get(win_findbuf(bufnr('t.md')), 0, 0)
  call s:check(twin > 0 && s:wait('getcurpos(' . twin . ')[1] == 11'), 'not back in t.md: ' . string(getcurpos(twin)))
  call s:check(s:wait('s:drawn()'), 'not drawn back in t.md')
  wincmd p

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
