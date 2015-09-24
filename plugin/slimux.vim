" Tmux integration for Vim
" Maintainer Esa-Matti Suuronen <esa-matti@suuronen.org>
" License: MIT. See LICENSE




let s:slimux_panelist_cmd = "tmux list-panes -a"
let s:retry_send = {}
let s:last_selected_pane = ""

function! s:PickPaneIdFromLine(line)
    let l:pane_match = matchlist(a:line, '\(^[^ ]\+\)\: ')
    if len(l:pane_match) == 0
        return ""
    endif
    return l:pane_match[1]
endfunction

function! SlimuxGetPaneList(lead, ...)
    let l:panes = system(s:slimux_panelist_cmd)
    let l:lst = map(split(l:panes, '\n'), 's:PickPaneIdFromLine(v:val)')

    if !exists("g:slimux_exclude_vim_pane") || g:slimux_exclude_vim_pane != 0
        " Remove current pane from pane list
        let l:current_pane_id = system('tmux display-message -p "#{session_name}:#{window_index}.#{pane_index}"')
        let l:current_pane_id = substitute(l:current_pane_id, "\n", "", "g")
        let l:lst = filter(l:lst, 'v:val !~ "' . l:current_pane_id . '"')
    endif
    if exists("g:slimux_exclude_other_sessions") && g:slimux_exclude_other_sessions != 0
        let l:current_session_id = system('tmux display-message -p "#{session_name}"')
        let l:current_session_id = substitute(l:current_session_id, "\n", "", "g")
        let l:lst = filter(l:lst, 'v:val =~ "' . l:current_session_id . ':"')
    endif

    return filter(l:lst, 'v:val =~ ''\V\^''. a:lead')
endfunction

function! s:ConfSetPane(tmux_packet, target_pane)
  " Configure current packet
  let a:tmux_packet["target_pane"] = a:target_pane
  " Save last selected pane
  let s:last_selected_pane = a:target_pane

  let type = a:tmux_packet["type"]

  if type == "global"
      if !exists("b:code_packet")
          let b:code_packet = { "target_pane": "", "type": "code" }
      endif
      let b:code_packet["target_pane"] = a:tmux_packet["target_pane"]
      let s:cmd_packet["target_pane"] = a:tmux_packet["target_pane"]
      let s:keys_packet["target_pane"] = a:tmux_packet["target_pane"]
      return
  endif

  if !empty(s:retry_send)
      call s:Send(s:retry_send)
      let s:retry_send = {}
  endif

  if !empty(s:retry_send)
      call s:Send(s:retry_send)
      let s:retry_send = {}
  endif
endfunction

function! g:_SlimuxPickPaneFromBuf(tmux_packet, test)
    let l:target_pane = s:PickPaneIdFromLine(getline("."))
    if l:target_pane == ""
       echo "Please select a pane with enter or exit with 'q'"
       return
     endif

     " Test only. Do not send the real packet or configure anything. Instead
     " just send line break to see on which pane the cursor is on.
     if a:test
        return s:Send({ "target_pane": l:target_pane, "text": "\n", "type": "code" })
     endif

     hide
    call s:ConfSetPane(a:tmux_packet, l:target_pane)
endfunction

