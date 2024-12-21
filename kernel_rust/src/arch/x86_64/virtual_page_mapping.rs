use super::page_allocation::{self, OwnedPhysicalPage};
use super::paging::{align_to_page, PageTable, PageTableEntry};
use core::mem::transmute;

pub struct VirtualPageMapper {
    pml4: OwnedPhysicalPage,
}

impl VirtualPageMapper {
    const LEVEL_MASKS: [usize; 4] = [
        0xFF80_0000_0000,
        0x007F_C000_0000,
        0x0000_3FE0_0000,
        0x0000_001F_F000,
    ];

    pub fn new() -> Result<Self, ()> {
        // Create new PML4
        let mut pml4 = page_allocation::find_and_reserve_page()?;
        let pml4_table = unsafe { transmute::<&mut [u8; 4096], &mut PageTable>(&mut pml4) };
        // Clear first half
        pml4_table[0..256].fill(PageTableEntry::ZERO);
        // Fill second half with kernel pages
        let kernel_pml4 = unsafe { &*(page_allocation::page_table_address() as *const PageTable) };
        pml4_table[256..512].copy_from_slice(kernel_pml4);
        // Return new empty lower half page mapper
        Ok(Self { pml4 })
    }

    /// Maps `(size / 4096) + 1` free pages to virtual memory at start address. Fills pages with
    /// data from provided buffer. Memory past buffer length is zeroed. Generated child entries are
    /// set to be only readable, generated parent entries are set to be read/write/execute. Flags
    /// for already existing parent pages are preserved.
    pub fn map_mem_copy_from_buffer(
        &mut self,
        virtual_start_address: usize,
        size: usize,
        buffer: &[u8],
    ) -> Result<(), ()> {
        const PARENT_FLAGS: PageTableEntry = PageTableEntry::READ_WRITE_EXECUTE;
        const CHILD_FLAGS: PageTableEntry = PageTableEntry::READ;
        let pml4_address = self.pml4.as_mut() as *mut [u8; 4096] as usize;
        let num_pages = {
            let lower_bound = align_to_page(virtual_start_address);
            let upper_bound = align_to_page(virtual_start_address + (size - 1));
            ((upper_bound - lower_bound) >> 12) + 1
        };
        let mut start_offset = virtual_start_address & 0xFFF;
        let mut data_written = 0;
        for page_i in 0..num_pages {
            let virtual_address = virtual_start_address + (page_i << 12);
            let mut current_address = pml4_address;
            for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
                let current_table = current_address as *mut PageTable;
                let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
                let entry = unsafe { &mut (&mut *current_table)[index] };
                // Allocate page if required
                if i < 3 {
                    // Allocate parent entry
                    let new_page = page_allocation::find_and_reserve_page()?.into_raw();
                    let new_page_ref = unsafe { &mut *new_page };
                    // Zero out page
                    new_page_ref.fill(0);
                    // Set entry to new page table
                    let stripped_address = new_page as u64 & 0x000FFFFFFFFFF000;
                    let new_entry = stripped_address | PARENT_FLAGS.0;
                    *entry = PageTableEntry(new_entry);
                } else {
                    // Allocate new child page
                    let new_page = page_allocation::find_and_reserve_page()?.into_raw();
                    // Set entry to child page
                    let stripped_address = new_page as u64 & 0x000FFFFFFFFFF000;
                    let new_entry = stripped_address | CHILD_FLAGS.0;
                    *entry = PageTableEntry(new_entry);
                }
                if i == 3 {
                    // Write buffer data to page
                    let data_to_write =
                        usize::min(buffer.len() - data_written, 4096 - start_offset);
                    let write_page = unsafe { &mut *(entry.address() as *mut [u8; 4096]) };
                    write_page[start_offset..][0..data_to_write]
                        .copy_from_slice(&buffer[data_written..]);
                    // Zero out rest of page
                    write_page[start_offset + data_to_write..].fill(0);
                    // Record amount of data written, reset offset
                    data_written += data_to_write;
                    start_offset = 0;
                }
                current_address = entry.address();
            }
        }
        Ok(())
    }

    // TODO Cleanup parent page table pages, keep number of used pages somewhere in page table?
    /// Unmaps and frees `(size / 4096) + 1` pages starting at the given linear address.
    pub fn unmap_mem(&mut self, start_address: usize, size: usize) {
        let pml4_address = self.pml4.as_mut() as *mut [u8; 4096] as usize;
        let actual_start_address = start_address & 0x000FFFFFFFFFF000;
        let num_pages = {
            let lower_bound = align_to_page(start_address);
            let upper_bound = align_to_page(start_address + (size - 1));
            ((upper_bound - lower_bound) >> 12) + 1
        };
        'outer: for page_i in 0..num_pages {
            let virtual_address = actual_start_address + (page_i << 12);
            let mut current_address = pml4_address;
            for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
                let current_table = current_address as *mut PageTable;
                let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
                let entry = unsafe { &mut (&mut *current_table)[index] };
                debug_assert!(!entry.huge_page());
                // Allocate page if required
                if i == 3 {
                    if !entry.present() {
                        continue 'outer;
                    }
                    // Free page, remove entry
                    page_allocation::free_page(entry.address());
                    *entry = PageTableEntry::ZERO;
                } else {
                    current_address = entry.address();
                }
            }
        }
    }

    // TODO Optimize by keeping count of number of pages done, stay at deepest level
    /// Sets the flags of `(size / 4096) + 1` child pages starting at the given linear address.
    /// Relaxes permissions for parent pages where necessary.
    pub fn change_flags(&mut self, start_address: usize, size: usize, flags: PageTableEntry) {
        let pml4_address = self.pml4.as_mut() as *mut [u8; 4096] as usize;
        let actual_start_address = start_address & 0x000FFFFFFFFFF000;
        let actual_flags = (flags.0 & 0x80000000000001FE) | 1;
        let num_pages = {
            let lower_bound = align_to_page(start_address);
            let upper_bound = align_to_page(start_address + (size - 1));
            ((upper_bound - lower_bound) >> 12) + 1
        };
        'outer: for page_i in 0..num_pages {
            let virtual_address = actual_start_address + (page_i << 12);
            let mut current_address = pml4_address;
            for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
                let current_table = current_address as *mut PageTable;
                let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
                let entry = unsafe { &mut (&mut *current_table)[index] };
                debug_assert!(!entry.huge_page());
                // Allocate page if required
                if i == 3 {
                    if !entry.present() {
                        continue 'outer;
                    }
                    *entry = PageTableEntry(entry.address() as u64 | actual_flags);
                } else {
                    current_address = entry.address();
                }
            }
        }
    }

    // TODO Optimize by keeping count of number of pages done, stay at deepest level
    /// Relaxes the flags of `(size / 4096) + 1` child pages starting at the given linear address.
    /// Also relaxes permissions for parent pages where necessary.
    pub fn change_flags_relaxing(
        &mut self,
        start_address: usize,
        size: usize,
        flags: PageTableEntry,
    ) {
        let pml4_address = self.pml4.as_mut() as *mut [u8; 4096] as usize;
        let actual_start_address = start_address & 0x000FFFFFFFFFF000;
        let relaxation_flags = (flags.0 & 0x6) | 1;
        let no_execute_mask = match flags.0 & (1 << 63) == 0 {
            true => !(1 << 63),
            false => !0,
        };
        let num_pages = {
            let lower_bound = align_to_page(start_address);
            let upper_bound = align_to_page(start_address + (size - 1));
            ((upper_bound - lower_bound) >> 12) + 1
        };
        'outer: for page_i in 0..num_pages {
            let virtual_address = actual_start_address + (page_i << 12);
            let mut current_address = pml4_address;
            for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
                let current_table = current_address as *mut PageTable;
                let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
                let entry = unsafe { &mut (&mut *current_table)[index] };
                debug_assert!(!entry.huge_page());
                // Allocate page if required
                if i == 3 {
                    if !entry.present() {
                        continue 'outer;
                    }
                    *entry = PageTableEntry(
                        (entry.address() as u64 | relaxation_flags) & no_execute_mask,
                    );
                } else {
                    current_address = entry.address();
                }
            }
        }
    }

    unsafe fn free_page_tree(&mut self, node: PageTableEntry, level: usize) {
        if !node.present() {
            return;
        }
        // TODO Add huge page support
        if node.huge_page() {
            todo!()
        }
        if level < 3 {
            let page_table = &mut *(node.address() as *mut PageTable);
            for entry in page_table {
                if entry.present() {
                    self.free_page_tree(*entry, level + 1);
                }
            }
        }
        page_allocation::free_page(node.address());
    }
}

impl Drop for VirtualPageMapper {
    fn drop(&mut self) {
        unsafe {
            let node = transmute::<&[u8; 4096], &PageTable>(&self.pml4);
            for entry in &node[0..256] {
                if entry.present() {
                    self.free_page_tree(*entry, 0);
                }
            }
        }
    }
}
