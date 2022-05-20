const std = @import("std");
const LibExeObjStep = std.build.LibExeObjStep;
const Builder = std.build.Builder;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const builtin = @import("builtin");
const multiboot2_builder = @import("../../../../boot/multiboot2/build.zig");
const build_options = @import("../../../config/config.zig");

pub fn build(b: *Builder) void {
    const build_mode = b.standardReleaseOptions();

    // b.verbose = true;
    // b.verbose_link = true;

    // // ACPICA library
    // const patched_acpica_files = comptime blk: {
    //     var patched_files = acpica_files;
    //     for (patched_files) |*file_path| {
    //         file_path.* = "../" ++ file_path.*;
    //     }
    //     break :blk patched_files;
    // };
    // const acpica_library = b.addSystemCommand(&[_][]const u8{
    //     "wsl",
    //     "ls",
    //     "build-cache/built.txt",
    //     "2>/dev/null",
    //     "1>/dev/null",
    //     "||",
    //     "(",
    //     "cd",
    //     "build-cache",
    //     "&&",
    //     // "gcc",
    //     "clang",
    //     "-I../src/platform/acpi/acpica/include",
    //     "-U_LINUX",
    //     "-U__linux__",
    //     "-D__9x__",
    //     "-DB_9X_64_BIT",
    //     "-DDEBUG=0",
    //     "-fPIC",
    //     "-disable-red-zone",
    //     "-nostdlib",
    //     "-ffunction-sections",
    //     "-c",
    //     "-w",
    //     "-O2",
    // } ++ patched_acpica_files ++ [_][]const u8{
    //     "&&",
    //     "touch",
    //     "built.txt",
    //     ")",
    // });

    // ACPICA library
    const acpica_library = b.addStaticLibrary("acpica", null);
    acpica_library.setBuildMode(build_mode);
    acpica_library.setTarget(CrossTarget{
        .cpu_arch = Target.Cpu.Arch.x86_64,
        .os_tag = Target.Os.Tag.freestanding,
        .abi = Target.Abi.gnu,
    });
    acpica_library.force_pic = true;
    acpica_library.red_zone = false;
    acpica_library.addIncludeDir("src/platform/acpi/acpica/include");
    acpica_library.defineCMacro("__9x__", null);
    acpica_library.defineCMacro("B_9X_64_BIT", null);
    acpica_library.defineCMacro("_DEBUG", "0");
    for (acpica_files) |file_path| {
        acpica_library.addCSourceFile(file_path, &[_][]const u8{});
    }

    // // ACPICA Library
    // const acpica_library = b.addSystemCommand(&[_][]const u8{
    //     "wsl",
    //     "zig",
    //     "build",
    //     "--build-file",
    //     "build_acpica.zig",
    // });

    // Multiboot stub
    // const multiboot = b.addExecutable("multiboot_stub", null);
    // multiboot.addAssemblyFile("boot/multiboot/src/entry.s");
    // multiboot.setBuildMode(build_mode);
    // multiboot.setTarget(CrossTarget{
    //     .cpu_arch = Target.Cpu.Arch.x86_64,
    //     .os_tag = Target.Os.Tag.freestanding,
    //     .abi = Target.Abi.gnu,
    // });
    // multiboot.setLinkerScriptPath("boot/multiboot/link.ld");
    // multiboot.setOutputDir("boot/multiboot/out");
    // multiboot.force_pic = true;
    // multiboot.disable_stack_probing = true;
    // multiboot.strip = true;
    // const multiboot2 = b.addSystemCommand(&[_][]const u8{
    //     "nasm",
    //     "-f bin",
    //     "boot/multiboot2/src/entry.asm",
    //     "-o boot/multiboot2/out/multiboot2_stub.bin",
    // });

    // Main kernel executable
    const kernel = b.addExecutable("kernel_unstripped", "src/main.zig");
    kernel.addAssemblyFile("src/arch/x86_64/init.s");
    kernel.setBuildMode(build_mode);
    kernel.setTarget(CrossTarget{
        .cpu_arch = Target.Cpu.Arch.x86_64,
        .os_tag = Target.Os.Tag.freestanding,
        .abi = Target.Abi.gnu,
    });
    kernel.setLinkerScriptPath(.{ .path = "src/arch/x86_64/build/link.ld" });
    kernel.setOutputDir("out");
    kernel.force_pic = true;
    kernel.code_model = .kernel;
    kernel.single_threaded = true;
    kernel.red_zone = false;
    kernel.disable_stack_probing = true;
    kernel.linkLibrary(acpica_library);
    // kernel.setVerboseCC(true);
    // kernel.setVerboseLink(true);
    kernel.addCSourceFile("src/platform/acpi/acpica/zig/os_layer_extra.c", &[_][]const u8{});
    // kernel.step.dependOn(&acpica_library.step);
    // kernel.addLibPath("build-cache");
    // kernel.linkSystemLibraryName("acpica");
    // for (acpica_files) |file_path| {
    //     const fixed_path = b.fmt("build-cache/{s}.o", .{file_path[32 .. file_path.len - 2]});
    //     kernel.addObjectFile(fixed_path);
    // }

    const kernel_stripped = b.addSystemCommand(&[_][]const u8{
        "wsl",
        "objcopy",
        "--strip-debug",
        "out/kernel_unstripped",
        "out/kernel",
    });
    kernel_stripped.step.dependOn(&kernel.step);

    const multiboot2 = multiboot2_builder.build(b, build_mode, CrossTarget{
        .cpu_arch = Target.Cpu.Arch.x86_64,
        .os_tag = Target.Os.Tag.freestanding,
        .abi = Target.Abi.none,
    });
    multiboot2.step.dependOn(&kernel_stripped.step);
    b.default_step.dependOn(&multiboot2.step);

    if (build_options.efi.efi_stub_enabled) {
        const efi = b.addExecutable("bootx64", "boot/efi/src/main.zig");
        efi.step.dependOn(&kernel_stripped.step);
        efi.setBuildMode(build_mode);
        efi.setTarget(CrossTarget{
            .cpu_arch = Target.Cpu.Arch.x86_64,
            .os_tag = Target.Os.Tag.uefi,
            .abi = Target.Abi.msvc,
        });
        efi.strip = true;
        efi.disable_stack_probing = true;
        efi.single_threaded = true;
        efi.setOutputDir("boot/efi/out");

        b.default_step.dependOn(&efi.step);
    } else {
        b.default_step.dependOn(&kernel_stripped.step);
    }
}

