use core::arch::x86_64::{CpuidResult, __cpuid};

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct CpuidInfo {
    // 0h
    pub cpu_vendor_id: [u8; 12],
    // 0000_0001h
    pub local_apic_timer_tsc_deadline: bool,
    // 8000_0002h ... 8000_0004h
    pub brand_string_bytes: Option<[u8; 48]>,
    // 8000_0007h
    pub invariant_tsc: bool,
}

static mut CPUID_INFO: Option<CpuidInfo> = None;

/// Populates internal information with calls to CPUID. Caller guarantees no references exist to
/// CPUID_INFO, and that no other thread is accessing CPU_ID.
pub unsafe fn generate_info() {
    // Supported levels and CPU Vendor ID
    let (standard_maximum_level, cpu_vendor_id) = {
        let regs = __cpuid(0);
        let ebx_bytes = regs.ebx.to_le_bytes();
        let edx_bytes = regs.edx.to_le_bytes();
        let ecx_bytes = regs.ecx.to_le_bytes();
        let cpu_vendor_id: [u8; 12] = core::mem::transmute([ebx_bytes, edx_bytes, ecx_bytes]);
        (regs.eax, cpu_vendor_id)
    };
    let extended_maximum_level = __cpuid(0x8000_0000).eax;
    // TSC Deadline Mode Supported
    let local_apic_timer_tsc_deadline =
        standard_maximum_level >= 1 && __cpuid(1).ecx & 0x100_0000 != 0;
    // Brand String
    let brand_string_bytes = match extended_maximum_level >= 0x8000_0004 {
        true => {
            let mut bytes = [0u8; 48];
            bytes[0..16].copy_from_slice(&cpuid_result_to_le_bytes(__cpuid(0x8000_0002)));
            bytes[16..32].copy_from_slice(&cpuid_result_to_le_bytes(__cpuid(0x8000_0002)));
            bytes[32..48].copy_from_slice(&cpuid_result_to_le_bytes(__cpuid(0x8000_0003)));
            Some(bytes)
        }
        false => None,
    };
    // Has Invariant TSC
    let invariant_tsc =
        extended_maximum_level >= 0x8000_0007 && __cpuid(0x8000_0007).edx & 0x100 != 0;
    // Populate
    CPUID_INFO = Some(CpuidInfo {
        cpu_vendor_id,
        local_apic_timer_tsc_deadline,
        brand_string_bytes,
        invariant_tsc,
    });
}

pub fn get_info() -> &'static CpuidInfo {
    unsafe { CPUID_INFO.as_ref().unwrap() }
}

fn cpuid_result_to_le_bytes(regs: CpuidResult) -> [u8; 16] {
    unsafe {
        core::mem::transmute([
            regs.eax.to_le_bytes(),
            regs.ebx.to_le_bytes(),
            regs.ecx.to_le_bytes(),
            regs.edx.to_le_bytes(),
        ])
    }
}
