const builtin = @import("builtin");

const trim_supported = builtin.link_libc and builtin.os.tag == .linux and
    builtin.abi.isGnu() and builtin.mode != .debug;

const glibc = struct {
    extern "c" fn malloc_trim(pad: usize) c_int;
};

pub fn trimReleasedHeap() void {
    if (!trim_supported) return;
    _ = glibc.malloc_trim(0);
}

test "trimReleasedHeap is safe to call" {
    trimReleasedHeap();
}
