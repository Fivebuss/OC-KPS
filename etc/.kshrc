# Sets up some stuff
export SHELL=/bin/ksh.lua
export TERM=polaris-truecolor
export VERSION=0.4
export EDITOR='kedit'
alias id='whoami -i'
alias stty='sterm'
alias edit=$EDITOR
alias login='echo "Login within a shell is hilariously broken. Dont use it. (This is aliased)"'
lua /etc/motd.lua
cd /home/$USER
source /home/$USER/.kshrc