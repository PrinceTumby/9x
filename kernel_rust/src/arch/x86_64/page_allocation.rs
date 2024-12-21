//! Provides facilities for allocating physical memory.

use crate::arch::kernel_args::MutSlice;
use crate::arch::paging::{align_to_page, PageTable, PageTableEntry, PAGE_SIZE};
use core::arch::asm;
use core::ops::{Deref, DerefMut};
use core::ptr::NonNull;
use core::marker::PhantomData;
use spin::Mutex;
use thiserror_no_std::Error;

pub type RawPage = [u8; PAGE_SIZE];

static PAGE_ALLOCATOR: Mutex<Option<PageAllocatorInternal>> = Mutex::new(None);

/// Initialises the page allocation system. Does nothing if the page allocation system is already
/// initialised.
pub unsafe fn init(page_table_address: usize, memory_bitmap: &'static mut [u8], num_pages: usize) {
    let mut lock = PAGE_ALLOCATOR.lock();
    if let None = lock.as_mut() {
        lock.replace(PageAllocatorInternal::new(
            page_table_address,
            memory_bitmap,
            num_pages,
        ));
    }
}

pub fn deinit_and_remove() -> Option<PageAllocatorInternal> {
    PAGE_ALLOCATOR.lock().take()
}

#[inline]
pub fn page_table_address() -> usize {
    let lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_ref().unwrap();
    page_allocator.page_table.address()
}

pub fn memory_bitmap() -> MutSlice<u8> {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.memory_bitmap.into()
}

#[inline]
pub fn total_pages() -> usize {
    let lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_ref().unwrap();
    page_allocator.total_pages
}

#[inline]
pub fn free_pages() -> usize {
    let lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_ref().unwrap();
    page_allocator.free_pages
}

#[inline]
pub fn used_pages() -> usize {
    let lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_ref().unwrap();
    page_allocator.total_pages - page_allocator.free_pages
}

/// Attempts to reserve a free page. Returns the physical address if a page is found.
pub fn find_and_reserve_page() -> Result<OwnedPhysicalPage, ()> {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator
        .find_and_reserve_page()
        .map(|ptr| OwnedPhysicalPage::from_non_null(ptr))
}

/// Marks a page as no longer reserved.
/// The caller is expected to no longer use references to this page.
pub fn free_page(address: usize) {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.free_page(address);
}

/// Returns whether whether memory at the given virtual address is identity mapped.
pub unsafe fn is_address_identity_mapped(address: usize) -> bool {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.is_address_identity_mapped(address)
}

pub unsafe fn map_page_translation(
    physical_address: usize,
    virtual_address: usize,
    flags: PageTableEntry,
) -> Result<(), MapPageError> {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.map_page_translation(physical_address, virtual_address, flags)
}

/// Allocates a page at the given virtual address (aligned down, top 16 bits ignored).
/// No flags are applied to already existing pages.
/// Returns whether a page was allocated, if `false` then either reserving a page failed or a page
/// was already found to be mapped at that address.
pub unsafe fn map_page(virtual_address: usize, flags: PageTableEntry) -> Result<(), MapPageError> {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.map_page(virtual_address, flags)
}

/// Unmaps and frees a page at `virtual_address` (aligned down, top 16 bits ignored).
pub unsafe fn unmap_and_free_page(virtual_address: usize) {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.unmap_and_free_page(virtual_address);
}

// TODO Make this work for NX
/// Checks if all of the enabled flags exist on the mapped pages.
/// Returns `false` if some pages do not have the enabled flags or are not mapped.
pub fn check_flags(virtual_start_address: usize, size: usize, flags: PageTableEntry) -> bool {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.check_flags(virtual_start_address, size, flags)
}

/// Switches to the main kernel kernel address space.
pub unsafe fn load_kernel_address_space() {
    let mut lock = PAGE_ALLOCATOR.lock();
    let page_allocator = lock.as_mut().unwrap();
    page_allocator.load_address_space();
}

pub struct OwnedPhysicalPage {
    pointer: NonNull<RawPage>,
    _marker: PhantomData<RawPage>,
}

impl OwnedPhysicalPage {
    #[must_use]
    pub unsafe fn from_raw(raw: *mut RawPage) -> Self {
        Self {
            pointer: NonNull::new_unchecked(raw),
            _marker: PhantomData,
        }
    }

    #[must_use]
    pub fn from_non_null(ptr: NonNull<RawPage>) -> Self {
        Self {
            pointer: ptr,
            _marker: PhantomData,
        }
    }

    #[must_use]
    pub fn into_raw(self) -> *mut RawPage {
        let return_ptr = self.pointer.as_ptr();
        core::mem::forget(self);
        return_ptr
    }
}

