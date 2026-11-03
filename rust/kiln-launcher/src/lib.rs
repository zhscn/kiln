//! C `main` for AOT executables. Linked together with an object file
//! produced by `kiln-cg obj`, which defines `kiln_module_info`.

use kiln_rt::ModuleInfo;

unsafe extern "C" {
    static kiln_module_info: ModuleInfo;
}

#[unsafe(no_mangle)]
pub extern "C" fn main(_argc: i32, _argv: *const *const u8) -> i32 {
    unsafe { kiln_rt::run_module(&*core::ptr::addr_of!(kiln_module_info)) }
}
