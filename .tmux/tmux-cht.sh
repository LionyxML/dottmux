#!/usr/bin/env bash
selected=$(cat ~/.tmux/tmux-cht-languages-list ~/.tmux/tmux-cht-command-list | fzf --tmux center --border --color=border:blue --prompt='  Searching cheat-sheet: ')
if [[ -z $selected ]]; then
    exit 0
fi

read -p "Enter Query: " query

if grep -qs "$selected" ~/.tmux/tmux-cht-languages-list; then
    query=`echo $query | tr ' ' '+'`
    # tmux neww bash -c "echo \"curl cht.sh/$selected/$query/\" & curl cht.sh/$selected/$query & while [ : ]; do sleep 1; done"
    tmux neww bash -c "echo \"curl cht.sh/$selected/$query/\" & curl -s cht.sh/$selected/$query | less -R"
else
    tmux neww bash -c "curl -s cht.sh/$selected~$query | less -R"
fi
