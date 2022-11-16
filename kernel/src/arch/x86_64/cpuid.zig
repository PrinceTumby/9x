const std = @import("std");

const logger = std.log.scoped(.x86_64_cpuid);

// 0h
pub var cpu_vendor_id: [12]u8 = undefined;

// 0000_0001h
pub var local_apic_timer_tsc_deadline = false;

// 8000_0002h ... 8000_0004h
var brand_string_bytes: [48]u8 = undefined;
pub var brand_string: ?[:0]const u8 = null;

// 8000_0007h
pub var invariant_tsc = false;

pub fn populateInfo() void {
    // Supported levels and cpu_vendor_id
    const standard_maximum_level = blk: {
        const regs = cpuid(0);
        cpu_vendor_id = @bitCast([12]u8, [3]u32{ regs.ebx, regs.edx, regs.ecx });
        break :blk regs.eax;
    };
    const extended_maximum_level = cpuid(0x80000000).eax;
    // local_apic_timer_tsc_deadline
    if (standard_maximum_level >= 1) {
        local_apic_timer_tsc_deadline = cpuid(1).ecx & 0x100_0000 != 0;
    }
    // brand_string
    if (extended_maximum_level >= 0x80000004) {
        brand_string_bytes[0..16].* = @bitCast([16]u8, cpuid(0x80000002).asArray());
        brand_string_bytes[16..32].* = @bitCast([16]u8, cpuid(0x80000003).asArray());
        brand_string_bytes[32..48].* = @bitCast([16]u8, cpuid(0x80000004).asArray());
        if (std.mem.indexOfScalar(u8, &brand_string_bytes, 0)) |zero_pos|
            brand_string = brand_string_bytes[0..zero_pos :0];
    }
    // invariant_tsc
    if (extended_maximum_level >= 0x80000007) {
        const flags = cpuid(0x80000007).edx;
        invariant_tsc = flags & 0x100 != 0;
    }
    logger.debug("0x{X}", .{cpuid(1)});
}

const Regs = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,

    pub fn asArray(self: Regs) [4]u32 {
        return [4]u32{ self.eax, self.ebx, self.ecx, self.edx };
    }
};

pub fn cpuid(leaf: u32) Regs {
    var eax: u32 = leaf;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [eax] "{eax}" (eax)
    );
    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}
