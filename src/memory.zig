const builtin = @import("builtin");

const MallocTrim = if (trim_supported)
    @extern(?*const fn (pad: usize) c_int, .{
        .name = "malloc_trim",
        .linkage = .weak,
    })
else
    null;

const trim_supported = builtin.link_libc and builtin.os.tag == .linux and
    builtin.mode != .debug;

pub fn trimReleasedHeap() void {
    if (!trim_supported) return;
    if (MallocTrim) |f| _ = f(0);
}
