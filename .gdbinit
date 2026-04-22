# ~/.gdbinit - U-Boot auto-relocation helper
#
# On every stop event the Python handler checks whether U-Boot symbols are
# loaded and, if gd->relocaddr is set and differs from the link-time .text
# base, discards the old symbol table and reloads it at the relocation
# address automatically.
#
# Commands added:
#   uboot-reloc [ADDRESS]  - force relocation (reads gd->relocaddr if omitted)
#   uboot-reset            - clear relocated flag after a target reset
#   uboot-info             - show current helper state

python

import gdb
import os

# Architecture -> register that holds struct global_data *
# (sandbox, x86, and Xtensa keep gd in a symbol, not a register - not listed)
_GD_REGS = {
    'arc':        'r25',
    'arm':        'r9',
    'aarch64':    'x18',
    'arm64':      'x18',
    'm68k':       'd7',
    'microblaze': 'r31',
    'mips':       'k0',
    'nios2':      'gp',
    'powerpc':    'r2',
    'riscv':      'gp',
    'sh':         'r13',
}

# A handful of symbols that only exist in a U-Boot image
_UBOOT_PROBE_SYMS = (
    'board_init_f',
    'board_init_r',
    'relocate_code',
    '__u_boot_list',
    'gd',
)

_UBOOT_BINARIES_NAMES = (
    'u-boot',
    'u-boot.elf'
    'uboot',
    'uboot.elf',
)


_state = {'relocated': False}


def _is_uboot_loaded():
    for name in _UBOOT_PROBE_SYMS:
        try:
            if gdb.lookup_global_symbol(name) is not None:
                return True
        except gdb.error:
            pass
    for obj in gdb.objfiles():
        if os.path.basename(obj.filename) in _UBOOT_BINARIES_NAMES:
            return True
    return False


def _gd_register():
    try:
        arch = gdb.selected_frame().architecture().name().lower()
    except gdb.error:
        return None
    for prefix, reg in _GD_REGS.items():
        if arch.startswith(prefix):
            return reg
    return None


def _read_relocaddr():
    reg = _gd_register()
    if reg is None:
        return None
    try:
        val = gdb.parse_and_eval(
            '((struct global_data *)$%s)->relocaddr' % reg)
        addr = int(val)
        return addr if addr != 0 else None
    except gdb.error:
        return None


def _uboot_objfile_path():
    for obj in gdb.objfiles():
        base = os.path.basename(obj.filename)
        if base in _UBOOT_BINARIES_NAMES:
            return obj.filename
    return None


def _link_text_addr():
    """Compile-time .text base - the address _start was linked at."""
    try:
        sym = gdb.lookup_global_symbol('_start')
        if sym is not None:
            return int(gdb.parse_and_eval('(unsigned long)&_start'))
    except gdb.error:
        pass
    return None


def _set_confirm(state):
    gdb.execute('set confirm %s' % ('on' if state else 'off'))


def do_reloc(relocaddr=None, filename=None):
    if relocaddr is None:
        relocaddr = _read_relocaddr()
    if relocaddr is None:
        gdb.write('u-boot-gdb: cannot determine relocaddr\n', gdb.STDERR)
        return False

    if filename is None:
        filename = _uboot_objfile_path()
    if filename is None:
        gdb.write('u-boot-gdb: cannot find u-boot objfile\n', gdb.STDERR)
        return False

    gdb.write('u-boot-gdb: reloading "%s" at 0x%x\n' % (filename, relocaddr))
    saved_confirm = gdb.parameter('confirm')
    _set_confirm(False)
    try:
        gdb.execute('symbol-file', to_string=True)
        gdb.execute('add-symbol-file %s 0x%x' % (filename, relocaddr))
        _state['relocated'] = True
        gdb.write('u-boot-gdb: symbols relocated to 0x%x\n' % relocaddr)
        return True
    except gdb.error as exc:
        gdb.write('u-boot-gdb: relocation failed: %s\n' % exc, gdb.STDERR)
        return False
    finally:
        _set_confirm(saved_confirm)


def _on_stop(event):
    if _state['relocated']:
        return
    if not _is_uboot_loaded():
        return

    relocaddr = _read_relocaddr()
    if relocaddr is None:
        return

    # Skip if U-Boot hasn't moved yet (relocaddr == compile-time .text base)
    link_addr = _link_text_addr()
    if link_addr is not None and relocaddr == link_addr:
        return

    do_reloc(relocaddr)


gdb.events.stop.connect(_on_stop)


class UBootRelocCommand(gdb.Command):
    """Force U-Boot symbol relocation.
    Usage: uboot-reloc [ADDRESS]
    ADDRESS defaults to gd->relocaddr when omitted."""

    def __init__(self):
        super().__init__('uboot-reloc', gdb.COMMAND_FILES)

    def invoke(self, arg, from_tty):
        addr = None
        arg = arg.strip()
        if arg:
            try:
                addr = int(gdb.parse_and_eval(arg))
            except gdb.error as exc:
                gdb.write('u-boot-gdb: bad address - %s\n' % exc, gdb.STDERR)
                return
        do_reloc(relocaddr=addr)


class UBootResetCommand(gdb.Command):
    """Clear the U-Boot relocation state (use after a target reset).
    Usage: uboot-reset"""

    def __init__(self):
        super().__init__('uboot-reset', gdb.COMMAND_FILES)

    def invoke(self, arg, from_tty):
        _state['relocated'] = False
        gdb.write('u-boot-gdb: relocation state cleared\n')


class UBootInfoCommand(gdb.Command):
    """Show U-Boot GDB helper status.
    Usage: uboot-info"""

    def __init__(self):
        super().__init__('uboot-info', gdb.COMMAND_FILES)

    def invoke(self, arg, from_tty):
        gdb.write('u-boot loaded : %s\n' % _is_uboot_loaded())
        gdb.write('relocated     : %s\n' % _state['relocated'])
        reg = _gd_register()
        gdb.write('gd register   : %s\n' % (reg or '(arch not in list)'))
        if reg is not None:
            addr = _read_relocaddr()
            gdb.write('relocaddr     : %s\n' % (
                '0x%x' % addr if addr else '(zero / not yet set)'))
        link = _link_text_addr()
        gdb.write('link .text    : %s\n' % (
            '0x%x' % link if link else '(unknown)'))
        obj = _uboot_objfile_path()
        gdb.write('objfile       : %s\n' % (obj or '(none found)'))


UBootRelocCommand()
UBootResetCommand()
UBootInfoCommand()

gdb.write('u-boot-gdb helper active  '
          '(uboot-reloc / uboot-reset / uboot-info)\n')

end
