use super::page_allocation::{self, OwnedPhysicalPage, ReservePageError};
use super::paging::{PageTable, PageTableEntry, PageTableData, align_to_page};
use core::mem::transmute;
use core::task::Poll;

#[derive(Debug)]
pub struct UnmapMemTask {
    current_address: usize,
    pages_left: usize,
    pages_freed: usize,
}

impl UnmapMemTask {
    pub fn new(start_address: usize, num_pages: usize) -> Self {
        Self {
            current_address: start_address,
            pages_left: num_pages,
            pages_freed: 0,
        }
    }

    /// If this completes, returns the total number of pages freed.
    pub fn run<F>(&mut self, mapper: &mut UserPageMapper, mut should_suspend: F) -> Poll<usize>
    where
        F: FnMut() -> bool,
    {
        loop {
            if should_suspend() {
                return Poll::Pending;
            }
            // Calculate how many parent page tables to check for freeing.
            let page_address = self.current_address;
            let next_page_address = page_address + 4096;
            let free_table_check_depth = match self.pages_left == 0 {
                true => 3,
                false => 'blk: {
                    for (i, level_mask) in UserPageMapper::LEVEL_MASKS.iter().enumerate() {
                        if page_address & level_mask != next_page_address & level_mask {
                            break 'blk 4 - i;
                        }
                    }
                    0
                }
            };
            // Unmap the page.
            self.pages_freed += mapper.unmap_page(page_address, free_table_check_depth);
            // Advance.
            self.current_address = next_page_address;
            self.pages_left -= 1;
            if self.pages_left == 0 {
                return Poll::Ready(self.pages_freed);
            }
        }
    }
}


#[derive(Debug)]
pub struct MapMemTask {
    start_address: usize,
    current_address: usize,
    pages_allocated: usize,
    state: MapMemState,
}

#[derive(Clone, Copy, Debug)]
enum MapMemState {
    Mapping { pages_left: usize, flags: PageTableEntry },
    FailRewinding { error: MapMemError },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum MapMemError {
    #[error("out of memory")]
    OutOfMemory,
}

impl MapMemTask {
    pub fn new(start_address: usize, num_pages: usize, flags: crate::vma::SegmentFlags) -> Self {
        Self {
            start_address,
            current_address: start_address,
            pages_allocated: 0,
            state: MapMemState::Mapping {
                pages_left: num_pages,
                flags: PageTableEntry::from_data(PageTableData {
                    user_accessable: flags.read,
                    writable: flags.write,
                    no_execute: !flags.execute,
                    ..Default::default()
                })
            },
        }
    }

    pub fn start_address(&self) -> usize {
        self.start_address
    }

