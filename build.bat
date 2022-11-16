@echo off
setlocal
if "%1%"=="x86_64-efi" goto x64efi
:: if "%1%"=="x86_64-grub" goto x64grub
if "%1%"=="x86_64-limine" goto x64limine
if "%1%"=="x86_64-limine-pxe" goto x64liminepxe
if "%1%"=="arm-rpi" goto armrpi
:: if "%1%"=="aarch64-rpi3" goto aarch64rpi3
:: if "%1%"=="riscv64-qemu" goto riscv64qemu
echo Usage: build [command]
echo.
echo Commands:
echo.
echo   x86_64-efi           Build an x86_64 9x iso using the EFI loader
:: echo   x86_64-grub          Build an x86_64 9x iso using the GRUB bootloader
echo   x86_64-limine        Build an x86_64 9x iso using the Limine bootloader
echo   x86_64-limine-pxe    Build an x86_64 PXE boot environment using the Limine bootloader
echo   arm-rpi              Build an ARM kernel image for the Raspberry Pi
:: echo   aarch64-rpi3         Build an AArch64 img for the Raspberry Pi 3
:: echo   rv64-qemu            Build an RV64GC 9x iso as QEMU bios
echo.
if "%1%"=="" (
    echo error: expected command argument
) else (
    echo error: unrecognised command argument "%1"
)
exit /b 1

:: EFI bootloader config
:x64efi
echo Building:
:: Kernel building
echo - Compiling kernel...
cd kernel
cmd /k "zig build -Drelease-safe=true -Dbuild-efi-stub=true & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..
wsl objcopy --only-keep-debug kernel/out/kernel_unstripped dev/kernel.sym
:: initrd building
echo - Cleaning output directory...
del 9x.iso 2>NUL
del 9x.img 2>NUL
rmdir /s /q out 2>NUL
mkdir out 2>NUL
echo - Copying base initrd template files...
xcopy /c /q /e /i initrd\template out\initrd 1>NUL
echo - Compiling test programs...
cd initrd\test_program
cmd /k "zig build -Drelease-fast=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\test_zig_program
cmd /k "zig build -Drelease-fast=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\..
echo - Building initrd...
copy initrd\test_program\out\test_program out\initrd\bin\sys 1>NUL
copy initrd\test_zig_program\out\test_zig_program out\initrd\bin\sys 1>NUL
cd out\initrd
tar -c --format cpio -f ..\initrd.cpio *
cd ..
:: ISO root building
echo - Generating ISO root...
mkdir isoroot 2>NUL
echo - Building ISO...
cd ..
wsl mformat -i out/efi.img -C -f 1440 "::"
wsl mmd -i out/efi.img "::/EFI"
wsl mmd -i out/efi.img "::/EFI/BOOT"
wsl mmd -i out/efi.img "::/boot"
wsl mcopy -i out/efi.img kernel/boot/efi/out/bootx64.efi "::/EFI/BOOT"
wsl mcopy -i out/efi.img out/initrd.cpio "::/boot"
wsl mcopy -i out/efi.img misc/startup_efi.nsh "::/startup.nsh"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
mkdir out\efi
mkdir out\efi\EFI
mkdir out\efi\EFI\BOOT
mkdir out\efi\boot
copy kernel\boot\efi\out\bootx64.efi out\efi\EFI\BOOT 1>NUL
copy out\initrd.cpio out\efi\boot 1>NUL
copy out\efi.img out\isoroot 1>NUL
if %errorlevel% NEQ 0 (
    goto :compfailed
)
copy kernel\out\kernel out\isoroot\dummy 1>NUL
wsl xorriso -outdev 9x.iso -blank as_needed ^
    -map out/isoroot / ^
    -volid "9X" ^
    -boot_image any partition_table=on ^
    -boot_image any efi_path="efi.img" ^
    -boot_image any efi_boot_part="--efi-boot-image"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
echo Done!
goto :end

