" The build function of mdview by goda.vim's convention (goda_{name}#build()),
" which goda.vim names in its messages, and which a plugin manager's hook can
" call: as :MdviewBuild.
function! goda_mdview#build() abort
  call mdview#build()
endfunction
