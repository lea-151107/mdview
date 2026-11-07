" mdview - a viewer for Markdown with mermaid, math and images drawn.
if exists('g:loaded_mdview')
  finish
endif
let g:loaded_mdview = 1

command! -bar -nargs=? -complete=customlist,mdview#complete Mdview
      \ call mdview#open(<q-args>)
command! -bar MdviewRefresh    call mdview#refresh()
command! -bar MdviewBuild      call mdview#build()
command! -bar MdviewClearCache call mdview#clear_cache()
command! -bar MdviewLog        for s:l in mdview#log() | echomsg s:l | endfor
