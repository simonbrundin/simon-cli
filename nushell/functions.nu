#!/usr/bin/env nu

export def fzfSelect [list: list] {
  let selection = ($list | str join "\n" | fzf --multi | lines)
  if ($selection | length) == 1 {
    return ($selection | first)
  } else {
    return $selection
  }
}
