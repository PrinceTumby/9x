const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});

    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("test_program", null);
    exe.addAssemblyFile("src/main.s");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.setOutputDir("out");
    exe.single_threaded = true;

    b.default_step.dependOn(&exe.step);
}