function! s:SelectPane(tmux_packet, ...)
     " Save config dict to global so that it can be accessed later
     let g:SlimuxActiveConfigure = a:tmux_packet

    if a:0 >= 1
        if a:1 != ""
            call s:ConfSetPane(g:SlimuxActiveConfigure, a:1)
            return
        endif
    endif

    " Create new buffer in a horizontal split
    belowright new

    " Get syntax highlighting from specified filetype
    if !exists("g:slimux_buffer_filetype")
      let g:slimux_buffer_filetype = 'sh'
    endif
    let &filetype=g:slimux_buffer_filetype

    " Set header for the menu buffer
    call setline(1, "# Enter: Select pane - Space/x: Test - C-c/q: Cancel")
    call setline(2, "")

    " Add last used pane as the first
    if len(s:last_selected_pane) != 0
      call setline(3, s:last_selected_pane . ": (last one used)")
    endif

    " List all tmux panes at the end
    normal G

    " Put tmux panes in the buffer.
    if !exists("g:slimux_pane_format")
      let g:slimux_pane_format = '#{session_name}:#{window_index}.#{pane_index}: #{window_name}: #{pane_title} [#{pane_width}x#{pane_height}]#{?pane_active, (active),}'
    endif

    " We need the pane_id at the beginning of the line so we can
    " identify the selected target pane
    let l:format = '#{pane_id}: ' . g:slimux_pane_format
    let l:command = "tmux list-panes -F '" . escape(l:format, '#') . "'"

    " if g:slimux_select_from_current_window = 1, then list panes from current
    " window only.
    if !exists("g:slimux_select_from_current_window") || g:slimux_select_from_current_window != 1
      let l:command .= ' -a'
    endif

    if !exists("g:slimux_exclude_vim_pane") || g:slimux_exclude_vim_pane != 0
        " Remove current pane from pane list
        let l:current_pane_id = system('tmux display-message -p "\#{pane_id}"')
        let l:current_pane_id = substitute(l:current_pane_id, "\n", "", "g")
        let l:command .= " | grep -E -v " . shellescape("^" . l:current_pane_id, 1)
    endif
    if exists("g:slimux_exclude_other_sessions") && g:slimux_exclude_other_sessions != 0
        let l:current_session_id = system('tmux display-message -p "#{session_name}"')
        let l:current_session_id = substitute(l:current_session_id, "\n", "", "g")
        let l:command .= " | grep -E " . shellescape(" " . l:current_session_id . ":", 1)
    endif

    " Warn if no additional pane is found
    let l:no_panes_warning = "No additional panes found"
    if exists("g:slimux_select_from_current_window") && g:slimux_select_from_current_window == 1
      let l:no_panes_warning .= " in current window (g:slimux_select_from_current_window is enabled)"
    endif
    let l:command .= " || echo '" . l:no_panes_warning . "'"

    " Must use cat here because tmux might fail here due to some libevent bug in linux.
    " Try 'tmux list-panes -a > panes.txt' to see if it is fixed
    let l:command .= ' | cat'

    " Fill buffer with pane list
    execute 'silent read !' . l:command

    " Resize the split to the number of lines in the buffer,
    " limit to 10 lines maximum.
    execute min([ 10, line('$') ]) . 'wincmd _'

    " Move cursor to first item
    normal gg
    call setpos(".", [0, 3, 0, 0])

    " bufhidden=wipe deletes the buffer when it is hidden
    setlocal bufhidden=wipe buftype=nofile
    setlocal nobuflisted nomodifiable noswapfile nowrap
    setlocal cursorline nocursorcolumn nonumber

    " Hide buffer on q, and C-c
    nnoremap <buffer> <silent> q :hide<CR>
    nnoremap <buffer> <silent> <C-c> :hide<CR>

    if !exists("g:slimux_enable_close_with_esc") || g:slimux_enable_close_with_esc != 0
        nnoremap <buffer> <silent> <ESC> :hide<CR>
    endif

    " Use enter key to pick tmux pane
    nnoremap <buffer> <silent> <Enter> :call g:_SlimuxPickPaneFromBuf(g:SlimuxActiveConfigure, 0)<CR>

    nnoremap <buffer> <silent> x :call g:_SlimuxPickPaneFromBuf(g:SlimuxActiveConfigure, 1)<CR>
    nnoremap <buffer> <silent> <Space> :call g:_SlimuxPickPaneFromBuf(g:SlimuxActiveConfigure, 1)<CR>

    " Set key mapping for pane index hitns
    if !exists("g:slimux_pane_hint_map")
      let g:slimux_pane_hint_map = 'd'
    endif
    execute 'nnoremap <buffer> <silent> ' . g:slimux_pane_hint_map . ' :call system("tmux display-panes")<CR>'

endfunction


function! s:Send(tmux_packet)

    " Pane not selected! Save text and open selection dialog
    if len(a:tmux_packet["target_pane"]) == 0
        let s:retry_send = a:tmux_packet
        return s:SelectPane(a:tmux_packet)
    endif

    let target = a:tmux_packet["target_pane"]
    let type = a:tmux_packet["type"]

    if type == "code" || type == "cmd"

      let text = a:tmux_packet["text"]

      if type == "code"
        call s:ExecFileTypeFn("SlimuxPre_", [target])
        let text = s:ExecFileTypeFn("SlimuxEscape_", [text])
      endif


      " The limit of text bytes tmux can send one time. 500 is a safe value.
      let s:sent_text_length_limit = 500

      " If the text is too long, split the text into pieces and send them one by one
      while text != ""
          let local_text = strpart(text, 0, s:sent_text_length_limit)
          let text = strpart(text, s:sent_text_length_limit)
          let local_text = s:EscapeText(local_text)
          call system("tmux set-buffer -- " . local_text)
          call system("tmux paste-buffer -t " . target)
      endwhile

      if type == "code"
        call s:ExecFileTypeFn("SlimuxPost_", [target])
      endif

    elseif type == 'keys'

      let keys = a:tmux_packet["keys"]
      call system("tmux send-keys -t " . target . " " . keys)

    endif

endfunction


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Helpers
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

function! s:EscapeText(text)
  return substitute(shellescape(a:text), "\\\\\\n", "\n", "g")
endfunction

function! s:ExecFileTypeFn(fn_name, args)
  let result = a:args[0]

  if exists("&filetype")
    let fullname = a:fn_name . &filetype
    if exists("*" . fullname)
      let result = call(fullname, a:args)
    end
  end

  return result
endfunction


" Thanks to http://vim.1045645.n5.nabble.com/Is-there-any-way-to-get-visual-selected-text-in-VIM-script-td1171241.html#a1171243
function! s:GetVisual() range
    let reg_save = getreg('"')
    let regtype_save = getregtype('"')
    let cb_save = &clipboard
    set clipboard&

    silent normal! ""gvy
    let selection = getreg('"')

    " restore the selection, this only works if we don't change
    " pane selection buffer
    silent normal! gv
    call setreg('"', reg_save, regtype_save)
    let &clipboard = cb_save
    return selection
