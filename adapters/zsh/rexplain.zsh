# Source after enabling zsh vi mode. Binds Ctrl-E in the visual keymap.
_rexplain_explain_selection() {
  emulate -L zsh
  local saved_buffer="$BUFFER" saved_cursor=$CURSOR
  local lo=$(( MARK < CURSOR ? MARK : CURSOR ))
  local hi=$(( MARK > CURSOR ? MARK : CURSOR ))
  local selected="${BUFFER[$((lo + 1)),$hi]}"
  if [[ -z "${selected//[[:space:]]/}" ]]; then
    zle -M 'Rexplain: no active selection'
    return 0
  fi
  zle -I
  print -r -- "$selected" | rexplain explain --stdin --detail "${REXPLAIN_DETAIL:-compact}" --styled
  print -P '%F{8}Press a key to return to the command line.%f'
  read -sk1
  BUFFER="$saved_buffer" CURSOR=$saved_cursor
  zle redisplay
}
zle -N rexplain-explain-selection _rexplain_explain_selection
bindkey -M visual '^E' rexplain-explain-selection
