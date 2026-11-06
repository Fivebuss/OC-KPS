# Kinda-Posix system
## I got no clue what else to call it. It's like if you try remembering unix off the top of your head

### WIP! This is very early in development. It has a semi-functional kernel and barely a userspace
### Polaris kernel features:
* A scheduler and process setup, for real (No, I did not do the '''preemptive''' load() trick, too jank even for me)
* A meh Console/tty/terminal emulator stack. Multiple-gpus and overral it may even be decent
* A ''better'' i/o system, it combines pipes into it and concurrent stuff, some optimizations. Potentially buggy? Yet to find out in long run
* garbage config and logging system
* Using event handlers its (usually?) possible to kill a genuine looping process
* RC style services
* Easy IPC and signal system. You can handle some of them if you want
* Extremely fast boot (<2 seconds for one gpu*)
* A real sleep that is not the busy-wait polling nonsense like openOS does. It just suspends a coroutine and tell's scheduler to wake it up
* devfs + procfs are different than openOS (and actually exist for the latter)
* Alot of ram use. Seriously, alot. ~470k for one GPU lmao

### Userspace
* ksh + utilities: A pretty "okay" shell, and a few coreutils. Still lacking though
* ksh features:
* Supports brace formatting, env variable syntax (for real), all stream redirection types, exit codes, subshells, shell scripting (Unfinished), most builtins
  * And a readline with the expected history/navigation but also the bash shortcuts (CTRL A/E, home, end, etc)
  * CTRL D is real. Yes, it functions like bash. I hope. Most arduous part of this project believe it or not...
* Coreutils:
  * Most i/o tools (cat, tee, head, wc, tail, even printf*)
  * a lua shell somewhat similiar to openOS's
  * Basic FS tools (du, df, stat, rm, mv, cp, dd, etc)
  * process tools (ps, pstree, kill, env)
  * environment stuff (set, unset, alias, env, etc)
  * Some specific system things, like memhog and gc (Abuses OpenOS trick to get more ram), you can ignore these
  * mount tools including easy bind mounting
  * user tools (addusr, users)
  * An extremely basic text editor derived from ULOS 2's ``edit`` but with my own stuff added
  * a tar archiver and unarchiver. It's pretty neat, thanks mpmxyz
  * other misc things that aren't worth mentioning

#### Libraries
* event: openOS style but with changes, specifically they arrive now upon a scheduler tick
* keyboard: merged openOS's keycodes and stuff into one. Seriously, no need to split
* text: added shell syntax and other stuff to it, made a bit more performant
* filesystem: does a few little things different but mostly same as openOS
* component: 1:1 to openOS minus the GPU/kb handling
* users: For multi-user things, login notably uses it
* termio: Terminal i/o reading, may be helpful for text editors (kedit uses it)
* serialization: nearly 1:1 port of openOS's though with a few bugs fixed

# Better readme coming soon(tm)

## System requirements
Built for Tier2 and above. Seriously, it crashes with less memory often, and a tier 1 GPUI didnt even bother to support\
Unavoidable as I love feature creep and this adds ALOT over openOS

## Installation
no installer even exists yet. Your problem to manage for now (Installer in progress)\
If you really care, clone this repo and remove .git definitely and /usr and /etc/network, etc/services/knet.d if you dont care about networking

## Roadmap
Mostly just finishing aformentioned gaps but here:
* more coreutils (dd for one)
* PTS/PTY
* Installer + Release system
* tar package system for optional things, notably networking and multi-gpu as the mgpu driver (only one right now) is very slow due to OC component call times
* Ksh jobs and backgrounding, just need to do the shell-side of it
* Optimization. Zero done yet really except boot times and major ram savings

## Lets talk security
* It does not exist. Sure every process get's their own _ENV inherited from their parent. Sure multi-user exists but:
  * No passwords, it just exists for a seperated /home and for IPC reasons
  * Debug library I didnt bother touching nor any other exploits
  * I wont stop you from just killing PID 1 (kernel) if you want
  * Why? It's lua. That simple. Too limited without faking it. And security is a larger problem than the entire OS and nearly as aweful as awk would be to add

## Regarding /usr and /etc/services/knet.d:
knet is a update and port of osinetwork. It's WIP and still yet to split from the main OS

## Lets talk about kernel module and boot script compilation
Using my fork of DumbLuaParser I parse, minify, escape and shove boot scripts and kernel modules into "bundled" files. This removes ALOT of i/o cost and even ram use funnily enough. \
However, compilation needs 2xtier3.5 memory for kernel and 2.5(?) for boot scripts. Lua ASTs are extremely memory intensive even with my DLP changes

However, for release versions once those exist, I will ship compiled versions by default. but due to debugging problems, I may ship both source and compiled, but that's a problem for later

## The elephant in the room: AI
Full disclosure, I used it, especially for testing and for string patterns, and other nightmares\
I have a soul and not unlimited time

#### Why I am doing this
No real reason, basically because I can to be honest.\
I wanted a multi-gpu project and my own shell originally on mineOS. Well that was hell to do so I moved to my own OS thing

``See LICENSE and LICENSEINFO.md``