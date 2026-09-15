# Kinda-Posix system
## Name wip Idk what to call it

### So far it has a semi-functional kernel and an extremely basic shell
### Polaris kernel features:
* Scheduler and process setup, for real
* Using event handlers its (usually?) possible to kill a genuine looping process
* Event libray merges mineOS's skipping and other stuff with openOS's
* Pretty light even without optimization! yay
#### Contains following modules:
* buffer: openOS's but with a few extras
* io: same as above but with pipe/process support done better and included
* component: genuinely openOS's component lol, in the future will do multiscreen
* config: a really horrible solution and will be replaced soon
* env: processes have their own _ENV and env variable system
* event: see above
* io: see above
* log: ring-buffer log thing
* process: groups, children and inheritance stuff plus _ENV management
* scheduler: kill and term, sleep, signals, waiting for input from another, etc
* syscall: Runs kernel functions inside the kernel RPC style
* tty: cynosure's TTY library with a proper cursor system and ported over

### Userspace
* ksh + utilities: Porting over mshell right now to this, so far its kinda worthless
#### Libraries
* keyboard: merged openOS's keycodes and stuff into one. Seriously, no need to split
* text: added shell syntax and other stuff
* transforms: practically identical port
* filesystem: does a few little things different but mostly same as openOS

### Pre-kernel
* Sets up package management like openOS but a bit different (remember _ENV?)
* Initializes gpu, will replace driver for multiscreen later (maybe)
* configures kernel
* uses standard OC lua eeprom, and boots and sets up kernel
* Loops inside boot.lua without assuming i/o exists weirdly
* Has an initconsole, I use for testing

#### Why I am doing this
Because I can