    /// If this completes successfully, returns the total number of pages allocated.
    /// If this fails, it cleans up all intermediate allocated pages.
    /// Panics if the task encounters a user page already mapped within the range.
    pub fn run<F>(&mut self, mapper: &mut UserPageMapper, mut should_suspend: F) -> Poll<Result<usize, MapMemError>>
    where
        F: FnMut() -> bool,
    {
        loop {
            if should_suspend() {
                return Poll::Pending;
            }
            match &mut self.state {
                MapMemState::Mapping { pages_left, flags } => {
                    // Calculate how many parent page tables to check for freeing, unmap page
                    let page_address = self.current_address;
                    let next_page_address = page_address + 4096;
                    match mapper.map_blank_page(
                        page_address,
                        *flags,
                        &mut self.pages_allocated,
                    ) {
                        Ok(()) => {}
                        Err(UserPageMapperError::OutOfMemory) => {
                            self.current_address = page_address.saturating_sub(4096);
                            self.state = MapMemState::FailRewinding {
                                error: MapMemError::OutOfMemory,
                            };
                            continue;
                        }
                        Err(err @ UserPageMapperError::PageAlreadyExists) => {
                            panic!("MapMemTask error - {err}");
                        }
                    }
                    // Advance.
                    self.current_address = next_page_address;
                    *pages_left -= 1;
                    if *pages_left == 0 {
                        return Poll::Ready(Ok(self.pages_allocated));
                    }
                }
                MapMemState::FailRewinding { error } => {
                    // Calculate how many parent page tables to check for freeing.
                    let page_address = self.current_address;
                    let next_page_address = page_address.saturating_sub(4096);
                    let free_table_check_depth = match page_address == self.start_address {
                        true => 3,
                        false => 'blk: {
                            for (i, level_mask) in UserPageMapper::LEVEL_MASKS.iter().enumerate() {
                                if page_address & level_mask != next_page_address & level_mask {
                                    break 'blk 4 - i;
                                }
                            }
                            0
                        }
                    };
                    // Unmap the page.
                    self.pages_allocated -= mapper.unmap_page(page_address, free_table_check_depth);
                    // Advance.
                    self.current_address = next_page_address;
                    if page_address == self.start_address {
                        debug_assert_eq!(self.pages_allocated, 0);
                        return Poll::Ready(Err(*error));
                    }
                }
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum UserPageMapperError {
    #[error("user page already exists")]
    PageAlreadyExists,
    #[error("out of memory")]
    OutOfMemory,
}

pub struct UserPageMapper {
    pml4: OwnedPhysicalPage,
}

impl UserPageMapper {
    const LEVEL_MASKS: [usize; 4] = [
        0xFF80_0000_0000,
        0x007F_C000_0000,
        0x0000_3FE0_0000,
        0x0000_001F_F000,
    ];

    pub fn new() -> Result<Self, ReservePageError> {
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

    /// Maps a new page to virtual memory at `virtual_address` aligned down to the nearest
    /// page, including any required parent pages. Page will be zeroed out. Generated parent pages
    /// are set to read/write/execute. Child page flags will be set to `flags`.
    /// Does not do any page invalidation, so the address space must not be in use.
    pub fn map_blank_page(
        &mut self,
        virtual_address: usize,
        flags: PageTableEntry,
        pages_used: &mut usize,
    ) -> Result<(), UserPageMapperError> {
        const PARENT_FLAGS: PageTableEntry = PageTableEntry::READ_WRITE_EXECUTE;
        let child_flags = (flags.0 & 0x8000_0000_0000_0007) | 5;
        // Store any parent pages created for cleanup if an error occurs
        let mut parent_pages_created: [Option<usize>; 3] = [None; 3];
        let result: Result<(), UserPageMapperError> = 'blk: {
            let mut current_address = self.pml4.as_mut() as *mut [u8; 4096] as usize;
            for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
                let current_table = current_address as *mut PageTable;
                let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
                let entry = unsafe { &mut (&mut *current_table)[index] };
                // Allocate page if required
                if !entry.present() {
                    *pages_used += 1;
                    // Allocate and zero out page
                    let new_page = match page_allocation::find_and_reserve_page() {
                        Ok(page) => page.into_raw(),
                        Err(ReservePageError) => break 'blk Err(UserPageMapperError::OutOfMemory),
                    };
                    unsafe { (&mut *new_page).fill(0) };
                    // If parent page, add to cleanup list
                    if i < 3 {
                        parent_pages_created[i] = Some(new_page as usize);
                    }
                    // Set entry to new page table
                    let stripped_address = new_page as u64 & 0x000FFFFFFFFFF000;
                    let new_entry = stripped_address
                        | match i < 3 {
                            true => PARENT_FLAGS.0,
                            false => child_flags,
                        };
                    *entry = PageTableEntry(new_entry);
                } else if i == 3 {
                    return Err(UserPageMapperError::PageAlreadyExists);
                }
                current_address = entry.address();
            }
            Ok(())
        };
        // Cleanup created parent pages if an error occurred
        if result.is_err() {
            for page in parent_pages_created.iter().filter_map(|x| *x) {
                page_allocation::free_page(page);
                *pages_used -= 1;
            }
        }
        result
    }

    /// Unmaps and frees a page at `virtual_address` aligned down to the nearest page.
    /// Also checks `free_table_check_depth` (up to 4) number of parent page tables for if they're
    /// empty and able to be freed.
    /// Returns the number of pages freed.
    #[must_use]
    pub fn unmap_page(&mut self, virtual_address: usize, free_table_check_depth: usize) -> usize {
        let virtual_address = virtual_address & 0x000FFFFFFFFFF000;
        // Collect table addresses as we go down
        let mut table_addresses: [(usize, usize); 4] = [(0, 0); 4];
        // Recurse through page table, free page
        let mut current_address = self.pml4.as_mut() as *mut [u8; 4096] as usize;
        for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
            let current_table = current_address as *mut PageTable;
            let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
            table_addresses[i] = (index, current_address);
            let entry = unsafe { &mut (&mut *current_table)[index] };
            debug_assert!(!entry.huge_page());
            if !entry.present() {
                return 0;
            }
            current_address = entry.address();
        }
        // Work backwards from PT for up to `free_table_check_depth` number of tables. If table is
        // empty, free page and check next table.
        // We always free the child entry to unmap the actual target page.
        let mut pages_freed = 0;
        for (tables_checked, (prev_table_index, table_addr)) in table_addresses.iter().copied().rev().enumerate() {
            let table = unsafe { &mut *(table_addr as *mut PageTable) };
            // Previous table was empty, free it and clear entry
            let page_address = table[prev_table_index].address();
            table[prev_table_index] = PageTableEntry::ZERO;
            // TODO: For multicore, we need to send an IPI to any other cores running threads in
            // this process to tell them to invalidate the page. This needs to happen after zeroing
            // out the entry, but before freeing the page.
            page_allocation::free_page(page_address);
            pages_freed += 1;
            if tables_checked >= free_table_check_depth {
                break;
            }
            // Check if current table is empty, continue if true
            for entry in table {
                if *entry != PageTableEntry::ZERO {
                    break;
                }
            }
        }
        pages_freed
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
    ) -> Result<(), ReservePageError> {
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
                if !entry.present() {
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

    /// Unmaps and frees `(size / 4096) + 1` pages starting at the given linear address.
    pub fn unmap_mem(&mut self, start_address: usize, size: usize) {
        // TODO: Cleanup parent page table pages, keep number of used pages somewhere in page table?
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

    /// Sets the flags of `(size / 4096) + 1` child pages starting at the given linear address.
    /// Relaxes permissions for parent pages where necessary.
    pub fn change_flags(&mut self, start_address: usize, size: usize, flags: PageTableEntry) {
        // TODO: Optimize by keeping count of number of pages done, stay at deepest level.
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

    /// Relaxes the flags of `(size / 4096) + 1` child pages starting at the given linear address.
    /// Also relaxes permissions for parent pages where necessary.
    pub fn change_flags_relaxing(
        &mut self,
        start_address: usize,
        size: usize,
        flags: PageTableEntry,
    ) {
        // TODO: Optimize by keeping count of number of pages done, stay at deepest level.
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

    unsafe fn free_page_tree(node: PageTableEntry, level: usize) {
        unsafe {
            if !node.present() {
                return;
            }
            // TODO: Add huge page support.
            if node.huge_page() {
                todo!("huge page support")
            }
            if level < 3 {
                let page_table = &mut *(node.address() as *mut PageTable);
                for entry in page_table {
                    if entry.present() {
                        Self::free_page_tree(*entry, level + 1);
                    }
                }
            }
            page_allocation::free_page(node.address());
        }
    }
}

impl Drop for UserPageMapper {
    fn drop(&mut self) {
        unsafe {
            let node = transmute::<&[u8; 4096], &PageTable>(&self.pml4);
            for entry in &node[0..256] {
                if entry.present() {
                    Self::free_page_tree(*entry, 0);
                }
            }
        }
    }
}
