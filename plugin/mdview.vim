" mdview - draw mermaid, math and images inside Markdown buffers.
if exists('g:loaded_mdview')
  finish
endif
let g:loaded_mdview = 1

command! -bar MdviewEnable     call mdview#enable()
command! -bar MdviewDisable    call mdview#disable()
command! -bar MdviewToggle     call mdview#toggle()
command! -bar MdviewRefresh    call mdview#refresh()
command! -bar MdviewBuild      call mdview#build()
command! -bar MdviewClearCache call mdview#clear_cache()
command! -bar MdviewLog        for s:l in mdview#log() | echomsg s:l | endfor

augroup mdview_auto
  autocmd!
  autocmd FileType markdown
        \ if get(g:, 'mdview_auto_enable', 1) | call mdview#enable() | endif
augroup END
