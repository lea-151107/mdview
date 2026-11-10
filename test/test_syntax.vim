" The markdown syntax of the viewer: what it conceals in the lines shown as
" their source, and the lines it is kept off.

" The text of line lnum as shown, with the concealed characters left out.
function! s:shown(lnum) abort
  let t = getline(a:lnum)
  let out = ''
  let c = 1
  while c <= len(t)
    let ch = matchstr(t, '.', c - 1)
    let cc = synconcealed(a:lnum, c)
    let out .= cc[0] ? cc[1] : ch
    let c += len(ch)
  endwhile
  return out
endfunction

function! Test_intraword_underscore() abort
  syntax on
  new
  setlocal buftype=nofile filetype=markdown conceallevel=2
  let b:mdview_source = 0
  call setline(1, ['## 見出しの日本_語です', '## 日本_語_です', '## _斜体_ と「_斜体_」',
        \ '## snake_case と __init__ と 日本__語__です', '## 日本*語*です', '続き_の行'])
  call S('code_syntax_here')([], 1)
  " A _ after a letter (Japanese too) starts no italic: it stays, and the
  " lines after it are not italic.
  call assert_equal('## 見出しの日本_語です', s:shown(1))
  call assert_equal('## 日本_語_です', s:shown(2))
  call assert_equal('続き_の行', s:shown(6))
  call assert_notequal('markdownItalic', synIDattr(synID(6, 1, 1), 'name'))
  " After a space, punctuation or the start, and *: italic and bold as before.
  call assert_equal('## 斜体 と「斜体」', s:shown(3))
  call assert_equal('## snake_case と init と 日本__語__です', s:shown(4))
  call assert_equal('## 日本語です', s:shown(5))
  " The heading's colors go on over the _.
  call assert_equal('markdownH2', synIDattr(synID(1, stridx(getline(1), '_') + 1, 1), 'name'))
  bwipeout!
  syntax off
endfunction

function! Test_table_without_markdown_syntax() abort
  let src = Src(['| 日本_語です |', '|--|'])
  let table = #{kind: 'table', start: 1, end: 2, indent: 0,
        \ table: #{align: [''], rows: [[[['日本_語です', '']]]], lines: [1]}}
  let v = S('build_view')(src, [table], #{cellw: 8, cols: 80})
  " The table's lines (its borders too) are a region without the markdown
  " syntax, as a paragraph's.
  call assert_equal([[1, len(v.lines), '-', 1]], v.code)
endfunction