:: GRUB bootloader config
:x64grub
echo Building:
:: Kernel building
echo - Compiling kernel...
cd kernel
cmd /k "zig build -Drelease-safe=true & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..
wsl objcopy --only-keep-debug kernel/out/kernel_unstripped dev/kernel.sym
:: initrd building
echo - Cleaning output directory...
del 9x.iso 2>NUL
del 9x.img 2>NUL
rmdir /s /q out 2>NUL
mkdir out 2>NUL
echo - Copying base initrd template files...
xcopy /c /q /e /i initrd\template out\initrd 1>NUL
echo - Compiling test programs...
cd initrd\test_program
cmd /k "zig build -Drelease-fast=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\test_zig_program
cmd /k "zig build -Drelease-fast=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\..
echo - Building initrd...
copy initrd\test_program\out\test_program out\initrd\bin\sys 1>NUL
copy initrd\test_zig_program\out\test_zig_program out\initrd\bin\sys 1>NUL
cd out\initrd
tar -c --format cpio -f ..\initrd.cpio *
cd ..
:: ISO root building
echo - Generating ISO root...
mkdir isoroot 2>NUL
echo - Building ISO...
mkdir isoroot\boot 2>NUL
mkdir isoroot\boot\grub 2>NUL
copy ..\misc\grub.cfg isoroot\boot\grub 1>NUL
copy ..\misc\startup.nsh isoroot 1>NUL
:: copy ..\kernel\out\kernel isoroot\boot 1>NUL
copy ..\kernel\boot\multiboot2\out\multiboot2_stub isoroot\boot\kernel 1>NUL
copy initrd.cpio isoroot\boot 1>NUL
cd ..
wsl grub-mkrescue -o 9x.iso out/isoroot
if %errorlevel% NEQ 0 (
    goto :compfailed
)
echo Done!
goto :end

:: Limine bootloader config
:x64limine
echo Building:
:: Kernel building
echo - Compiling kernel...
cd kernel
cmd /k "zig build -Drelease-safe=true & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..
wsl objcopy --only-keep-debug kernel/out/kernel_unstripped dev/kernel.sym
readelf -s -W kernel\out\kernel ^
    | wsl sed '1,4d' ^
    | wsl awk '{print $2 " " $8}' ^
    > dev\bochssyms.txt
:: initrd building
echo - Cleaning output directory...
del 9x.iso 2>NUL
del 9x.img 2>NUL
rmdir /s /q out 2>NUL
mkdir out 2>NUL
echo - Copying base initrd template files...
xcopy /c /q /e /i initrd\template out\initrd 1>NUL
echo - Compiling test programs...
cd initrd\test_program
cmd /k "zig build -Drelease-safe=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\test_zig_program
cmd /k "zig build -Drelease-safe=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\..
echo - Building initrd...
copy initrd\test_program\out\test_program out\initrd\bin\sys 1>NUL
copy initrd\test_zig_program\out\test_zig_program out\initrd\bin\sys 1>NUL
cd out\initrd
tar -c --format cpio -f ..\initrd.cpio *
cd ..
:: ISO root building
echo - Generating ISO root...
mkdir isoroot 2>NUL
echo - Building ISO...
mkdir isoroot\boot 2>NUL
mkdir isoroot\boot\limine 2>NUL
copy ..\misc\limine.cfg isoroot\boot 1>NUL
copy ..\misc\limine\limine.sys isoroot\boot 1>NUL
copy ..\misc\limine\limine-cd.bin isoroot\boot\limine 1>NUL
copy ..\misc\limine\limine-cd-efi.bin isoroot\boot\limine 1>NUL
copy ..\kernel\out\kernel isoroot\boot\kernel 1>NUL
copy initrd.cpio isoroot\boot 1>NUL
cd ..
wsl xorriso -as mkisofs ^
    -b boot/limine/limine-cd.bin ^
    -no-emul-boot -boot-load-size 4 -boot-info-table ^
    --efi-boot boot/limine/limine-cd-efi.bin ^
    -efi-boot-part --efi-boot-image --protective-msdos-label ^
    out/isoroot -o 9x.iso
limine-deploy 9x.iso
if %errorlevel% NEQ 0 (
    goto :compfailed
)
echo Done!
goto :end

