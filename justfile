set shell := ["bash", "-uc"]
set windows-shell := ["cmd.exe", "/c"]

os := os()
os_family := os_family()

# Command replacements
wsl := if os_family == "windows" { "wsl" } else { "" }
rm := if os_family == "windows" { "del" } else { "rm" }
rmdir := if os_family == "windows" { "rmdir /s /q" } else { "rm -r" }
copy := if os_family == "windows" { "1>NUL copy" } else { "cp" }
copydir := if os_family == "windows" { "1>NUL xcopy /c /q /e /i" } else { "cp -r" }
mkdir_create_parents := if os_family == "windows" { "mkdir" } else { "mkdir -p" }
silence_stderr := if os_family == "windows" { "2>NUL" } else { "2>/dev/null" }

@_default:
    just --list

_isoroot := join("out", "isoroot")
_kernel_out_dir := join("kernel", "target", "x86_64-unknown-kernel", "debug")
_kernel_bin := join(_kernel_out_dir, "kernel")
_unstripped_kernel_bin := join(_kernel_out_dir, "kernel_unstripped")

# Builds an x86_64 9x iso using the Limine bootloader
@build-x86_64-limine: (_compile-kernel "x86_64") _clean-output (_build-initrd "x86_64-freestanding-gnu")
    echo - Building ISO...
    {{mkdir_create_parents}} {{join(_isoroot, "boot", "limine")}}
    {{copy}} {{join("misc", "limine.conf")}} {{join(_isoroot, "boot")}}
    {{copy}} {{join("misc", "limine", "limine-bios.sys")}} {{join(_isoroot, "boot")}}
    {{copy}} {{join("misc", "limine", "limine-bios-cd.bin")}} {{join(_isoroot, "boot", "limine")}}
    {{copy}} {{join("misc", "limine", "limine-uefi-cd.bin")}} {{join(_isoroot, "boot", "limine")}}
    {{copy}} {{_kernel_bin}} {{join(_isoroot, "boot")}}
    {{copy}} {{join("out", "initrd.cpio")}} {{join(_isoroot, "boot")}}
    {{wsl}} xorriso -as mkisofs \
        -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        out/isoroot -o 9x.iso
    limine bios-install 9x.iso
    echo Done!

@_compile-kernel arch:
    echo - Compiling kernel...
    cd kernel && cargo +nightly-2025-09-26 build \
        --target {{"targets/" + arch + "-unknown-kernel.json"}} \
        -Zbuild-std=core,compiler_builtins,alloc \
        -Zbuild-std-features=compiler-builtins-mem
    cd {{_kernel_out_dir}} && ld.lld \
        --whole-archive libkernel.a \
        -T../../../targets/x86_64-unknown-kernel.ld \
        --gc-sections \
        -o kernel_unstripped
    cd {{_kernel_out_dir}} && llvm-objcopy --strip-debug kernel_unstripped kernel
    llvm-objcopy --only-keep-debug {{_unstripped_kernel_bin}} dev/kernel.sym
    {{ if os == "windows" { "extract_bochssyms" } else { "./extract_bochssyms.sh" } }}

# Helper recipes

test_program_dir := join("out", "initrd", "bin", "sys")

@_build-initrd arch:
    echo - Copying base initrd template files...
    {{copydir}} {{join("initrd", "template")}} {{join("out", "initrd")}}
    echo - Compiling test programs...
    just _zig-build {{join("initrd", "test_program")}} -Dtarget={{arch}} -Drelease-safe=true
    just _zig-build {{join("initrd", "test_zig_program")}} -Dtarget={{arch}} -Drelease-safe=true
    echo - Building initrd...
    {{copy}} {{join("initrd", "test_program", "out", "test_program")}} {{test_program_dir}}
    {{copy}} {{join("initrd", "test_zig_program", "out", "test_zig_program")}} {{test_program_dir}}
    just _build-initrd-cpio

[windows]
@_build-initrd-cpio:
    cd out\initrd && tar -c --format cpio -f ..\initrd.cpio *

[unix]
@_build-initrd-cpio:
    cd out/initrd && find * -depth -print | cpio --format=odc -o >../initrd.cpio

@_clean-output:
    {{rm}} 9x.iso {{silence_stderr}} || true
    {{rm}} 9x.img {{silence_stderr}} || true
    {{rmdir}} out {{silence_stderr}} || true
    mkdir out

@_zig-build dir *args:
    cd {{dir}} && zig 0.7.1 build {{args}}