impl Drop for OwnedPhysicalPage {
    fn drop(&mut self) {
        let mut lock = PAGE_ALLOCATOR.lock();
        let page_allocator = lock.as_mut().unwrap();
        page_allocator.free_page(self.pointer.as_ptr() as usize)
    }
}

impl Deref for OwnedPhysicalPage {
    type Target = RawPage;

    fn deref(&self) -> &Self::Target {
        unsafe { self.pointer.as_ref() }
    }
}

impl DerefMut for OwnedPhysicalPage {
    fn deref_mut(&mut self) -> &mut Self::Target {
        unsafe { self.pointer.as_mut() }
    }
}

impl AsRef<RawPage> for OwnedPhysicalPage {
    fn as_ref(&self) -> &RawPage {
        &*self
    }
}

impl AsMut<RawPage> for OwnedPhysicalPage {
    fn as_mut(&mut self) -> &mut RawPage {
        &mut *self
    }
}

/// Marks a page as no longer reserved.
/// The caller is expected to no longer use references to this page.

#[derive(Error, Debug)]
pub enum MapPageError {
    #[error("out of pages")]
    OutOfPages,
    #[error("page already exists at address")]
    PageAlreadyExists,
}

// TODO Turn the option types into error types
// TODO Make this thread safe
// TODO Rewrite this with a better scheme for contiguous physical pages
// (has uses with large pages, DMA, etc.)
pub struct PageAllocatorInternal {
    pub memory_bitmap: &'static mut [u8],
    pub total_pages: usize,
    pub free_pages: usize,
    pub page_table: PageTableEntry,
}

impl PageAllocatorInternal {
    const BYTE_RATIO: usize = PAGE_SIZE * 8;
    const LEVEL_MASKS: [usize; 4] = [
        0xFF80_0000_0000,
        0x007F_C000_0000,
        0x0000_3FE0_0000,
        0x0000_001F_F000,
    ];

    pub unsafe fn new(
        page_table_address: usize,
        memory_bitmap: &'static mut [u8],
        num_pages: usize,
    ) -> Self {
        let free_pages = memory_bitmap
            .iter()
            .fold(0, |acc, byte| acc + byte.count_zeros()) as usize;
        Self {
            memory_bitmap,
            total_pages: num_pages,
            free_pages,
            page_table: PageTableEntry::ZERO.replace_addr_with(page_table_address),
        }
    }

    #[inline]
    pub fn num_pages_used(&self) -> usize {
        return self.total_pages - self.free_pages;
    }

    /// Attempts to reserve a free page. Returns the physical address if a page is found.
    pub fn find_and_reserve_page(&mut self) -> Result<NonNull<RawPage>, ()> {
        for (byte_index, byte) in self.memory_bitmap.iter_mut().enumerate() {
            if *byte != 0xFF {
                let bit_index = (!*byte).leading_zeros() as usize;
                *byte |= 0x80 >> bit_index;
                self.free_pages -= 1;
                let addr = (byte_index * Self::BYTE_RATIO) + (bit_index * PAGE_SIZE);
                let page_ptr = addr as *mut RawPage;
                // Clear page
                unsafe {
                    page_ptr.as_mut().unwrap().fill(0);
                }
                return Ok(NonNull::new(page_ptr).unwrap());
            }
        }
        Err(())
    }

    /// Marks a page as no longer reserved.
    /// The caller is expected to no longer use references to this page.
    pub fn free_page(&mut self, address: usize) {
        let byte_index = address / Self::BYTE_RATIO;
        let bit_offset = (address / PAGE_SIZE) % 8;
        if byte_index * 8 + bit_offset >= self.total_pages {
            return;
        }
        self.memory_bitmap[byte_index] &= !(0x80 >> bit_offset);
        self.free_pages += 1;
    }

