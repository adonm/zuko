// On atomic Linux hosts (uBlue/Bluefin, Fedora Silverblue, …) the -devel
// symlinks `libpixman-1.so` / `libxkbcommon.so` are not installed next to the
// runtime `*.so.0`, so the final link can fail with
// `unable to find library -lpixman-1` / `-lxkbcommon`.
//
// The runtime objects are sufficient to link against (the dynamic loader
// resolves the recorded SONAME at run time from the default search path), so
// when a dev symlink is missing we create one in OUT_DIR pointing at the
// runtime lib and add OUT_DIR to the native link search path. This lets
// `cargo build/run` work on the host without setting
// LIBRARY_PATH or installing a full development SDK. Hosts that already ship
// the dev packages are unaffected: the symlink is only created when the dev
// file is absent, and an extra search path entry is harmless.
fn main() {
    #[cfg(target_os = "linux")]
    {
        let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR is set by cargo");
        let out = std::path::Path::new(&out_dir);
        let _ = std::fs::create_dir_all(out);

        let dirs = ["/usr/lib64", "/usr/lib", "/usr/lib/x86_64-linux-gnu"];
        for name in ["pixman-1", "xkbcommon"] {
            let dev = out.join(format!("lib{name}.so"));
            if dev.exists() {
                continue;
            }
            for dir in dirs {
                let runtime = std::path::Path::new(dir).join(format!("lib{name}.so.0"));
                if runtime.exists() {
                    // Absolute target so the symlink resolves regardless of cwd.
                    let _ = std::os::unix::fs::symlink(&runtime, &dev);
                    break;
                }
            }
        }

        // Only advertise OUT_DIR as a search path if we actually placed a
        // symlink there, keeping the link line clean for builds that don't need
        // these libs.
        if out.join("libpixman-1.so").exists() || out.join("libxkbcommon.so").exists() {
            println!("cargo:rustc-link-search=native={out_dir}");
        }
        println!("cargo:rerun-if-changed=build.rs");
    }
}
