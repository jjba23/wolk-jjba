# bashrc.sh - Bash configurations

# Copyright © Josep Bigorra <jjbigorra@gmail.com>

# Author: Josep Bigorra <jjbigorra@gmail.com>
# Maintainer: Josep Bigorra <jjbigorra@gmail.com>
# URL: https://codeberg.org/jjba23/wolk-jjba

# wolk-jjba is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# wolk-jjba is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with wolk-jjba.  If not, see <https://www.gnu.org/licenses/>.

# Commentary:

# TODO

# Code:

pur='\[\033[01;35m\]' # Purple
clr='\[\033[00m\]'    # Reset

# set size and add date and time to `history` command
export HISTTIMEFORMAT="%F %T  | "
export HISTSIZE=200000
export HISTCONTROL=ignoreboth:erasedups
export HISTFILESIZE=200000
export TERM=xterm-256color

# set history to append
shopt -s histappend

# Move to the parent folder.
alias ..='cd ..;pwd'

# Move up two parent folders.
alias ...='cd ../..;pwd'

# Move up three parent folders.
alias ....='cd ../../..;pwd'

# Press c to clear the terminal screen.
alias c='clear'

# Press h to view the bash history.
alias h='history'

# Display the directory structure better.
alias tree='tree --dirsfirst -F'

# Make a directory and all parent directories with verbosity.
alias mkdir='mkdir -p -v'

sys_config_dir="/etc/byggsteg/job-clone/wolk-jjba/trunk"

alias ll="ls -lAh --group-directories-first"
alias l="ls -lAh --group-directories-first"

function fr() {
  cd "${sys_config_dir}" && make fr
}

function sr() {
  cd "${sys_config_dir}" && make sr
}

function jr() {
  cd "${sys_config_dir}" && make jr
}

function ht() {
  sudo herd trigger "${1}"
  sudo tail -f /var/log/messages
}

function hr() {
  sudo herd restart "${1}"
  sudo tail -f /var/log/messages
}

function find_largest_files() {
  du -h -x -s -- * | sort -r -h | head -20
}

# Grep (search) through your history for previous run commands:

function hg() {
  history | grep "$1"
}

eval "$(fzf --bash)"

# Load Nix profile
source /run/current-system/profile/etc/profile.d/nix.sh

# Set the prompt.
export PS1=${pur}"\\s\\v\\u@\\h \\w${GUIX_ENVIRONMENT:+ [env]} ω${clr}"
