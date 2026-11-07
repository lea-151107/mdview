" s:mode(): which anchor a popup uses, by where its lines are in the window.

function! Test_mode() abort
  call Src(map(range(1, 200), 'v:val'))
  call winrestview(#{topline: 50})
  redraw
  let info = getwininfo(win_getid())[0]
  let [top, bot] = [info.topline, info.botline]
  let Mode = S('mode')
  let w = win_getid()
  " Inside the window: the bottom anchor.
  call assert_equal('end', Mode(w, #{first: top + 1, last: top + 3}))
  " Top above the window, bottom inside: still the bottom (top is clipped).
  call assert_equal('end', Mode(w, #{first: top - 5, last: top + 2}))
  " Bottom below the window, top inside: the top anchor.
  call assert_equal('start', Mode(w, #{first: bot - 1, last: bot + 5}))
  " Taller than the window on both sides: the bottom (hidden).
  call assert_equal('end', Mode(w, #{first: top - 2, last: bot + 2}))
endfunction

function! Test_build_view_pending() abort
  let src = Src(['```mermaid', 'graph TD', '```'])
  let v = S('build_view')(src, [#{kind: 'mermaid', start: 1, end: 3, pending: 1}])
  call assert_equal(['```mermaid', 'graph TD', '```', 'mdview: drawing…'], v.lines)
  call assert_equal('mdview_pending', v.props[0][1])
endfunction
