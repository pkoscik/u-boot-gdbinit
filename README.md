# u-boot-gdbinit

GDB helper that automatically relocates the U-Boot symbol table after
`board_init_f` moves the image to the top of RAM.

## What it does

On every stop (breakpoint, step, halt) it checks whether a U-Boot binary is
loaded and reads `gd->relocaddr` from the architecture's global-data register.
If the value is non-zero and differs from the compile-time `.text` address,
it silently discards the old symbol table and reloads it at the relocation
address - equivalent to running this manually:

```
symbol-file
add-symbol-file u-boot 0x27f7a000
```

Detection uses a combination of well-known U-Boot symbols (`board_init_f`,
`relocate_code`, `__u_boot_list`, ...) and objfile names (`u-boot`, `u-boot.elf`, ...).

Supported architectures (register-based `gd`):
- arc
- arm
- aarch64
- m68k
- microblaze
- mips
- nios2
- powerpc
- riscv

Not supported:
- sandbox,
- x86,
- Xtensa

## Install

```sh
cp .gdbinit ~/.gdbinit
# or, if you already have a ~/.gdbinit:
cat .gdbinit >> ~/.gdbinit
```

## Usage

Start a session as usual:

```sh
gdb-multiarch u-boot
(gdb) target extended-remote :3333
```

Relocation happens automatically the first time execution stops after
`gd->relocaddr` is set. No manual steps needed.

### Commands

| Command | Description |
|---|---|
| `uboot-reloc [ADDRESS]` | Force relocation; reads `gd->relocaddr` if address omitted |
| `uboot-reset` | Clear the relocated flag - run this after a target reset |
| `uboot-info` | Show helper state: loaded, relocated, register, relocaddr, objfile |