endfunction

function! s:GetBuffer()
    let l:winview = winsaveview()
    let reg_save = getreg('"')
    let regtype_save = getregtype('"')
    let cb_save = &clipboard
    set clipboard&

    silent normal! ggVGy
    let selection = getreg('"')

    call setreg('"', reg_save, regtype_save)
    let &clipboard = cb_save
    call winrestview(l:winview)
    return selection
endfunction

function! s:GetParagraph()
    let reg_save = getreg('"')
    let regtype_save = getregtype('"')
    let cb_save = &clipboard
    set clipboard&
    let l:l = line(".")
    let l:c = col(".")

    " Do the business:
    silent normal ""yip
    let selection = getreg('"')

    call cursor(l:l, l:c)
    call setreg('"', reg_save, regtype_save)
    let &clipboard = cb_save
    return selection
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Code interface
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" Code interface uses per buffer configuration

function! SlimuxConfigureCode(...)
  if !exists("b:code_packet")
    let b:code_packet = { "target_pane": "", "type": "code" }
  endif
  if a:0 >= 1
      call s:SelectPane(b:code_packet, a:1)
  else
      call s:SelectPane(b:code_packet)
  endif
endfunction

function! SlimuxSendCode(text)
  if !exists("b:code_packet")
    let b:code_packet = { "target_pane": "", "type": "code" }
  endif
  let b:code_packet["text"] = a:text
  call s:Send(b:code_packet)
endfunction

function! s:SlimeSendRange()  range abort
    if !exists("b:code_packet")
        let b:code_packet = { "target_pane": "", "type": "code" }
    endif
    let rv = getreg('"')
    let rt = getregtype('"')
    sil exe a:firstline . ',' . a:lastline . 'yank'
    call SlimuxSendCode(@")
    call setreg('"',rv, rt)
endfunction

command! SlimuxREPLSendLine call SlimuxSendCode(getline(".") . "\n")
command! SlimuxREPLSendParagraph call SlimuxSendCode(s:GetParagraph())
command! -range=% -bar -nargs=* SlimuxREPLSendSelection call SlimuxSendCode(s:GetVisual())
command! -range -bar -nargs=0 SlimuxREPLSendLine <line1>,<line2>call s:SlimeSendRange()
command! -range=% -bar -nargs=* SlimuxREPLSendBuffer call SlimuxSendCode(s:GetBuffer())
command! -nargs=? -complete=customlist,SlimuxGetPaneList SlimuxREPLConfigure call SlimuxConfigureCode(<q-args>)

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Shell interface
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" Command interface has only one global configuration

let s:cmd_packet = { "target_pane": "", "type": "cmd" }
let s:previous_cmd = ""

function! SlimuxSendCommand(cmd)

  let s:previous_cmd = a:cmd
  let s:cmd_packet["text"] = a:cmd . "\n"
  call s:Send(s:cmd_packet)

endfunction

command! -nargs=1 -complete=shellcmd SlimuxShellRun call SlimuxSendCommand("<args>")
command! SlimuxShellPrompt    call SlimuxSendCommand(input("CMD>", s:previous_cmd))
command! SlimuxShellLast      call SlimuxSendCommand(s:previous_cmd != "" ? s:previous_cmd : input("CMD>", s:previous_cmd))
command! -nargs=? -complete=customlist,SlimuxGetPaneList SlimuxShellConfigure call s:SelectPane(s:cmd_packet, <q-args>)

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Keys interface
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" Send raw keys using the tmux 'send-keys' syntax.
" Works like the shell interface regarding configuration.
" Here's an example the stops the currently running server(ctrl+c) and starts it again:
" :SlimuxSendKeysPrompt
" KEYS>C-C 'make run-server' Enter)

let s:keys_packet = { "target_pane": "", "type": "keys" }
let s:previous_keys = ""

function! SlimuxSendKeys(keys)

  let s:previous_keys = a:keys
  let s:keys_packet["keys"] = a:keys
  call s:Send(s:keys_packet)

endfunction

command! -nargs=1 SlimuxSendKeys call SlimuxSendKeys("<args>")
command! SlimuxSendKeysPrompt    call SlimuxSendKeys(input('KEYS>', s:previous_keys))
command! SlimuxSendKeysLast      call SlimuxSendKeys(s:previous_keys != "" ? s:previous_keys : input('KEYS>'))
command! -nargs=? -complete=customlist,SlimuxGetPaneList SlimuxSendKeysConfigure call s:SelectPane(s:keys_packet, <q-args>)


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Global interface (i.e. for repl, shell, and keys )
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let s:global_conf = { "target_pane": "", "type": "global" }

command! -nargs=? -complete=customlist,SlimuxGetPaneList SlimuxGlobalConfigure call s:SelectPane(s:global_conf, <q-args>)
