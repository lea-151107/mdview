" Tests of how mdview is installed: plugin managers and goda.vim.

let s:root = fnamemodify(expand('<sfile>:p:h'), ':h')

" A plugin manager may link the files of mdview into a directory it shares
" with other plugins (goda-pm.vim's "merged"): bin/ and go/ are still found
" in mdview's own directory.
function! Test_root_follows_links() abort
  let d = tempname()
  call mkdir(d . '/autoload', 'p')
  let out = d . '/out'
  try
    call system('ln -s ' . shellescape(s:root . '/autoload/mdview.vim') . ' '
          \ . shellescape(d . '/autoload/mdview.vim'))
    call assert_equal(0, v:shell_error)
    " In a Vim of its own: the script here is already sourced.
    call system(join(map([v:progpath, '-Nu', 'NONE', '-i', 'NONE', '-es',
          \ '--cmd', 'set rtp^=' . d, '-c', 'runtime autoload/mdview.vim',
          \ '-c', 'let s = getscriptinfo(#{name: "autoload/mdview.vim"})[0]',
          \ '-c', 'call writefile([s.name, function("<SNR>" . s.sid . "_bin")()], "' . out . '")',
          \ '-c', 'qa!'], 'shellescape(v:val)')))
    let [name, bin] = readfile(out)
    call assert_match('^' . d, name)
    call assert_equal(s:root . '/bin/mdview', bin)
  finally
    call delete(d, 'rf')
  endtry
endfunction

" goda.vim names goda_{plugin}#build() in its messages to build again when
" it exists (exists() does not load an autoload script): s:init() loads it.
function! Test_goda_build_function() abort
  call assert_true(filereadable(s:root . '/autoload/goda_mdview.vim'))
  execute 'source' fnameescape(s:root . '/autoload/goda_mdview.vim')
  call assert_true(exists('*goda_mdview#build'))
  call assert_match("runtime autoload/goda_mdview.vim",
        \ join(readfile(s:root . '/autoload/mdview.vim'), "\n"))
endfunction
