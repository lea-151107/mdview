" Tests of how mdview is installed and built: plugin managers and goda.vim.

let s:root = fnamemodify(expand('<sfile>:p:h'), ':h')

" A goda.vim of which goda#build() keeps its argument in g:built (and throws
" g:build_error when set), in a new directory for 'runtimepath'.
function! s:fake_goda() abort
  let d = tempname()
  call mkdir(d . '/autoload', 'p')
  call writefile([
        \ 'function! goda#build(opts) abort',
        \ '  let g:built = a:opts',
        \ '  let g:built_workspace = get(g:, ''goda#workspace'', ''unset'')',
        \ '  if exists(''g:build_error'') | throw g:build_error | endif',
        \ 'endfunction',
        \ 'function! goda#is_running(...) abort',
        \ '  return 0',
        \ 'endfunction',
        \ 'function! goda#register(plugin, starter, opts = {}) abort',
        \ '  let g:registered = [a:plugin, a:starter, a:opts]',
        \ 'endfunction',
        \ ], d . '/autoload/goda.vim')
  call writefile(['module github.com/Shougo/goda.vim', '', 'go 1.26'], d . '/go.mod')
  return d
endfunction

" mdview#build() builds go/ of mdview into s:bin() with goda#build().
function! Test_build_with_goda() abort
  if !executable('go')
    return
  endif
  let goda = s:fake_goda()
  let rtp = &runtimepath
  try
    execute 'set runtimepath^=' . fnameescape(goda)
    let g:mdview_bin = goda . '/bin/mdview'
    silent call mdview#build()
    call assert_equal(#{name: 'mdview', dir: s:root . '/go', bin: goda . '/bin/mdview'},
          \ get(g:, 'built', {}))
    " With the goda.vim installed (its Go module), as goda-pm.vim does; only
    " for the build.
    call assert_equal([resolve(goda)], g:built_workspace)
    call assert_false(exists('g:goda#workspace'))
    " That of the user (goda-pm.vim's, or [] for the versions of go.mod) is
    " used as it is.
    let g:goda#workspace = []
    silent call mdview#build()
    call assert_equal([], g:built_workspace)
    call assert_equal([], g:goda#workspace)
    unlet g:goda#workspace
    " Registered again, with the start of the binary: a start that failed is
    " tried again.
    call assert_equal('mdview', get(g:, 'registered', [''])[0])
    call assert_equal(v:t_func, type(g:registered[1]))
    call assert_true(has_key(g:registered[2], 'version'))
    " A failed build is shown, not thrown, and registers nothing.
    unlet g:registered
    let g:build_error = "goda-mdview: go build failed:\nmain.go:1: error"
    let msgs = execute('call mdview#build()')
    call assert_match('main.go:1: error', msgs)
    " Said as mdview's, not with goda.vim's own "goda-" name.
    call assert_match('mdview: go build failed', msgs)
    call assert_notmatch('goda-mdview', msgs)
    call assert_false(exists('g:registered'))
  finally
    let &runtimepath = rtp
    unlet! g:mdview_bin g:built g:build_error g:registered g:built_workspace g:goda#workspace
    call delete(goda, 'rf')
  endtry
endfunction

" The binary is built into a cache directory, not into the plugin.
function! Test_bin_in_cache() abort
  let Bin = S('bin')
  let saved = $XDG_CACHE_HOME
  try
    let $XDG_CACHE_HOME = '/cache'
    call assert_equal('/cache/vim/mdview/mdview' . (has('win32') ? '.exe' : ''), Bin())
    let g:mdview_bin = '/x/mdview'
    call assert_equal('/x/mdview', Bin())
  finally
    let $XDG_CACHE_HOME = saved
    unlet! g:mdview_bin
  endtry
endfunction

" A plugin manager may link the files of mdview into a directory it shares
" with other plugins (goda-pm.vim's "merged"): go/ is still found in
" mdview's own directory.
function! Test_root_follows_links() abort
  if !executable('go')
    return
  endif
  let d = tempname()
  call mkdir(d . '/autoload', 'p')
  let goda = s:fake_goda()
  let out = d . '/out'
  try
    call system('ln -s ' . shellescape(s:root . '/autoload/mdview.vim') . ' '
          \ . shellescape(d . '/autoload/mdview.vim'))
    call assert_equal(0, v:shell_error)
    " In a Vim of its own: the script here is already sourced.
    call system(join(map([v:progpath, '-Nu', 'NONE', '-i', 'NONE', '-es',
          \ '--cmd', 'set rtp^=' . d . ',' . goda,
          \ '-c', 'let g:mdview_bin = "' . d . '/mdview"',
          \ '-c', 'silent call mdview#build()',
          \ '-c', 'let s = getscriptinfo(#{name: "autoload/mdview.vim"})[0]',
          \ '-c', 'call writefile([s.name, g:built.dir], "' . out . '")',
          \ '-c', 'qa!'], 'shellescape(v:val)')))
    let [name, dir] = readfile(out)
    call assert_match('^' . d, name)
    call assert_equal(s:root . '/go', dir)
  finally
    call delete(d, 'rf')
    call delete(goda, 'rf')
  endtry
endfunction

" The build needs go/ of mdview itself: not that of a directory a plugin
" manager shares with other plugins (copied or hard linked files).
function! Test_is_mdview_module() abort
  let Is = S('is_mdview_module')
  call assert_true(Is(s:root . '/go'))
  let d = tempname()
  call mkdir(d, 'p')
  try
    call assert_false(Is(d))
    call writefile(['module github.com/someone/other', '', 'go 1.26'], d . '/go.mod')
    call assert_false(Is(d))
  finally
    call delete(d, 'rf')
  endtry
endfunction
