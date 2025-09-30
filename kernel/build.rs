use std::process::Command;

fn main() {
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();

    // Build ACPICA.
    println!("cargo:rerun-if-changed=src/platform/acpi/acpica_9x");
    let target_cpu = match target_arch.as_str() {
        "x86_64" => "baseline-mmx-sse-sse2+soft_float",
        _ => panic!("Unrecognised target architecture \"{target_arch}\""),
    };
    assert!(
        Command::new("zig")
            .arg("build")
            .arg("-Doptimize=ReleaseSmall")
            .arg(format!("-Dtarget={target_arch}-freestanding"))
            .arg(format!("-Dcpu={target_cpu}"))
            .args(["--prefix-lib-dir", &out_dir])
            .current_dir("src/platform/acpi/acpica_9x")
            .status()
            .unwrap()
            .success()
    );
    println!("cargo:rustc-link-search=native={}", out_dir);
    println!("cargo:rustc-link-lib=static:+whole-archive=acpica");

    // Set linker script.
    println!("cargo:rustc-link-arg=-Ttargets/{target_arch}-unknown-kernel.ld");
}
