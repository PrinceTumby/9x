# 9x

Operating system heavily inspired by ideas from Plan 9 and Minix.

## Build Dependencies

These may change over time, but the current required dependencies to build a complete bootable ISO
are:

- [`just`](https://github.com/casey/just), used as the main build script.
- [Rust](https://rust-lang.org) nightly (see `rust-toolchain.toml` for the current version).
- [Zig](https://ziglang.org) 0.15.1 ([anyzig](https://github.com/marler8997/anyzig) is recommended).
- `xorriso` (in WSL2, if building on Windows).

Additional dependencies:

- The [Limine bootloader](https://codeberg.org/Limine/Limine) binary tool, if building for the
  Limine bootloader (currently the only bootloader option).
