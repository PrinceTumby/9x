//! Implementation of x86_64 page tables.

pub const PAGE_SIZE: usize = 4096;

/// Aligns `address` down to the nearest page boundary.
#[inline]
pub fn align_to_page(address: usize) -> usize {
    return address & !0xFFF;
}

pub type PageTable = [PageTableEntry; 512];

bitfield::bitfield! {
    #[derive(Clone, Copy, PartialEq, Eq)]
    #[repr(transparent)]
    pub struct PageTableEntry(u64);
    impl Debug;
    pub present, _: 0;
    pub writable, _: 1;
    pub user_accessable, _: 2;
    pub write_through_caching_enabled, _: 3;
    pub cache_disabled, _: 4;
    pub accessed, _: 5;
    pub dirty, _: 6;
    pub huge_page, _: 7;
    pub global, _: 8;
    pub no_execute, _: 63;
    address_unextended, _: 51, 12;
    kernel_data_1, _: 11, 9;
    kernel_data_2, _: 58, 52;
}

impl PageTableEntry {
    pub const ZERO: Self = Self(0);
    pub const READ: Self = Self::from_data(PageTableData {
        present: true,
        writable: false,
        user_accessable: false,
        write_through_caching_enabled: false,
        cache_disabled: false,
        accessed: false,
        dirty: false,
        huge_page: false,
        global: false,
        physical_address: 0,
        no_execute: true,
    });
    pub const READ_WRITE: Self = Self::from_data(PageTableData {
        present: true,
        writable: true,
        user_accessable: false,
        write_through_caching_enabled: false,
        cache_disabled: false,
        accessed: false,
        dirty: false,
        huge_page: false,
        global: false,
        physical_address: 0,
        no_execute: true,
    });
    pub const READ_EXECUTE: Self = Self::from_data(PageTableData {
        present: true,
        writable: false,
        user_accessable: false,
        write_through_caching_enabled: false,
        cache_disabled: false,
        accessed: false,
        dirty: false,
        huge_page: false,
        global: false,
        physical_address: 0,
        no_execute: false,
    });
    pub const READ_WRITE_EXECUTE: Self = Self::from_data(PageTableData {
        present: true,
        writable: true,
        user_accessable: false,
        write_through_caching_enabled: false,
        cache_disabled: false,
        accessed: false,
        dirty: false,
        huge_page: false,
        global: false,
        physical_address: 0,
        no_execute: false,
    });

    pub const fn from_data(data: PageTableData) -> Self {
        Self(
            data.present as u64
                | (data.writable as u64) << 1
                | (data.user_accessable as u64) << 2
                | (data.write_through_caching_enabled as u64) << 3
                | (data.cache_disabled as u64) << 4
                | (data.accessed as u64) << 5
                | (data.dirty as u64) << 6
                | (data.huge_page as u64) << 7
                | (data.global as u64) << 8
                | (data.no_execute as u64) << 63
                | (data.physical_address as u64 & 0x000FFFFFFFFFF000),
        )
    }

    pub fn address(&self) -> usize {
        let addr_unextended = self.address_unextended() << 12;
        if addr_unextended & 0x0008000000000000 != 0 {
            addr_unextended as usize | 0xFFF0000000000000
        } else {
            addr_unextended as usize
        }
    }

    #[must_use]
    pub const fn replace_flags_with(&self, flags: PageTableEntry) -> Self {
        let raw_address = self.0 & 0x000FFFFFFFFFF000;
        let raw_flags = flags.0 & 0x80000000000001FF;
        Self(raw_address | raw_flags)
    }

    #[must_use]
    pub const fn replace_addr_with(&self, addr: usize) -> Self {
        let stripped_address = addr as u64 & 0x000FFFFFFFFFF000;
        let raw_flags = self.0 & 0x80000000000001FF;
        Self(stripped_address | raw_flags)
    }
}

impl From<PageTableData> for PageTableEntry {
    fn from(data: PageTableData) -> Self {
        Self::from_data(data)
    }
}

impl Default for PageTableEntry {
    fn default() -> Self {
        Self::from(PageTableData::default())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PageTableData {
    pub present: bool,
    pub writable: bool,
    pub user_accessable: bool,
    pub write_through_caching_enabled: bool,
    pub cache_disabled: bool,
    pub accessed: bool,
    pub dirty: bool,
    pub huge_page: bool,
    pub global: bool,
    pub physical_address: usize,
    pub no_execute: bool,
}

impl Default for PageTableData {
    fn default() -> Self {
        Self {
            present: true,
            writable: false,
            user_accessable: false,
            write_through_caching_enabled: false,
            cache_disabled: false,
            accessed: false,
            dirty: false,
            huge_page: false,
            global: false,
            physical_address: 0,
            no_execute: false,
        }
    }
}
