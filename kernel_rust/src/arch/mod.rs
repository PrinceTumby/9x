cfg_select! {
    target_arch = "x86_64" => {
        mod x86_64;
        pub use x86_64::*;
    }
    _ => {
        compile_error!("Unsupported architecture");
    }
}
