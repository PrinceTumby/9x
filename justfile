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

_bootx64_path := join("kernel", "boot", "efi", "out", "bootx64.efi")

_x64_target := "x86_64-freestanding-gnu"

@_default:
    just --list

_kernel_bin := join("kernel", "out", "kernel")
_isoroot := join("out", "isoroot")

# Builds an x86_64 9x iso using the EFI loader
@build-x86_64-efi: (_compile-kernel _x64_target) _clean-output (_build-initrd _x64_target)
    echo - Building ISO...
    {{wsl}} mformat -i out/efi.img -C -f 1440 "::"
    {{wsl}} mmd -i out/efi.img "::/EFI"
    {{wsl}} mmd -i out/efi.img "::/EFI/BOOT"
    {{wsl}} mmd -i out/efi.img "::/boot"
    {{wsl}} mcopy -i out/efi.img kernel/boot/efi/out/bootx64.efi "::/EFI/BOOT"
    {{wsl}} mcopy -i out/efi.img out/initrd.cpio "::/boot"
    {{wsl}} mcopy -i out/efi.img misc/startup_efi.nsh "::/startup.nsh"
    {{mkdir_create_parents}} {{join("out", "efi", "EFI", "BOOT")}}
    mkdir {{join("out", "efi", "boot")}}
    {{copy}} {{_bootx64_path}} {{join("out", "efi", "EFI", "BOOT")}}
    {{copy}} {{join("out", "initrd.cpio")}} {{join("out", "efi", "boot")}}
    mkdir {{_isoroot}}
    {{copy}} {{_kernel_bin}} {{join(_isoroot, "dummy")}}
    {{copy}} {{join("out", "efi.img")}} {{_isoroot}}
    {{wsl}} xorriso -outdev 9x.iso -blank as_needed \
        -map out/isoroot / \
        -volid "9X" \
        -boot_image any partition_table=on \
        -boot_image any efi_path="efi.img" \
        -boot_image any efi_boot_part="--efi-boot-image"
    echo Done!

# Builds an x86_64 9x iso using the Limine bootloader
@build-x86_64-limine: (_compile-kernel "x86_64") _clean-output (_build-initrd _x64_target)
    echo - Building ISO...
    {{mkdir_create_parents}} {{join(_isoroot, "boot", "limine")}}
    {{copy}} {{join("misc", "limine.cfg")}} {{join(_isoroot, "boot")}}
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

# Builds and x86_64 9x PXE boot environment using the Limine bootloader
@build-x86_64-limine-pxe:
    {{error("unimplemented")}}

# Builds an ARM kernel image for the Raspberry Pi
@build-arm-rpi:
    {{error("unimplemented")}}

# Helper recipes

test_program_dir := join("out", "initrd", "bin", "sys")

@_compile-kernel arch=(arch()):
    echo - Compiling kernel...
    just _zig-build kernel -Dcpu-arch={{arch}} -Drelease-safe=true
    {{wsl}} objcopy --only-keep-debug kernel/out/kernel_unstripped dev/kernel.sym
    {{ if os == "windows" { "extract_bochssyms" } else { "./extract_bochssyms.sh" } }}

@_build-initrd arch=(arch() + "-freestanding-gnu"):
    echo - Copying base initrd template files...
    {{copydir}} {{join("initrd", "template")}} {{join("out", "initrd")}}
    echo - Compiling test programs...
    just _zig-build {{join("initrd", "test_program")}} -Dtarget={{arch}} -Drelease-safe=true
    just _zig-build {{join("initrd", "test_zig_program")}} -Dtarget={{arch}} -Drelease-safe=true
    echo - Building initrd...
    {{copy}} {{join("initrd", "test_program", "out", "test_program")}} {{test_program_dir}}
    {{copy}} {{join("initrd", "test_zig_program", "out", "test_zig_program")}} {{test_program_dir}}
    just _build-initrd-cpio

# just _build-cpio {{join("out", "initrd")}} {{join("..", "initrd.cpio")}}

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

# Rust compilation

target_start := "--target targets/"
target_end := "-unknown-kernel.json"
_rust_kernel_out_dir := join("kernel_rust", "target", "x86_64-unknown-kernel", "debug")
_rust_kernel_bin := join(_rust_kernel_out_dir, "kernel")
_rust_unstripped_kernel_bin := join(_rust_kernel_out_dir, "kernel_unstripped")

# Builds an x86_64 9x Rust iso (EXPERIMENTAL) using the Limine bootloader
@build-x86_64-limine-rust: (_compile-rust-kernel "x86_64") _clean-output (_build-initrd _x64_target)
    echo - Building ISO...
    {{mkdir_create_parents}} {{join(_isoroot, "boot", "limine")}}
    {{copy}} {{join("misc", "limine.cfg")}} {{join(_isoroot, "boot")}}
    {{copy}} {{join("misc", "limine", "limine-bios.sys")}} {{join(_isoroot, "boot")}}
    {{copy}} {{join("misc", "limine", "limine-bios-cd.bin")}} {{join(_isoroot, "boot", "limine")}}
    {{copy}} {{join("misc", "limine", "limine-uefi-cd.bin")}} {{join(_isoroot, "boot", "limine")}}
    {{copy}} {{_rust_kernel_bin}} {{join(_isoroot, "boot")}}
    {{copy}} {{join("out", "initrd.cpio")}} {{join(_isoroot, "boot")}}
    {{wsl}} xorriso -as mkisofs \
        -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        out/isoroot -o 9x.iso
    limine bios-install 9x.iso
    echo Done!

@_compile-rust-kernel arch:
    echo - Compiling kernel...
    cd kernel_rust && cargo build {{target_start + arch + target_end}}
    cd {{_rust_kernel_out_dir}} && ld.lld \
        --whole-archive libkernel.a \
        -T../../../targets/x86_64-unknown-kernel.ld \
        --gc-sections \
        -o kernel_unstripped
    cd {{_rust_kernel_out_dir}} && llvm-objcopy --strip-debug kernel_unstripped kernel
    llvm-objcopy --only-keep-debug {{_rust_unstripped_kernel_bin}} dev/kernel.sym
    {{ if os == "windows" { "extract_bochssyms" } else { "./extract_bochssyms.sh" } }}