    pub unsafe fn is_address_identity_mapped(&self, address: usize) -> bool {
        let mut current_address = self.page_table.address();
        for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
            let current_table = current_address as *mut PageTable;
            let index = ((*level_mask & address) >> ((3 - i) * 9 + 12)) % 512;
            let entry = unsafe { (&*current_table)[index] };
            if !entry.present() {
                return false;
            }
            if i == 3 || entry.huge_page() {
                let page_aligned_address = address
                    & match i {
                        0 => 0xFFFF_FF80_C000_0000,
                        1 => 0xFFFF_FFFF_C000_0000,
                        2 => 0xFFFF_FFFF_FFE0_0000,
                        3 => 0xFFFF_FFFF_FFFF_F000,
                        _ => unreachable!(),
                    };
                return page_aligned_address == entry.address();
            }
            current_address = entry.address();
        }
        unreachable!()
    }

    pub unsafe fn map_page_translation(
        &mut self,
        physical_address: usize,
        virtual_address: usize,
        flags: PageTableEntry,
    ) -> Result<(), MapPageError> {
        let physical_address = physical_address & 0x000FFFFFFFFFF000;
        let mut current_address = self.page_table.address();
        for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
            let current_table = current_address as *mut PageTable;
            let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
            let entry = unsafe { &mut (&mut *current_table)[index] };
            // Allocate page if required
            match (i, entry.present()) {
                // Child page already exists, return failure
                (3, true) => return Err(MapPageError::PageAlreadyExists),
                // Child page doesn't exist, map page with flags
                (3, false) => {
                    *entry = flags.replace_addr_with(physical_address);
                    // unsafe {
                    //     asm!("invlpg [{}]", in(reg) new_page_address, options(nostack));
                    // }
                    return Ok(());
                }
                // Parent entry doesn't exist, allocate
                (_, false) => {
                    let Ok(mut new_page_table) = self.find_and_reserve_page() else {
                        return Err(MapPageError::OutOfPages);
                    };
                    // Zero out page table
                    new_page_table.as_mut().fill(0);
                    // Set entry to new page table
                    let new_page_table_addr = new_page_table.as_ptr() as usize & 0x000FFFFFFFFFF000;
                    *entry = PageTableEntry::READ_WRITE.replace_addr_with(new_page_table_addr);
                    // unsafe {
                    //     asm!("invlpg [{}]", in(reg) new_page_table_addr, options(nostack));
                    // }
                }
                (_, true) => {}
            }
            current_address = entry.address();
        }
        unreachable!()
    }

    /// Allocates a page at the given virtual address (aligned down, top 16 bits ignored).
    /// No flags are applied to already existing pages.
    /// Returns whether a page was allocated, if `false` then either reserving a page failed or a
    /// page was already found to be mapped at that address.
    pub unsafe fn map_page(
        &mut self,
        virtual_address: usize,
        flags: PageTableEntry,
    ) -> Result<(), MapPageError> {
        let Ok(new_page) = self.find_and_reserve_page() else {
            return Err(MapPageError::OutOfPages);
        };
        let new_page_address = new_page.as_ptr() as usize;
        if let Err(err) = self.map_page_translation(new_page_address, virtual_address, flags) {
            // Free reserved page if unsuccessful
            self.free_page(new_page_address);
            return Err(err);
        }
        Ok(())
    }

    /// Unmaps and frees a page at `virtual_address` (aligned down, top 16 bits ignored).
    pub unsafe fn unmap_and_free_page(&mut self, virtual_address: usize) {
        let stripped_virtual_address = virtual_address & 0x000FFFFFFFFFF000;
        let mut current_address = self.page_table.address();
        for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
            let current_table = current_address as *mut PageTable;
            let index = ((*level_mask & stripped_virtual_address) >> ((3 - i) * 9 + 12)) % 512;
            let entry = unsafe { &mut (&mut *current_table)[index] };
            if !entry.present() {
                return;
            }
            // Free child page
            if i == 3 {
                let address = entry.address();
                *entry = PageTableEntry::ZERO;
                self.free_page(address);
                return;
            }
            current_address = entry.address();
        }
    }

    // TODO Make this work for NX
    /// Checks if all of the enabled flags exist on the mapped pages.
    /// Returns `false` if some pages do not have the enabled flags or are not mapped.
    pub fn check_flags(
        &self,
        virtual_start_address: usize,
        size: usize,
        flags: PageTableEntry,
    ) -> bool {
        let actual_flags = flags.replace_addr_with(0).0;
        let num_pages = {
            let lower_bound = align_to_page(virtual_start_address);
            let upper_bound = align_to_page(virtual_start_address + (size - 1));
            ((upper_bound - lower_bound) >> 12) + 1
        };
        for page_i in 0..num_pages {
            let virtual_address = virtual_start_address + (page_i << 12);
            let mut current_address = self.page_table.address();
            for (i, level_mask) in Self::LEVEL_MASKS.iter().enumerate() {
                let current_table = current_address as *mut PageTable;
                let index = ((*level_mask & virtual_address) >> ((3 - i) * 9 + 12)) % 512;
                let entry = unsafe { &mut (&mut *current_table)[index] };
                // Check flags
                if !entry.present() || entry.0 & actual_flags != actual_flags {
                    return false;
                }
                current_address = entry.address();
            }
        }
        true
    }

    /// Switches to the page allocator's page table.
    pub unsafe fn load_address_space(&self) {
        asm!("mov cr3, {}", in(reg) self.page_table.0, options(nostack))
    }
}
