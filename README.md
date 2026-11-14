# Kinda-Posix system (KPS)
## Like if you tried recreating how unix works with a little bit of amnesia
<sub>Better readme coming soon™</sub>

### WIP! This is very early in development. There is no installer, and the kernel + userspace are quite lacking and unoptimized
### Polaris kernel features:
* A scheduler and process setup, for real (No, I did not do the '''preemptive''' load() trick, too jank even for me)
* A meh Console/tty/terminal emulator stack. Multiple-gpus and decent performance however
* A ''better'' i/o system, it combines pipes into it and concurrent stuff, some optimizations. Potentially buggy? Yet to find out in long run
* ^ By extension, stdio is real. Stop using print()!!!
* garbage config and logging system
* RC style services
* Easy IPC and signal system. And some easy ways to handle signals
* Extremely fast boot (<2 seconds for one gpu*)
* A real sleep that is not the busy-wait polling nonsense like openOS does. It just suspends a coroutine and tell's scheduler to wake it upz
* Each process get's their own _ENV but it's easily manageable
* devfs + procfs are different than openOS (and actually exist for the latter)
* because of how pullSignal works, the actual lua GC runs *every few centuries* by itself
* neat name

### Userspace
* KPS Shell: A pretty "okay" shell, surpassing openOS while being also worse
* ksh features:
* Syntax
  * Most of posix and bash extensions like brace expansion
  * Missing some though. I have too many to list and lack too many to list either
  * tldr; better than openOS by 50 miles, (We dont talk about 20k memory cost for this...)
* General
  * Exit codes
  * An actual shell pipeline that isn't sequential
  * env variables are distinguished between the expected kinds
  * *Most* of special variable support (like $?)
  * Basic shell scripting
  * Multi-user (it wont mystically crash the system, looking at you openOS with globals)
  * Job control. Yup. It exists sorta like sh does. Expect bugs, this is the most untested
  * A majority of builtins
  * CTRL D is real. Yes, it functions like bash. I hope. Most arduous part of this project believe it or not...
* Readline
  * The usual arrow key navigation and command history
  * Works with unicode
  * Supports a few bash shortcuts and keybinds:
    * Home/End
    * CTRL A/E
    * CTRL L
  * Usable all over with little difficulty (It's a pretty portable library)
  * (Half broken) multi-line support
* Coreutils:
  * Most i/o tools (cat, tee, head, wc, tail, even printf*)
  * A lua shell somewhat similiar to openOS's
  * Basic FS tools (du, df, stat, rm, mv, cp, dd, etc)
  * Some process tools (ps, pstree, kill, env)
  * Environment stuff (env, lua, ksh ``<file>`` to run)
  * mount tools including easy bind mounting
  * User tools (addusr, users)
  * Two editors:
    * An extremely basic text editor derived from ULOS 2's ``edit`` but with my own stuff
    * An optional syntax highlighting editor that is extremely slow and I will likely re-do sometime
  * a tar archiver and unarchiver. It's pretty neat, thanks mpmxyz
  * Some system-specific tools
  * Other misc things that aren't worth mentioning
* Alot of ram use. Seriously, alot. ~490k idle for one GPU lmao and boots needing ~512k

#### Main libraries
* event: openOS style but with changes, specifically they arrive now upon a scheduler tick
* keyboard: merged openOS's keycodes and stuff into one. Seriously, no need to split
* text: added shell syntax and other stuff to it, made a bit more performant
* filesystem: does a few little things different but mostly same as openOS
* component: 1:1 to openOS minus the GPU/kb handling
* users: For multi-user things, login notably uses it
* ksh
  * (Only commands ran by ksh get this): console, gives current path and easy path resolving to the real path. You dont have to worry about * and such
  * readline
  * port of Wobbo's getopt but with --long-flag support
  * condraw, a bugfixed version of PixelToast's consoleutils
* termio: Terminal i/o reading, may be helpful for text editors (kedit uses it)
* serialization: nearly 1:1 port of openOS's though with a few bugs fixed
* bit32 backwards compat
* full keyboard library
* My fork of DumbLuaParser (Feel free to remove it)

## System requirements
Built for Tier2 and above. Seriously, it crashes with less memory often, and a tier 1 GPUI didnt even bother to support\
Unavoidable as I love feature creep and this adds ALOT over openOS

## Installation
no installer even exists yet. Your problem to manage for now (Installer in progress)\
If you really care, clone this repo and remove .git definitely\
Some extras are under /usr, if you dont care about them (notably networking) remove it\
You may want to remove the README and other documents at /, they are quite large

## Roadmap
Mostly just finishing aformentioned gaps but here:
* Shell scripting part 2 (Right now it doesnt support stuff like if/fi)
* Installer + Release system
* Some kind of virtual console system, PTS/PTY is too complex to bother with though
* tar package system for optional things, notably networking and multi-gpu as the mgpu driver (only one right now) is very slow due to OC component call times
* bugfix everything I can find
* Optimization. Very little done so for the ram side (490k is outrageous)
* **Actual release** and make documentation

## Lets talk security
* It does not exist.
Sure multi-user exists but:
  * No passwords, it just exists for a seperated /home and for IPC reasons
  * Debug library I didnt bother touching nor any other exploits
  * I wont stop you from just killing PID 1 (kernel) if you want
  * Why? It's lua. That simple. Too limited without faking it. And security is a larger problem than the entire OS and nearly as aweful as awk would be to add

## Regarding /usr
knet is a update and port of osinetwork. It's WIP and still yet to split from the main OS\
sbedit is a pretty aweful syntax highlighting editor based on tedit. I made the mistake\
of using io.write() instead of GPU calls and it's very slow as a result

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