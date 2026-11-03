# Sets up some stuff
export SHELL=/bin/ksh.lua
export TERM=polaris-truecolor
export VERSION=0.4
alias id='whoami -i'
alias stty='sterm'
lua /etc/motd.lua
cd /home/$USER