const acpica_files = [_][]const u8{
    // "src/platform/acpi/acpica/include/acpi.h",
    // "src/platform/acpi/acpica/include/acapps.h",
    // "src/platform/acpi/acpica/include/acbuffer.h",
    // "src/platform/acpi/acpica/include/acclib.h",
    // "src/platform/acpi/acpica/include/accommon.h",
    // "src/platform/acpi/acpica/include/acconfig.h",
    // "src/platform/acpi/acpica/include/acconvert.h",
    // "src/platform/acpi/acpica/include/acdebug.h",
    // "src/platform/acpi/acpica/include/acdisasm.h",
    // "src/platform/acpi/acpica/include/acdispat.h",
    // "src/platform/acpi/acpica/include/acevents.h",
    // "src/platform/acpi/acpica/include/acexcep.h",
    // "src/platform/acpi/acpica/include/acglobal.h",
    // "src/platform/acpi/acpica/include/achware.h",
    // "src/platform/acpi/acpica/include/acinterp.h",
    // "src/platform/acpi/acpica/include/aclocal.h",
    // "src/platform/acpi/acpica/include/acmacros.h",
    // "src/platform/acpi/acpica/include/acnames.h",
    // "src/platform/acpi/acpica/include/acnamesp.h",
    // "src/platform/acpi/acpica/include/acobject.h",
    // "src/platform/acpi/acpica/include/acopcode.h",
    // "src/platform/acpi/acpica/include/acoutput.h",
    // "src/platform/acpi/acpica/include/acparser.h",
    // "src/platform/acpi/acpica/include/acpiosxf.h",
    // "src/platform/acpi/acpica/include/acpixf.h",
    // "src/platform/acpi/acpica/include/acpredef.h",
    // "src/platform/acpi/acpica/include/acresrc.h",
    // "src/platform/acpi/acpica/include/acrestyp.h",
    // "src/platform/acpi/acpica/include/acstruct.h",
    // "src/platform/acpi/acpica/include/actables.h",
    // "src/platform/acpi/acpica/include/actbinfo.h",
    // "src/platform/acpi/acpica/include/actbl.h",
    // "src/platform/acpi/acpica/include/actbl1.h",
    // "src/platform/acpi/acpica/include/actbl2.h",
    // "src/platform/acpi/acpica/include/actbl3.h",
    // "src/platform/acpi/acpica/include/actypes.h",
    // "src/platform/acpi/acpica/include/acutils.h",
    // "src/platform/acpi/acpica/include/acuuid.h",
    // "src/platform/acpi/acpica/include/amlcode.h",
    // "src/platform/acpi/acpica/include/amlresrc.h",
    // "src/platform/acpi/acpica/include/platform/acenv.h",

    "src/platform/acpi/acpica/source/dsargs.c",
    "src/platform/acpi/acpica/source/dscontrol.c",
    "src/platform/acpi/acpica/source/dsdebug.c",
    "src/platform/acpi/acpica/source/dsfield.c",
    "src/platform/acpi/acpica/source/dsinit.c",
    "src/platform/acpi/acpica/source/dsmethod.c",
    "src/platform/acpi/acpica/source/dsmthdat.c",
    "src/platform/acpi/acpica/source/dsobject.c",
    "src/platform/acpi/acpica/source/dsopcode.c",
    "src/platform/acpi/acpica/source/dspkginit.c",
    "src/platform/acpi/acpica/source/dsutils.c",
    "src/platform/acpi/acpica/source/dswexec.c",
    "src/platform/acpi/acpica/source/dswload.c",
    "src/platform/acpi/acpica/source/dswload2.c",
    "src/platform/acpi/acpica/source/dswscope.c",
    "src/platform/acpi/acpica/source/dswstate.c",
    "src/platform/acpi/acpica/source/evevent.c",
    "src/platform/acpi/acpica/source/evglock.c",
    "src/platform/acpi/acpica/source/evgpe.c",
    "src/platform/acpi/acpica/source/evgpeblk.c",
    "src/platform/acpi/acpica/source/evgpeinit.c",
    "src/platform/acpi/acpica/source/evgpeutil.c",
    "src/platform/acpi/acpica/source/evhandler.c",
    "src/platform/acpi/acpica/source/evmisc.c",
    "src/platform/acpi/acpica/source/evregion.c",
    "src/platform/acpi/acpica/source/evrgnini.c",
    "src/platform/acpi/acpica/source/evsci.c",
    "src/platform/acpi/acpica/source/evxface.c",
    "src/platform/acpi/acpica/source/evxfevnt.c",
    "src/platform/acpi/acpica/source/evxfgpe.c",
    "src/platform/acpi/acpica/source/evxfregn.c",
    "src/platform/acpi/acpica/source/exconcat.c",
    "src/platform/acpi/acpica/source/exconfig.c",
    "src/platform/acpi/acpica/source/exconvrt.c",
    "src/platform/acpi/acpica/source/excreate.c",
    "src/platform/acpi/acpica/source/exdebug.c",
    "src/platform/acpi/acpica/source/exdump.c",
    "src/platform/acpi/acpica/source/exfield.c",
    "src/platform/acpi/acpica/source/exfldio.c",
    "src/platform/acpi/acpica/source/exmisc.c",
    "src/platform/acpi/acpica/source/exmutex.c",
    "src/platform/acpi/acpica/source/exnames.c",
    "src/platform/acpi/acpica/source/exoparg1.c",
    "src/platform/acpi/acpica/source/exoparg2.c",
    "src/platform/acpi/acpica/source/exoparg3.c",
    "src/platform/acpi/acpica/source/exoparg6.c",
    "src/platform/acpi/acpica/source/exprep.c",
    "src/platform/acpi/acpica/source/exregion.c",
    "src/platform/acpi/acpica/source/exresnte.c",
    "src/platform/acpi/acpica/source/exresolv.c",
    "src/platform/acpi/acpica/source/exresop.c",
    "src/platform/acpi/acpica/source/exserial.c",
    "src/platform/acpi/acpica/source/exstore.c",
    "src/platform/acpi/acpica/source/exstoren.c",
    "src/platform/acpi/acpica/source/exstorob.c",
    "src/platform/acpi/acpica/source/exsystem.c",
    "src/platform/acpi/acpica/source/extrace.c",
    "src/platform/acpi/acpica/source/exutils.c",
    "src/platform/acpi/acpica/source/hwacpi.c",
    "src/platform/acpi/acpica/source/hwesleep.c",
    "src/platform/acpi/acpica/source/hwgpe.c",
    "src/platform/acpi/acpica/source/hwpci.c",
    "src/platform/acpi/acpica/source/hwregs.c",
    "src/platform/acpi/acpica/source/hwsleep.c",
    "src/platform/acpi/acpica/source/hwtimer.c",
    "src/platform/acpi/acpica/source/hwvalid.c",
    "src/platform/acpi/acpica/source/hwxface.c",
    "src/platform/acpi/acpica/source/hwxfsleep.c",
    "src/platform/acpi/acpica/source/nsaccess.c",
    "src/platform/acpi/acpica/source/nsalloc.c",
    "src/platform/acpi/acpica/source/nsarguments.c",
    "src/platform/acpi/acpica/source/nsconvert.c",
    "src/platform/acpi/acpica/source/nsdump.c",
    "src/platform/acpi/acpica/source/nsdumpdv.c",
    "src/platform/acpi/acpica/source/nseval.c",
    "src/platform/acpi/acpica/source/nsinit.c",
    "src/platform/acpi/acpica/source/nsload.c",
    "src/platform/acpi/acpica/source/nsnames.c",
    "src/platform/acpi/acpica/source/nsobject.c",
    "src/platform/acpi/acpica/source/nsparse.c",
    "src/platform/acpi/acpica/source/nspredef.c",
    "src/platform/acpi/acpica/source/nsprepkg.c",
    "src/platform/acpi/acpica/source/nsrepair.c",
    "src/platform/acpi/acpica/source/nsrepair2.c",
    "src/platform/acpi/acpica/source/nssearch.c",
    "src/platform/acpi/acpica/source/nsutils.c",
    "src/platform/acpi/acpica/source/nswalk.c",
    "src/platform/acpi/acpica/source/nsxfeval.c",
    "src/platform/acpi/acpica/source/nsxfname.c",
    "src/platform/acpi/acpica/source/nsxfobj.c",
    "src/platform/acpi/acpica/source/psargs.c",
    "src/platform/acpi/acpica/source/psloop.c",
    "src/platform/acpi/acpica/source/psobject.c",
    "src/platform/acpi/acpica/source/psopcode.c",
    "src/platform/acpi/acpica/source/psopinfo.c",
    "src/platform/acpi/acpica/source/psparse.c",
    "src/platform/acpi/acpica/source/psscope.c",
    "src/platform/acpi/acpica/source/pstree.c",
    "src/platform/acpi/acpica/source/psutils.c",
    "src/platform/acpi/acpica/source/pswalk.c",
    "src/platform/acpi/acpica/source/psxface.c",
    "src/platform/acpi/acpica/source/rsaddr.c",
    "src/platform/acpi/acpica/source/rscalc.c",
    "src/platform/acpi/acpica/source/rscreate.c",
    // "src/platform/acpi/acpica/source/rsdump.c",
    // "src/platform/acpi/acpica/source/rsdumpinfo.c",
    "src/platform/acpi/acpica/source/rsinfo.c",
    "src/platform/acpi/acpica/source/rsio.c",
    "src/platform/acpi/acpica/source/rsirq.c",
    "src/platform/acpi/acpica/source/rslist.c",
    "src/platform/acpi/acpica/source/rsmemory.c",
    "src/platform/acpi/acpica/source/rsmisc.c",
    "src/platform/acpi/acpica/source/rsserial.c",
    "src/platform/acpi/acpica/source/rsutils.c",
    "src/platform/acpi/acpica/source/rsxface.c",
    "src/platform/acpi/acpica/source/tbdata.c",
    "src/platform/acpi/acpica/source/tbfadt.c",
    "src/platform/acpi/acpica/source/tbfind.c",
    "src/platform/acpi/acpica/source/tbinstal.c",
    "src/platform/acpi/acpica/source/tbprint.c",
    "src/platform/acpi/acpica/source/tbutils.c",
    "src/platform/acpi/acpica/source/tbxface.c",
    "src/platform/acpi/acpica/source/tbxfload.c",
    "src/platform/acpi/acpica/source/tbxfroot.c",
    "src/platform/acpi/acpica/source/utaddress.c",
    "src/platform/acpi/acpica/source/utalloc.c",
    "src/platform/acpi/acpica/source/utascii.c",
    "src/platform/acpi/acpica/source/utbuffer.c",
    "src/platform/acpi/acpica/source/utcache.c",
    "src/platform/acpi/acpica/source/utclib.c",
    "src/platform/acpi/acpica/source/utcopy.c",
    "src/platform/acpi/acpica/source/utdebug.c",
    "src/platform/acpi/acpica/source/utdecode.c",
    "src/platform/acpi/acpica/source/utdelete.c",
    "src/platform/acpi/acpica/source/uterror.c",
    "src/platform/acpi/acpica/source/uteval.c",
    "src/platform/acpi/acpica/source/utexcep.c",
    "src/platform/acpi/acpica/source/utglobal.c",
    "src/platform/acpi/acpica/source/uthex.c",
    "src/platform/acpi/acpica/source/utids.c",
    "src/platform/acpi/acpica/source/utinit.c",
    "src/platform/acpi/acpica/source/utlock.c",
    "src/platform/acpi/acpica/source/utmath.c",
    "src/platform/acpi/acpica/source/utmisc.c",
    "src/platform/acpi/acpica/source/utmutex.c",
    "src/platform/acpi/acpica/source/utnonansi.c",
    "src/platform/acpi/acpica/source/utobject.c",
    "src/platform/acpi/acpica/source/utosi.c",
    "src/platform/acpi/acpica/source/utownerid.c",
    "src/platform/acpi/acpica/source/utpredef.c",
    "src/platform/acpi/acpica/source/utprint.c",
    "src/platform/acpi/acpica/source/utresdecode.c",
    "src/platform/acpi/acpica/source/utresrc.c",
    "src/platform/acpi/acpica/source/utstate.c",
    "src/platform/acpi/acpica/source/utstring.c",
    "src/platform/acpi/acpica/source/utstrsuppt.c",
    "src/platform/acpi/acpica/source/utstrtoul64.c",
    "src/platform/acpi/acpica/source/uttrack.c",
    "src/platform/acpi/acpica/source/utuuid.c",
    "src/platform/acpi/acpica/source/utxface.c",
    "src/platform/acpi/acpica/source/utxferror.c",
    "src/platform/acpi/acpica/source/utxfinit.c",
    "src/platform/acpi/acpica/source/utxfmutex.c",
};
