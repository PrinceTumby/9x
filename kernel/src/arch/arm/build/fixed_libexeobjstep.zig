//! Zig 0.7.1 has a bug which stops custom LLVM CPU names from being specified.
//! This is a hacky workaround to fix that.

// Original Zig source code license:
// The MIT License (Expat)
//
// Copyright (c) 2015-2022, Zig contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");
const builtin = std.builtin;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const panic = std.debug.panic;
const assert = debug.assert;
const warn = std.debug.warn;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Allocator = mem.Allocator;
const process = std.process;
const BufSet = std.BufSet;
const BufMap = std.BufMap;
const fmt_lib = std.fmt;
const File = std.fs.File;
const CrossTarget = std.zig.CrossTarget;
usingnamespace std.build;

fn doAtomicSymLinks(allocator: *Allocator, output_path: []const u8, filename_major_only: []const u8, filename_name_only: []const u8) !void {
    const out_dir = fs.path.dirname(output_path) orelse ".";
    const out_basename = fs.path.basename(output_path);
    // sym link for libfoo.so.1 to libfoo.so.1.2.3
    const major_only_path = fs.path.join(
        allocator,
        &[_][]const u8{ out_dir, filename_major_only },
    ) catch unreachable;
    fs.atomicSymLink(allocator, out_basename, major_only_path) catch |err| {
        warn("Unable to symlink {} -> {}\n", .{ major_only_path, out_basename });
        return err;
    };
    // sym link for libfoo.so to libfoo.so.1
    const name_only_path = fs.path.join(
        allocator,
        &[_][]const u8{ out_dir, filename_name_only },
    ) catch unreachable;
    fs.atomicSymLink(allocator, filename_major_only, name_only_path) catch |err| {
        warn("Unable to symlink {} -> {}\n", .{ name_only_path, filename_major_only });
        return err;
    };
}

const CSourceFile = struct {
    source: FileSource,
    args: []const []const u8,
};

const BuildOptionArtifactArg = struct {
    name: []const u8,
    artifact: *LibExeObjStep,
};