:: Limine bootloader PXE config
:x64liminepxe
echo Building:
:: Kernel building
echo - Compiling kernel...
cd kernel
cmd /k "zig build -Drelease-safe=true & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..
wsl objcopy --only-keep-debug kernel/out/kernel_unstripped dev/kernel.sym
readelf -s -W kernel\out\kernel ^
    | wsl sed '1,4d' ^
    | wsl awk '{print $2 " " $8}' ^
    > dev\bochssyms.txt
:: initrd building
echo - Cleaning output directory...
del 9x.iso 2>NUL
del 9x.img 2>NUL
rmdir /s /q out 2>NUL
mkdir out 2>NUL
echo - Copying base initrd template files...
xcopy /c /q /e /i initrd\template out\initrd 1>NUL
echo - Compiling test programs...
cd initrd\test_program
cmd /k "zig build -Drelease-safe=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\test_zig_program
cmd /k "zig build -Drelease-safe=true -Dtarget=x86_64-freestanding-gnu & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..\..
echo - Building initrd...
copy initrd\test_program\out\test_program out\initrd\bin\sys 1>NUL
copy initrd\test_zig_program\out\test_zig_program out\initrd\bin\sys 1>NUL
cd out\initrd
tar -c --format cpio -f ..\initrd.cpio *
cd ..
:: PXE root building
echo - Generating PXE root...
mkdir pxeroot 2>NUL
copy ..\misc\limine-pxe.cfg pxeroot\limine.cfg 1>NUL
copy ..\misc\limine\limine.sys pxeroot 1>NUL
copy ..\misc\limine\limine-pxe.bin pxeroot 1>NUL
copy ..\kernel\out\kernel pxeroot 1>NUL
copy initrd.cpio pxeroot 1>NUL
cd ..
echo Done!
goto :end

:: ARM Raspberry Pi config
:armrpi
echo Building:
echo - Cleaning output directory...
del 9x.iso 2>NUL
del 9x.img 2>NUL
rmdir /s /q out 2>NUL
mkdir out 2>NUL
:: Kernel building
echo - Compiling kernel...
cd kernel
cmd /k "zig build -Drelease-safe=true -Dcpu-arch=arm -Dmachine-type=raspberry_pi & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..
llvm-objcopy --only-keep-debug kernel\out\kernel_unstripped dev\kernel.sym
llvm-objcopy kernel\out\kernel -O binary out\kernel.img
llvm-objcopy kernel\out\kernel -O ihex out\kernel.hex
:: Image root building
echo - Building image...
cd out
mkdir imgroot 2>NUL
mkdir imgroot\boot 2>NUL
copy kernel.img imgroot\boot 1>NUL
copy ..\misc\raspberry_pi\config.txt imgroot\boot 1>NUL
copy ..\misc\raspberry_pi\firmware\bootcode.bin imgroot\boot 1>NUL
copy ..\misc\raspberry_pi\firmware\fixup.dat imgroot\boot 1>NUL
copy ..\misc\raspberry_pi\firmware\start.elf imgroot\boot 1>NUL
:: wsl ~/.local/bin/genimage --config ../misc/raspberry_pi/genimage.cfg --root imgroot
cd ..
copy out\images\9x.img . 1>NUL
echo Done!
goto :end

:: AArch64 Raspberry Pi 3 config
:aarch64rpi3
echo Building:
echo - Cleaning output directory...
del 9x.iso 2>NUL
del 9x.img 2>NUL
rmdir /s /q out 2>NUL
mkdir out 2>NUL
:: Kernel building
echo - Compiling kernel...
cd kernel
cmd /k "zig build -Drelease-safe=true -Dcpu-arch=aarch64 -Dmachine-type=raspberry_pi & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..
llvm-objcopy kernel\out\kernel -O binary out\kernel8.img
echo Done!
goto :end

:: RISC-V QEMU bootloader config
:riscv64qemu
echo Building:
:: Kernel building
echo - Compiling kernel...
cd kernel
cmd /k "zig build -Drelease-safe=true -Dcpu-arch=riscv64 & exit"
if %errorlevel% NEQ 0 (
    goto :compfailed
)
cd ..
copy kernel\out\kernel out 1>NUL
echo Done!
goto :end

:compfailed
echo.
echo Compilation failed, aborting...
exit /b 1

:end
exit /b 0
