# Kinda-Posix system
## I got no clue what else to call it. It's like if you try remembering unix off the top of your head

### WIP! This is very early in development. It has a semi-functional kernel and barely a userspace
### Polaris kernel features:
* Scheduler and process setup, for real (No, I did not do the '''preemptive''' load() trick, too jank even for me)
* A better i/o system which somehow lacks io.open still lmao
* garbage config and logging system
* Using event handlers its (usually?) possible to kill a genuine looping process
* RC style services
* Easy IPC
* Extremely fast boot
* A real sleep that is not the busy-wait polling nonsense like openOS does. It just suspends a coroutine and tell's scheduler to wake it up
* Alot of ram use

### Userspace
* ksh + utilities: A pretty "okay" shell, and a few coreutils. Still lacking though
* ksh features:
* * Supports brace formatting, env variable syntax (for real), all stream redirection types, exit codes, subshells, shell scripting (Unfinished)
* * And a readline with the expected history/navigation but also the bash shortcuts (CTRL A/E, home, end, etc)
* * CTRL D is real. Yes, it functions like bash. I hope. Most arduous part of this project believe it or not...
* Coreutils:
* * Most i/o tools (cat, tee, head, tail, even printf*)
* * a lua shell from openOS
* * Navigation tools for filesystem, except du and stat as those were horrificly broken and due a rewrite. Yes, stat is missing hilariously enough
* * process tools (ps, pstree, kill, env)
* * environment stuff (set, unset, alias, env, etc)
* * Some specific system things, like memhog and gc (Abuses OpenOS trick to get more ram), you can ignore these
* * mount tools including easy bind mounting
* * user tools (addusr, users)
* * other misc things that aren't worth really except a tar archiver and unarchiver. It's pretty neat, thanks mpmxyz

#### Libraries
* keyboard: merged openOS's keycodes and stuff into one. Seriously, no need to split
* text: added shell syntax and other stuff
* transforms: practically identical port
* filesystem: does a few little things different but mostly same as openOS
* users: For multi-user things
* termio: Terminal i/o reading, you generally shouldnt need to use this

# Better readme coming soon(tm)

## System requirements
Built for Tier2 and above. Seriously, it crashes with less memory often, and a tier 1 GPU isnt even bothered to support\
Unavoidable as I love feature creep and this adds ALOT over openOS

## Installation
no installer even exists and networking is still goofy, and forcibly included. Your problem to manage for now (Installer in progress)

## Roadmap
All of the above but so far:
* Installer from openOS
* tar package system for optional things, notably networking and multi-gpu as the mgpu driver (only one right now) is very slow due to OC component call times
* Ksh jobs and backgrounding, just need to do the shell-side of it
* Optimization. Zero done yet really except boot times

## Lets talk security
* It does not exist. Sure every process get's their own _ENV inherited from their parent. Sure multi-user exists but:
* * No passwords, it just exists for a seperated /home and for IPC reasons
* * Debug library I didnt bother touching nor any other exploits
* * I wont stop you from just killing PID 1 (kernel) if you want
* * Why? It's lua. That simple. Too limited without faking it. And security is a larger problem than the entire OS and nearly as aweful as awk would be to add

## Regarding /usr and /etc/services/knet.d:
knet is a update and port of osinetwork. It's WIP and still yet to split from the main OS

## The elephant in the room: AI
Full disclosure, I used it, especially for testing and for string patterns, and other nightmares\
I have a soul and not unlimited time

#### Why I am doing this
No real reason, basically because I can to be honest.\
If I had to justify it, I would snarkily respond with asking whoever's asking me to try "cat /dev/random | head -c 10" in openOS and realize that head doesn't exist and random cannot be interrupted

``See LICENSE and LICENSEINFO.md``