pub const FixedLibExeObjStep = struct {
    step: Step,
    builder: *Builder,
    name: []const u8,
    target: CrossTarget = CrossTarget{},
    llvm_cpu_name: ?[]const u8 = null,
    linker_script: ?[]const u8 = null,
    version_script: ?[]const u8 = null,
    out_filename: []const u8,
    is_dynamic: bool,
    version: ?Version,
    build_mode: builtin.Mode,
    kind: Kind,
    major_only_filename: []const u8,
    name_only_filename: []const u8,
    strip: bool,
    lib_paths: ArrayList([]const u8),
    framework_dirs: ArrayList([]const u8),
    frameworks: BufSet,
    verbose_link: bool,
    verbose_cc: bool,
    emit_llvm_ir: bool = false,
    emit_asm: bool = false,
    emit_bin: bool = true,
    emit_docs: bool = false,
    emit_h: bool = false,
    bundle_compiler_rt: ?bool = null,
    disable_stack_probing: bool,
    disable_sanitize_c: bool,
    rdynamic: bool,
    c_std: Builder.CStd,
    override_lib_dir: ?[]const u8,
    main_pkg_path: ?[]const u8,
    exec_cmd_args: ?[]const ?[]const u8,
    name_prefix: []const u8,
    filter: ?[]const u8,
    single_threaded: bool,
    test_evented_io: bool = false,
    code_model: builtin.CodeModel = .default,

    root_src: ?FileSource,
    out_h_filename: []const u8,
    out_lib_filename: []const u8,
    out_pdb_filename: []const u8,
    packages: ArrayList(Pkg),
    build_options_contents: std.ArrayList(u8),
    build_options_artifact_args: std.ArrayList(BuildOptionArtifactArg),

    object_src: []const u8,

    link_objects: ArrayList(LinkObject),
    include_dirs: ArrayList(IncludeDir),
    c_macros: ArrayList([]const u8),
    output_dir: ?[]const u8,
    is_linking_libc: bool = false,
    vcpkg_bin_path: ?[]const u8 = null,

    /// This may be set in order to override the default install directory
    override_dest_dir: ?InstallDir,
    installed_path: ?[]const u8,
    install_step: ?*InstallArtifactStep,

    /// Base address for an executable image.
    image_base: ?u64 = null,

    libc_file: ?[]const u8 = null,

    valgrind_support: ?bool = null,

    /// Create a .eh_frame_hdr section and a PT_GNU_EH_FRAME segment in the ELF
    /// file.
    link_eh_frame_hdr: bool = false,
    link_emit_relocs: bool = false,

    /// Place every function in its own section so that unused ones may be
    /// safely garbage-collected during the linking phase.
    link_function_sections: bool = false,

    /// Uses system Wine installation to run cross compiled Windows build artifacts.
    enable_wine: bool = false,

    /// Uses system QEMU installation to run cross compiled foreign architecture build artifacts.
    enable_qemu: bool = false,

    /// Uses system Wasmtime installation to run cross compiled wasm/wasi build artifacts.
    enable_wasmtime: bool = false,

    /// After following the steps in https://github.com/ziglang/zig/wiki/Updating-libc#glibc,
    /// this will be the directory $glibc-build-dir/install/glibcs
    /// Given the example of the aarch64 target, this is the directory
    /// that contains the path `aarch64-linux-gnu/lib/ld-linux-aarch64.so.1`.
    glibc_multi_install_dir: ?[]const u8 = null,

    /// Position Independent Code
    force_pic: ?bool = null,

    subsystem: ?builtin.SubSystem = null,

    const LinkObject = union(enum) {
        StaticPath: []const u8,
        OtherStep: *FixedLibExeObjStep,
        SystemLib: []const u8,
        AssemblyFile: FileSource,
        CSourceFile: *CSourceFile,
    };

    const IncludeDir = union(enum) {
        RawPath: []const u8,
        RawPathSystem: []const u8,
        OtherStep: *FixedLibExeObjStep,
    };

    const Kind = enum {
        Exe,
        Lib,
        Obj,
        Test,
    };

    const SharedLibKind = union(enum) {
        versioned: Version,
        unversioned: void,
    };

    pub fn createSharedLibrary(builder: *Builder, name: []const u8, root_src: ?FileSource, kind: SharedLibKind) *FixedLibExeObjStep {
        const self = builder.allocator.create(FixedLibExeObjStep) catch unreachable;
        self.* = initExtraArgs(builder, name, root_src, Kind.Lib, true, switch (kind) {
            .versioned => |ver| ver,
            .unversioned => null,
        });
        return self;
    }

    pub fn createStaticLibrary(builder: *Builder, name: []const u8, root_src: ?FileSource) *FixedLibExeObjStep {
        const self = builder.allocator.create(FixedLibExeObjStep) catch unreachable;
        self.* = initExtraArgs(builder, name, root_src, Kind.Lib, false, null);
        return self;
    }

    pub fn createObject(builder: *Builder, name: []const u8, root_src: ?FileSource) *FixedLibExeObjStep {
        const self = builder.allocator.create(FixedLibExeObjStep) catch unreachable;
        self.* = initExtraArgs(builder, name, root_src, Kind.Obj, false, null);
        return self;
    }

    pub fn createExecutable(builder: *Builder, name: []const u8, root_src: ?FileSource, is_dynamic: bool) *FixedLibExeObjStep {
        const self = builder.allocator.create(FixedLibExeObjStep) catch unreachable;
        self.* = initExtraArgs(builder, name, root_src, Kind.Exe, is_dynamic, null);
        return self;
    }

    pub fn createTest(builder: *Builder, name: []const u8, root_src: FileSource) *FixedLibExeObjStep {
        const self = builder.allocator.create(FixedLibExeObjStep) catch unreachable;
        self.* = initExtraArgs(builder, name, root_src, Kind.Test, false, null);
        return self;
    }

    fn initExtraArgs(
        builder: *Builder,
        name: []const u8,
        root_src: ?FileSource,
        kind: Kind,
        is_dynamic: bool,
        ver: ?Version,
    ) FixedLibExeObjStep {
        if (mem.indexOf(u8, name, "/") != null or mem.indexOf(u8, name, "\\") != null) {
            panic("invalid name: '{}'. It looks like a file path, but it is supposed to be the library or application name.", .{name});
        }
        var self = FixedLibExeObjStep{
            .strip = false,
            .builder = builder,
            .verbose_link = false,
            .verbose_cc = false,
            .build_mode = builtin.Mode.Debug,
            .is_dynamic = is_dynamic,
            .kind = kind,
            .root_src = root_src,
            .name = name,
            .frameworks = BufSet.init(builder.allocator),
            .step = Step.init(.LibExeObj, name, builder.allocator, make),
            .version = ver,
            .out_filename = undefined,
            .out_h_filename = builder.fmt("{}.h", .{name}),
            .out_lib_filename = undefined,
            .out_pdb_filename = builder.fmt("{}.pdb", .{name}),
            .major_only_filename = undefined,
            .name_only_filename = undefined,
            .packages = ArrayList(Pkg).init(builder.allocator),
            .include_dirs = ArrayList(IncludeDir).init(builder.allocator),
            .link_objects = ArrayList(LinkObject).init(builder.allocator),
            .c_macros = ArrayList([]const u8).init(builder.allocator),
            .lib_paths = ArrayList([]const u8).init(builder.allocator),
            .framework_dirs = ArrayList([]const u8).init(builder.allocator),
            .object_src = undefined,
            .build_options_contents = std.ArrayList(u8).init(builder.allocator),
            .build_options_artifact_args = std.ArrayList(BuildOptionArtifactArg).init(builder.allocator),
            .c_std = Builder.CStd.C99,
            .override_lib_dir = null,
            .main_pkg_path = null,
            .exec_cmd_args = null,
            .name_prefix = "",
            .filter = null,
            .disable_stack_probing = false,
            .disable_sanitize_c = false,
            .rdynamic = false,
            .output_dir = null,
            .single_threaded = false,
            .override_dest_dir = null,
            .installed_path = null,
            .install_step = null,
        };
        self.computeOutFileNames();
        if (root_src) |rs| rs.addStepDependencies(&self.step);
        return self;
    }

    fn computeOutFileNames(self: *FixedLibExeObjStep) void {
        const target_info = std.zig.system.NativeTargetInfo.detect(
            self.builder.allocator,
            self.target,
        ) catch unreachable;
        const target = target_info.target;
        self.out_filename = std.zig.binNameAlloc(self.builder.allocator, .{
            .root_name = self.name,
            .target = target,
            .output_mode = switch (self.kind) {
                .Lib => .Lib,
                .Obj => .Obj,
                .Exe, .Test => .Exe,
            },
            .link_mode = if (self.is_dynamic) .Dynamic else .Static,
            .version = self.version,
        }) catch unreachable;

        if (self.kind == .Lib) {
            if (!self.is_dynamic) {
                self.out_lib_filename = self.out_filename;
            } else if (self.version) |version| {
                if (target.isDarwin()) {
                    self.major_only_filename = self.builder.fmt("lib{s}.{d}.dylib", .{
                        self.name,
                        version.major,
                    });
                    self.name_only_filename = self.builder.fmt("lib{s}.dylib", .{self.name});
                    self.out_lib_filename = self.out_filename;
                } else if (target.os.tag == .windows) {
                    self.out_lib_filename = self.builder.fmt("{s}.lib", .{self.name});
                } else {
                    self.major_only_filename = self.builder.fmt("lib{s}.so.{d}", .{ self.name, version.major });
                    self.name_only_filename = self.builder.fmt("lib{s}.so", .{self.name});
                    self.out_lib_filename = self.out_filename;
                }
            } else {
                if (target.isDarwin()) {
                    self.out_lib_filename = self.out_filename;
                } else if (target.os.tag == .windows) {
                    self.out_lib_filename = self.builder.fmt("{s}.lib", .{self.name});
                } else {
                    self.out_lib_filename = self.out_filename;
                }
            }
        }
    }

    pub fn setTarget(self: *FixedLibExeObjStep, target: CrossTarget) void {
        self.target = target;
        self.computeOutFileNames();
    }

    pub fn _setLlvmCpu(self: *FixedLibExeObjStep, llvm_cpu_name: ?[]const u8) void {
        self.llvm_cpu_name = llvm_cpu_name;
    }

    pub fn setOutputDir(self: *FixedLibExeObjStep, dir: []const u8) void {
        self.output_dir = self.builder.dupePath(dir);
    }

    pub fn install(self: *FixedLibExeObjStep) void {
        self.builder.installArtifact(self);
    }

    pub fn installRaw(self: *FixedLibExeObjStep, dest_filename: []const u8) void {
        self.builder.installRaw(self, dest_filename);
    }

    /// Creates a `RunStep` with an executable built with `addExecutable`.
    /// Add command line arguments with `addArg`.
    pub fn run(exe: *FixedLibExeObjStep) *RunStep {
        assert(exe.kind == Kind.Exe);

        // It doesn't have to be native. We catch that if you actually try to run it.
        // Consider that this is declarative; the run step may not be run unless a user
        // option is supplied.
        const run_step = RunStep.create(exe.builder, exe.builder.fmt("run {}", .{exe.step.name}));
        run_step.addArtifactArg(exe);

        if (exe.vcpkg_bin_path) |path| {
            run_step.addPathDir(path);
        }

        return run_step;
    }

    pub fn setLinkerScriptPath(self: *FixedLibExeObjStep, path: []const u8) void {
        self.linker_script = path;
    }

    pub fn linkFramework(self: *FixedLibExeObjStep, framework_name: []const u8) void {
        assert(self.target.isDarwin());
        self.frameworks.put(framework_name) catch unreachable;
    }

    /// Returns whether the library, executable, or object depends on a particular system library.
    pub fn dependsOnSystemLibrary(self: FixedLibExeObjStep, name: []const u8) bool {
        if (isLibCLibrary(name)) {
            return self.is_linking_libc;
        }
        for (self.link_objects.span()) |link_object| {
            switch (link_object) {
                LinkObject.SystemLib => |n| if (mem.eql(u8, n, name)) return true,
                else => continue,
            }
        }
        return false;
    }

    pub fn linkLibrary(self: *FixedLibExeObjStep, lib: *FixedLibExeObjStep) void {
        assert(lib.kind == Kind.Lib);
        self.linkLibraryOrObject(lib);
    }

    pub fn isDynamicLibrary(self: *FixedLibExeObjStep) bool {
        return self.kind == Kind.Lib and self.is_dynamic;
    }

    pub fn producesPdbFile(self: *FixedLibExeObjStep) bool {
        if (!self.target.isWindows() and !self.target.isUefi()) return false;
        if (self.strip) return false;
        return self.isDynamicLibrary() or self.kind == .Exe;
    }

    pub fn linkLibC(self: *FixedLibExeObjStep) void {
        if (!self.is_linking_libc) {
            self.is_linking_libc = true;
            self.link_objects.append(LinkObject{ .SystemLib = "c" }) catch unreachable;
        }
    }

    /// name_and_value looks like [name]=[value]. If the value is omitted, it is set to 1.
    pub fn defineCMacro(self: *FixedLibExeObjStep, name_and_value: []const u8) void {
        self.c_macros.append(self.builder.dupe(name_and_value)) catch unreachable;
    }

    /// This one has no integration with anything, it just puts -lname on the command line.
    /// Prefer to use `linkSystemLibrary` instead.
    pub fn linkSystemLibraryName(self: *FixedLibExeObjStep, name: []const u8) void {
        self.link_objects.append(LinkObject{ .SystemLib = self.builder.dupe(name) }) catch unreachable;
    }

    /// This links against a system library, exclusively using pkg-config to find the library.
    /// Prefer to use `linkSystemLibrary` instead.
    pub fn linkSystemLibraryPkgConfigOnly(self: *FixedLibExeObjStep, lib_name: []const u8) !void {
        const pkg_name = match: {
            // First we have to map the library name to pkg config name. Unfortunately,
            // there are several examples where this is not straightforward:
            // -lSDL2 -> pkg-config sdl2
            // -lgdk-3 -> pkg-config gdk-3.0
            // -latk-1.0 -> pkg-config atk
            const pkgs = try self.builder.getPkgConfigList();

            // Exact match means instant winner.
            for (pkgs) |pkg| {
                if (mem.eql(u8, pkg.name, lib_name)) {
                    break :match pkg.name;
                }
            }

            // Next we'll try ignoring case.
            for (pkgs) |pkg| {
                if (std.ascii.eqlIgnoreCase(pkg.name, lib_name)) {
                    break :match pkg.name;
                }
            }

            // Now try appending ".0".
            for (pkgs) |pkg| {
                if (std.ascii.indexOfIgnoreCase(pkg.name, lib_name)) |pos| {
                    if (pos != 0) continue;
                    if (mem.eql(u8, pkg.name[lib_name.len..], ".0")) {
                        break :match pkg.name;
                    }
                }
            }

            // Trimming "-1.0".
            if (mem.endsWith(u8, lib_name, "-1.0")) {
                const trimmed_lib_name = lib_name[0 .. lib_name.len - "-1.0".len];
                for (pkgs) |pkg| {
                    if (std.ascii.eqlIgnoreCase(pkg.name, trimmed_lib_name)) {
                        break :match pkg.name;
                    }
                }
            }

            return error.PackageNotFound;
        };

        var code: u8 = undefined;
        const stdout = if (self.builder.execAllowFail(&[_][]const u8{
            "pkg-config",
            pkg_name,
            "--cflags",
            "--libs",
        }, &code, .Ignore)) |stdout| stdout else |err| switch (err) {
            error.ProcessTerminated => return error.PkgConfigCrashed,
            error.ExitCodeFailure => return error.PkgConfigFailed,
            error.FileNotFound => return error.PkgConfigNotInstalled,
            else => return err,
        };
        var it = mem.tokenize(stdout, " \r\n\t");
        while (it.next()) |tok| {
            if (mem.eql(u8, tok, "-I")) {
                const dir = it.next() orelse return error.PkgConfigInvalidOutput;
                self.addIncludeDir(dir);
            } else if (mem.startsWith(u8, tok, "-I")) {
                self.addIncludeDir(tok["-I".len..]);
            } else if (mem.eql(u8, tok, "-L")) {
                const dir = it.next() orelse return error.PkgConfigInvalidOutput;
                self.addLibPath(dir);
            } else if (mem.startsWith(u8, tok, "-L")) {
                self.addLibPath(tok["-L".len..]);
            } else if (mem.eql(u8, tok, "-l")) {
                const lib = it.next() orelse return error.PkgConfigInvalidOutput;
                self.linkSystemLibraryName(lib);
            } else if (mem.startsWith(u8, tok, "-l")) {
                self.linkSystemLibraryName(tok["-l".len..]);
            } else if (mem.eql(u8, tok, "-D")) {
                const macro = it.next() orelse return error.PkgConfigInvalidOutput;
                self.defineCMacro(macro);
            } else if (mem.startsWith(u8, tok, "-D")) {
                self.defineCMacro(tok["-D".len..]);
            } else if (mem.eql(u8, tok, "-pthread")) {
                self.linkLibC();
            } else if (self.builder.verbose) {
                warn("Ignoring pkg-config flag '{}'\n", .{tok});
            }
        }
    }

    pub fn linkSystemLibrary(self: *FixedLibExeObjStep, name: []const u8) void {
        if (isLibCLibrary(name)) {
            self.linkLibC();
            return;
        }
        if (self.linkSystemLibraryPkgConfigOnly(name)) |_| {
            // pkg-config worked, so nothing further needed to do.
            return;
        } else |err| switch (err) {
            error.PkgConfigInvalidOutput,
            error.PkgConfigCrashed,
            error.PkgConfigFailed,
            error.PkgConfigNotInstalled,
            error.PackageNotFound,
            => {},

            else => unreachable,
        }

        self.linkSystemLibraryName(name);
    }

    pub fn setNamePrefix(self: *FixedLibExeObjStep, text: []const u8) void {
        assert(self.kind == Kind.Test);
        self.name_prefix = text;
    }

    pub fn setFilter(self: *FixedLibExeObjStep, text: ?[]const u8) void {
        assert(self.kind == Kind.Test);
        self.filter = text;
    }

    pub fn addCSourceFile(self: *FixedLibExeObjStep, file: []const u8, args: []const []const u8) void {
        self.addCSourceFileSource(.{
            .args = args,
            .source = .{ .path = file },
        });
    }

    pub fn addCSourceFileSource(self: *FixedLibExeObjStep, source: CSourceFile) void {
        const c_source_file = self.builder.allocator.create(CSourceFile) catch unreachable;

        const args_copy = self.builder.allocator.alloc([]u8, source.args.len) catch unreachable;
        for (source.args) |arg, i| {
            args_copy[i] = self.builder.dupe(arg);
        }

        c_source_file.* = source;
        c_source_file.args = args_copy;
        self.link_objects.append(LinkObject{ .CSourceFile = c_source_file }) catch unreachable;
    }

    pub fn setVerboseLink(self: *FixedLibExeObjStep, value: bool) void {
        self.verbose_link = value;
    }

    pub fn setVerboseCC(self: *FixedLibExeObjStep, value: bool) void {
        self.verbose_cc = value;
    }

    pub fn setBuildMode(self: *FixedLibExeObjStep, mode: builtin.Mode) void {
        self.build_mode = mode;
    }

    pub fn overrideZigLibDir(self: *FixedLibExeObjStep, dir_path: []const u8) void {
        self.override_lib_dir = self.builder.dupe(dir_path);
    }

    pub fn setMainPkgPath(self: *FixedLibExeObjStep, dir_path: []const u8) void {
        self.main_pkg_path = dir_path;
    }

    pub fn setLibCFile(self: *FixedLibExeObjStep, libc_file: ?[]const u8) void {
        self.libc_file = libc_file;
    }

    /// Unless setOutputDir was called, this function must be called only in
    /// the make step, from a step that has declared a dependency on this one.
    /// To run an executable built with zig build, use `run`, or create an install step and invoke it.
    pub fn getOutputPath(self: *FixedLibExeObjStep) []const u8 {
        return fs.path.join(
            self.builder.allocator,
            &[_][]const u8{ self.output_dir.?, self.out_filename },
        ) catch unreachable;
    }

    /// Unless setOutputDir was called, this function must be called only in
    /// the make step, from a step that has declared a dependency on this one.
    pub fn getOutputLibPath(self: *FixedLibExeObjStep) []const u8 {
        assert(self.kind == Kind.Lib);
        return fs.path.join(
            self.builder.allocator,
            &[_][]const u8{ self.output_dir.?, self.out_lib_filename },
        ) catch unreachable;
    }

    /// Unless setOutputDir was called, this function must be called only in
    /// the make step, from a step that has declared a dependency on this one.
    pub fn getOutputHPath(self: *FixedLibExeObjStep) []const u8 {
        assert(self.kind != Kind.Exe);
        assert(self.emit_h);
        return fs.path.join(
            self.builder.allocator,
            &[_][]const u8{ self.output_dir.?, self.out_h_filename },
        ) catch unreachable;
    }

    /// Unless setOutputDir was called, this function must be called only in
    /// the make step, from a step that has declared a dependency on this one.
    pub fn getOutputPdbPath(self: *FixedLibExeObjStep) []const u8 {
        assert(self.target.isWindows() or self.target.isUefi());
        return fs.path.join(
            self.builder.allocator,
            &[_][]const u8{ self.output_dir.?, self.out_pdb_filename },
        ) catch unreachable;
    }

    pub fn addAssemblyFile(self: *FixedLibExeObjStep, path: []const u8) void {
        self.link_objects.append(LinkObject{
            .AssemblyFile = .{ .path = self.builder.dupe(path) },
        }) catch unreachable;
    }

    pub fn addAssemblyFileFromWriteFileStep(self: *FixedLibExeObjStep, wfs: *WriteFileStep, basename: []const u8) void {
        self.addAssemblyFileSource(.{
            .write_file = .{
                .step = wfs,
                .basename = self.builder.dupe(basename),
            },
        });
    }

    pub fn addAssemblyFileSource(self: *FixedLibExeObjStep, source: FileSource) void {
        self.link_objects.append(LinkObject{ .AssemblyFile = source }) catch unreachable;
        source.addStepDependencies(&self.step);
    }

    pub fn addObjectFile(self: *FixedLibExeObjStep, path: []const u8) void {
        self.link_objects.append(LinkObject{ .StaticPath = self.builder.dupe(path) }) catch unreachable;
    }

    pub fn addObject(self: *FixedLibExeObjStep, obj: *FixedLibExeObjStep) void {
        assert(obj.kind == Kind.Obj);
        self.linkLibraryOrObject(obj);
    }

    pub fn addBuildOption(self: *FixedLibExeObjStep, comptime T: type, name: []const u8, value: T) void {
        const out = self.build_options_contents.outStream();
        switch (T) {
            []const []const u8 => {
                out.print("pub const {z}: []const []const u8 = &[_][]const u8{{\n", .{name}) catch unreachable;
                for (value) |slice| {
                    out.print("    \"{Z}\",\n", .{slice}) catch unreachable;
                }
                out.writeAll("};\n") catch unreachable;
                return;
            },
            []const u8 => {
                out.print("pub const {z}: []const u8 = \"{Z}\";\n", .{ name, value }) catch unreachable;
                return;
            },
            ?[]const u8 => {
                out.print("pub const {z}: ?[]const u8 = ", .{name}) catch unreachable;
                if (value) |payload| {
                    out.print("\"{Z}\";\n", .{payload}) catch unreachable;
                } else {
                    out.writeAll("null;\n") catch unreachable;
                }
                return;
            },
            std.SemanticVersion => {
                out.print(
                    \\pub const {z}: @import("std").SemanticVersion = .{{
                    \\    .major = {d},
                    \\    .minor = {d},
                    \\    .patch = {d},
                    \\
                , .{
                    name,

                    value.major,
                    value.minor,
                    value.patch,
                }) catch unreachable;
                if (value.pre) |some| {
                    out.print("    .pre = \"{Z}\",\n", .{some}) catch unreachable;
                }
                if (value.build) |some| {
                    out.print("    .build = \"{Z}\",\n", .{some}) catch unreachable;
                }
                out.writeAll("};\n") catch unreachable;
                return;
            },
            else => {},
        }
        switch (@typeInfo(T)) {
            .Enum => |enum_info| {
                out.print("pub const {z} = enum {{\n", .{@typeName(T)}) catch unreachable;
                inline for (enum_info.fields) |field| {
                    out.print("    {z},\n", .{field.name}) catch unreachable;
                }
                out.writeAll("};\n") catch unreachable;
            },
            else => {},
        }
        out.print("pub const {z}: {} = {};\n", .{ name, @typeName(T), value }) catch unreachable;
    }

    /// The value is the path in the cache dir.
    /// Adds a dependency automatically.
    pub fn addBuildOptionArtifact(self: *FixedLibExeObjStep, name: []const u8, artifact: *FixedLibExeObjStep) void {
        self.build_options_artifact_args.append(.{ .name = name, .artifact = artifact }) catch unreachable;
        self.step.dependOn(&artifact.step);
    }

    pub fn addSystemIncludeDir(self: *FixedLibExeObjStep, path: []const u8) void {
        self.include_dirs.append(IncludeDir{ .RawPathSystem = self.builder.dupe(path) }) catch unreachable;
    }

    pub fn addIncludeDir(self: *FixedLibExeObjStep, path: []const u8) void {
        self.include_dirs.append(IncludeDir{ .RawPath = self.builder.dupe(path) }) catch unreachable;
    }

    pub fn addLibPath(self: *FixedLibExeObjStep, path: []const u8) void {
        self.lib_paths.append(self.builder.dupe(path)) catch unreachable;
    }

    pub fn addFrameworkDir(self: *FixedLibExeObjStep, dir_path: []const u8) void {
        self.framework_dirs.append(self.builder.dupe(dir_path)) catch unreachable;
    }

    pub fn addPackage(self: *FixedLibExeObjStep, package: Pkg) void {
        self.packages.append(self.builder.dupePkg(package)) catch unreachable;
    }

    pub fn addPackagePath(self: *FixedLibExeObjStep, name: []const u8, pkg_index_path: []const u8) void {
        self.packages.append(Pkg{
            .name = self.builder.dupe(name),
            .path = self.builder.dupe(pkg_index_path),
        }) catch unreachable;
    }

    /// If Vcpkg was found on the system, it will be added to include and lib
    /// paths for the specified target.
    pub fn addVcpkgPaths(self: *FixedLibExeObjStep, linkage: VcpkgLinkage) !void {
        // Ideally in the Unattempted case we would call the function recursively
        // after findVcpkgRoot and have only one switch statement, but the compiler
        // cannot resolve the error set.
        switch (self.builder.vcpkg_root) {
            .Unattempted => {
                self.builder.vcpkg_root = if (try findVcpkgRoot(self.builder.allocator)) |root|
                    VcpkgRoot{ .Found = root }
                else
                    .NotFound;
            },
            .NotFound => return error.VcpkgNotFound,
            .Found => {},
        }

        switch (self.builder.vcpkg_root) {
            .Unattempted => unreachable,
            .NotFound => return error.VcpkgNotFound,
            .Found => |root| {
                const allocator = self.builder.allocator;
                const triplet = try self.target.vcpkgTriplet(allocator, linkage);
                defer self.builder.allocator.free(triplet);

                const include_path = try fs.path.join(allocator, &[_][]const u8{ root, "installed", triplet, "include" });
                errdefer allocator.free(include_path);
                try self.include_dirs.append(IncludeDir{ .RawPath = include_path });

                const lib_path = try fs.path.join(allocator, &[_][]const u8{ root, "installed", triplet, "lib" });
                try self.lib_paths.append(lib_path);

                self.vcpkg_bin_path = try fs.path.join(allocator, &[_][]const u8{ root, "installed", triplet, "bin" });
            },
        }
    }

    pub fn setExecCmd(self: *FixedLibExeObjStep, args: []const ?[]const u8) void {
        assert(self.kind == Kind.Test);
        self.exec_cmd_args = args;
    }

    fn linkLibraryOrObject(self: *FixedLibExeObjStep, other: *FixedLibExeObjStep) void {
        self.step.dependOn(&other.step);
        self.link_objects.append(LinkObject{ .OtherStep = other }) catch unreachable;
        self.include_dirs.append(IncludeDir{ .OtherStep = other }) catch unreachable;

        // Inherit dependency on system libraries
        for (other.link_objects.span()) |link_object| {
            switch (link_object) {
                .SystemLib => |name| self.linkSystemLibrary(name),
                else => continue,
            }
        }

        // Inherit dependencies on darwin frameworks
        if (self.target.isDarwin() and !other.isDynamicLibrary()) {
            var it = other.frameworks.iterator();
            while (it.next()) |entry| {
                self.frameworks.put(entry.key) catch unreachable;
            }
        }
    }

    fn makePackageCmd(self: *FixedLibExeObjStep, pkg: Pkg, zig_args: *ArrayList([]const u8)) error{OutOfMemory}!void {
        const builder = self.builder;

        try zig_args.append("--pkg-begin");
        try zig_args.append(pkg.name);
        try zig_args.append(builder.pathFromRoot(pkg.path));

        if (pkg.dependencies) |dependencies| {
            for (dependencies) |sub_pkg| {
                try self.makePackageCmd(sub_pkg, zig_args);
            }
        }

        try zig_args.append("--pkg-end");
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(FixedLibExeObjStep, "step", step);
        const builder = self.builder;

        if (self.root_src == null and self.link_objects.items.len == 0) {
            warn("{}: linker needs 1 or more objects to link\n", .{self.step.name});
            return error.NeedAnObject;
        }

        var zig_args = ArrayList([]const u8).init(builder.allocator);
        defer zig_args.deinit();

        zig_args.append(builder.zig_exe) catch unreachable;

        const cmd = switch (self.kind) {
            .Lib => "build-lib",
            .Exe => "build-exe",
            .Obj => "build-obj",
            .Test => "test",
        };
        zig_args.append(cmd) catch unreachable;

        if (builder.color != .auto) {
            try zig_args.append("--color");
            try zig_args.append(@tagName(builder.color));
        }

        if (self.root_src) |root_src| try zig_args.append(root_src.getPath(builder));

        var prev_has_extra_flags = false;
        for (self.link_objects.span()) |link_object| {
            switch (link_object) {
                .StaticPath => |static_path| {
                    try zig_args.append(builder.pathFromRoot(static_path));
                },

                .OtherStep => |other| switch (other.kind) {
                    .Exe => unreachable,
                    .Test => unreachable,
                    .Obj => {
                        try zig_args.append(other.getOutputPath());
                    },
                    .Lib => {
                        const full_path_lib = other.getOutputLibPath();
                        try zig_args.append(full_path_lib);

                        if (other.is_dynamic and !self.target.isWindows()) {
                            if (fs.path.dirname(full_path_lib)) |dirname| {
                                try zig_args.append("-rpath");
                                try zig_args.append(dirname);
                            }
                        }
                    },
                },
                .SystemLib => |name| {
                    try zig_args.append("--library");
                    try zig_args.append(name);
                },
                .AssemblyFile => |asm_file| {
                    if (prev_has_extra_flags) {
                        try zig_args.append("-extra-cflags");
                        try zig_args.append("--");
                        prev_has_extra_flags = false;
                    }
                    try zig_args.append(asm_file.getPath(builder));
                },
                .CSourceFile => |c_source_file| {
                    if (c_source_file.args.len == 0) {
                        if (prev_has_extra_flags) {
                            try zig_args.append("-cflags");
                            try zig_args.append("--");
                            prev_has_extra_flags = false;
                        }
                    } else {
                        try zig_args.append("-cflags");
                        for (c_source_file.args) |arg| {
                            try zig_args.append(arg);
                        }
                        try zig_args.append("--");
                    }
                    try zig_args.append(c_source_file.source.getPath(builder));
                },
            }
        }

        if (self.build_options_contents.items.len > 0 or self.build_options_artifact_args.items.len > 0) {
            // Render build artifact options at the last minute, now that the path is known.
            for (self.build_options_artifact_args.items) |item| {
                const out = self.build_options_contents.writer();
                out.print("pub const {}: []const u8 = \"{Z}\";\n", .{ item.name, item.artifact.getOutputPath() }) catch unreachable;
            }

            const build_options_file = try fs.path.join(
                builder.allocator,
                &[_][]const u8{ builder.cache_root, builder.fmt("{}_build_options.zig", .{self.name}) },
            );
            const path_from_root = builder.pathFromRoot(build_options_file);
            try fs.cwd().writeFile(path_from_root, self.build_options_contents.span());
            try zig_args.append("--pkg-begin");
            try zig_args.append("build_options");
            try zig_args.append(path_from_root);
            try zig_args.append("--pkg-end");
        }

        if (self.image_base) |image_base| {
            try zig_args.append("--image-base");
            try zig_args.append(builder.fmt("0x{x}", .{image_base}));
        }

        if (self.filter) |filter| {
            try zig_args.append("--test-filter");
            try zig_args.append(filter);
        }

        if (self.test_evented_io) {
            try zig_args.append("--test-evented-io");
        }

        if (self.name_prefix.len != 0) {
            try zig_args.append("--test-name-prefix");
            try zig_args.append(self.name_prefix);
        }

        if (builder.verbose_tokenize) zig_args.append("--verbose-tokenize") catch unreachable;
        if (builder.verbose_ast) zig_args.append("--verbose-ast") catch unreachable;
        if (builder.verbose_cimport) zig_args.append("--verbose-cimport") catch unreachable;
        if (builder.verbose_ir) zig_args.append("--verbose-ir") catch unreachable;
        if (builder.verbose_llvm_ir) zig_args.append("--verbose-llvm-ir") catch unreachable;
        if (builder.verbose_link or self.verbose_link) zig_args.append("--verbose-link") catch unreachable;
        if (builder.verbose_cc or self.verbose_cc) zig_args.append("--verbose-cc") catch unreachable;
        if (builder.verbose_llvm_cpu_features) zig_args.append("--verbose-llvm-cpu-features") catch unreachable;

        if (self.emit_llvm_ir) try zig_args.append("-femit-llvm-ir");
        if (self.emit_asm) try zig_args.append("-femit-asm");
        if (!self.emit_bin) try zig_args.append("-fno-emit-bin");
        if (self.emit_docs) try zig_args.append("-femit-docs");
        if (self.emit_h) try zig_args.append("-femit-h");

        if (self.strip) {
            try zig_args.append("--strip");
        }
        if (self.link_eh_frame_hdr) {
            try zig_args.append("--eh-frame-hdr");
        }
        if (self.link_emit_relocs) {
            try zig_args.append("--emit-relocs");
        }
        if (self.link_function_sections) {
            try zig_args.append("-ffunction-sections");
        }
        if (self.single_threaded) {
            try zig_args.append("--single-threaded");
        }

        if (self.libc_file) |libc_file| {
            try zig_args.append("--libc");
            try zig_args.append(builder.pathFromRoot(libc_file));
        }

        switch (self.build_mode) {
            .Debug => {}, // Skip since it's the default.
            else => zig_args.append(builder.fmt("-O{s}", .{@tagName(self.build_mode)})) catch unreachable,
        }

        try zig_args.append("--cache-dir");
        try zig_args.append(builder.pathFromRoot(builder.cache_root));

        try zig_args.append("--global-cache-dir");
        try zig_args.append(builder.pathFromRoot(builder.global_cache_root));

        zig_args.append("--name") catch unreachable;
        zig_args.append(self.name) catch unreachable;

        if (self.kind == Kind.Lib and self.is_dynamic) {
            if (self.version) |version| {
                zig_args.append("--version") catch unreachable;
                zig_args.append(builder.fmt("{}", .{version})) catch unreachable;
            }
        }
        if (self.is_dynamic) {
            try zig_args.append("-dynamic");
        }
        if (self.bundle_compiler_rt) |x| {
            if (x) {
                try zig_args.append("-fcompiler-rt");
            } else {
                try zig_args.append("-fno-compiler-rt");
            }
        }
        if (self.disable_stack_probing) {
            try zig_args.append("-fno-stack-check");
        }
        if (self.disable_sanitize_c) {
            try zig_args.append("-fno-sanitize-c");
        }
        if (self.rdynamic) {
            try zig_args.append("-rdynamic");
        }

        if (self.code_model != .default) {
            try zig_args.append("-mcmodel");
            try zig_args.append(@tagName(self.code_model));
        }

        if (!self.target.isNative()) {
            try zig_args.append("-target");
            try zig_args.append(try self.target.zigTriple(builder.allocator));

            // TODO this logic can disappear if cpu model + features becomes part of the target triple
            const cross = self.target.toTarget();
            const all_features = cross.cpu.arch.allFeaturesList();
            var populated_cpu_features = cross.cpu.model.features;
            populated_cpu_features.populateDependencies(all_features);

            if (self.llvm_cpu_name) |cpu_name| {
                try zig_args.append("-mcpu");
                try zig_args.append(cpu_name);
            }
            // if (populated_cpu_features.eql(cross.cpu.features)) {
            //     // The CPU name alone is sufficient.
            //     // If it is the baseline CPU, no command line args are required.
            //     if (cross.cpu.model != std.Target.Cpu.baseline(cross.cpu.arch).model) {
            //         try zig_args.append("-mcpu");
            //         try zig_args.append(cross.cpu.model.name);
            //     }
            // } else {
            //     var mcpu_buffer = std.ArrayList(u8).init(builder.allocator);

            //     try mcpu_buffer.outStream().print("-mcpu={}", .{cross.cpu.model.name});

            //     for (all_features) |feature, i_usize| {
            //         const i = @intCast(std.Target.Cpu.Feature.Set.Index, i_usize);
            //         const in_cpu_set = populated_cpu_features.isEnabled(i);
            //         const in_actual_set = cross.cpu.features.isEnabled(i);
            //         if (in_cpu_set and !in_actual_set) {
            //             try mcpu_buffer.outStream().print("-{}", .{feature.name});
            //         } else if (!in_cpu_set and in_actual_set) {
            //             try mcpu_buffer.outStream().print("+{}", .{feature.name});
            //         }
            //     }

            //     try zig_args.append(mcpu_buffer.toOwnedSlice());
            // }

            if (self.target.dynamic_linker.get()) |dynamic_linker| {
                try zig_args.append("--dynamic-linker");
                try zig_args.append(dynamic_linker);
            }
        }

        if (self.linker_script) |linker_script| {
            try zig_args.append("--script");
            try zig_args.append(builder.pathFromRoot(linker_script));
        }

        if (self.version_script) |version_script| {
            try zig_args.append("--version-script");
            try zig_args.append(builder.pathFromRoot(version_script));
        }

        if (self.exec_cmd_args) |exec_cmd_args| {
            for (exec_cmd_args) |cmd_arg| {
                if (cmd_arg) |arg| {
                    try zig_args.append("--test-cmd");
                    try zig_args.append(arg);
                } else {
                    try zig_args.append("--test-cmd-bin");
                }
            }
        } else switch (self.target.getExternalExecutor()) {
            .native, .unavailable => {},
            .qemu => |bin_name| if (self.enable_qemu) qemu: {
                const need_cross_glibc = self.target.isGnuLibC() and self.is_linking_libc;
                const glibc_dir_arg = if (need_cross_glibc)
                    self.glibc_multi_install_dir orelse break :qemu
                else
                    null;
                try zig_args.append("--test-cmd");
                try zig_args.append(bin_name);
                if (glibc_dir_arg) |dir| {
                    const full_dir = try fs.path.join(builder.allocator, &[_][]const u8{
                        dir,
                        try self.target.linuxTriple(builder.allocator),
                    });

                    try zig_args.append("--test-cmd");
                    try zig_args.append("-L");
                    try zig_args.append("--test-cmd");
                    try zig_args.append(full_dir);
                }
                try zig_args.append("--test-cmd-bin");
            },
            .wine => |bin_name| if (self.enable_wine) {
                try zig_args.append("--test-cmd");
                try zig_args.append(bin_name);
                try zig_args.append("--test-cmd-bin");
            },
            .wasmtime => |bin_name| if (self.enable_wasmtime) {
                try zig_args.append("--test-cmd");
                try zig_args.append(bin_name);
                try zig_args.append("--test-cmd");
                try zig_args.append("--dir=.");
                try zig_args.append("--test-cmd-bin");
            },
        }

        for (self.packages.span()) |pkg| {
            try self.makePackageCmd(pkg, &zig_args);
        }

        for (self.include_dirs.span()) |include_dir| {
            switch (include_dir) {
                .RawPath => |include_path| {
                    try zig_args.append("-I");
                    try zig_args.append(self.builder.pathFromRoot(include_path));
                },
                .RawPathSystem => |include_path| {
                    try zig_args.append("-isystem");
                    try zig_args.append(self.builder.pathFromRoot(include_path));
                },
                .OtherStep => |other| if (other.emit_h) {
                    const h_path = other.getOutputHPath();
                    try zig_args.append("-isystem");
                    try zig_args.append(fs.path.dirname(h_path).?);
                },
            }
        }

        for (self.lib_paths.span()) |lib_path| {
            try zig_args.append("-L");
            try zig_args.append(lib_path);
        }

        for (self.c_macros.span()) |c_macro| {
            try zig_args.append("-D");
            try zig_args.append(c_macro);
        }

        if (self.target.isDarwin()) {
            for (self.framework_dirs.span()) |dir| {
                try zig_args.append("-F");
                try zig_args.append(dir);
            }

            var it = self.frameworks.iterator();
            while (it.next()) |entry| {
                zig_args.append("-framework") catch unreachable;
                zig_args.append(entry.key) catch unreachable;
            }
        }

        if (self.valgrind_support) |valgrind_support| {
            if (valgrind_support) {
                try zig_args.append("-fvalgrind");
            } else {
                try zig_args.append("-fno-valgrind");
            }
        }

        if (self.override_lib_dir) |dir| {
            try zig_args.append("--override-lib-dir");
            try zig_args.append(builder.pathFromRoot(dir));
        } else if (self.builder.override_lib_dir) |dir| {
            try zig_args.append("--override-lib-dir");
            try zig_args.append(builder.pathFromRoot(dir));
        }

        if (self.main_pkg_path) |dir| {
            try zig_args.append("--main-pkg-path");
            try zig_args.append(builder.pathFromRoot(dir));
        }

        if (self.force_pic) |pic| {
            if (pic) {
                try zig_args.append("-fPIC");
            } else {
                try zig_args.append("-fno-PIC");
            }
        }

        if (self.subsystem) |subsystem| {
            try zig_args.append("--subsystem");
            try zig_args.append(switch (subsystem) {
                .Console => "console",
                .Windows => "windows",
                .Posix => "posix",
                .Native => "native",
                .EfiApplication => "efi_application",
                .EfiBootServiceDriver => "efi_boot_service_driver",
                .EfiRom => "efi_rom",
                .EfiRuntimeDriver => "efi_runtime_driver",
            });
        }

        if (self.kind == Kind.Test) {
            try builder.spawnChild(zig_args.span());
        } else {
            try zig_args.append("--enable-cache");

            const output_dir_nl = try builder.execFromStep(zig_args.span(), &self.step);
            const build_output_dir = mem.trimRight(u8, output_dir_nl, "\r\n");

            if (self.output_dir) |output_dir| {
                var src_dir = try std.fs.cwd().openDir(build_output_dir, .{ .iterate = true });
                defer src_dir.close();

                // Create the output directory if it doesn't exist.
                try std.fs.cwd().makePath(output_dir);

                var dest_dir = try std.fs.cwd().openDir(output_dir, .{});
                defer dest_dir.close();

                var it = src_dir.iterate();
                while (try it.next()) |entry| {
                    // The compiler can put these files into the same directory, but we don't
                    // want to copy them over.
                    if (mem.eql(u8, entry.name, "stage1.id") or
                        mem.eql(u8, entry.name, "llvm-ar.id") or
                        mem.eql(u8, entry.name, "libs.txt") or
                        mem.eql(u8, entry.name, "builtin.zig") or
                        mem.eql(u8, entry.name, "lld.id")) continue;

                    _ = try src_dir.updateFile(entry.name, dest_dir, entry.name, .{});
                }
            } else {
                self.output_dir = build_output_dir;
            }
        }

        if (self.kind == Kind.Lib and self.is_dynamic and self.version != null and self.target.wantSharedLibSymLinks()) {
            try doAtomicSymLinks(builder.allocator, self.getOutputPath(), self.major_only_filename, self.name_only_filename);
        }
    }
};
