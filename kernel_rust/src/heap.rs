use crate::arch::page_allocation;
use crate::arch::paging::{align_to_page, PageTableEntry, PAGE_SIZE};
use bitfield::bitfield;
use core::alloc::{GlobalAlloc, Layout};
use core::iter::Iterator;
use core::mem::{align_of, size_of};
use core::ptr::{self, NonNull};
use spin::Mutex;

#[cfg(target_pointer_width = "64")]
bitfield! {
    #[repr(transparent)]
    struct Block(u64);
    len_internal, set_len_internal: 61, 0;
    pub used, set_used: 62;
    pub has_next, set_has_next: 63;
}

impl Block {
    #[cfg(target_pointer_width = "64")]
    const LEN_MASK: u64 = 0x3FFF_FFFF_FFFF_FFFF;
    #[cfg(target_pointer_width = "32")]
    const LEN_MASK: u32 = 0x3FFF_FFFF;

    #[cfg(target_pointer_width = "64")]
    pub fn new(len: usize, used: bool, has_next: bool) -> Self {
        Self(len as u64 & Self::LEN_MASK | (used as u64) << 62 | (has_next as u64) << 63)
    }

    #[cfg(target_pointer_width = "32")]
    pub fn new(len: usize, used: bool, has_next: bool) -> Self {
        Self(len as u32 & Self::LEN_MASK | (used as u32) << 30 | (has_next as u32) << 31)
    }

    pub fn len(&self) -> usize {
        self.len_internal() as usize
    }

    pub fn set_len(&mut self, value: usize) {
        #[cfg(target_pointer_width = "64")]
        self.set_len_internal(value as u64);
        #[cfg(target_pointer_width = "32")]
        self.set_len_internal(value as u32);
    }

    /// Returns the start address of the inner block.
    pub fn start_address(&self) -> usize {
        self as *const Self as usize + size_of::<Self>()
    }

    pub unsafe fn get_next(&self) -> Option<NonNull<Self>> {
        if !self.has_next() {
            return None;
        }
        let address = self as *const Self as usize + size_of::<Self>() + self.len();
        Some(NonNull::new(address as *mut Self).unwrap_unchecked())
    }

    pub unsafe fn iter_mut(&mut self) -> BlockIterator {
        BlockIterator {
            current_block: Some(NonNull::from(self)),
        }
    }
}

struct BlockIterator {
    current_block: Option<NonNull<Block>>,
}

impl Iterator for BlockIterator {
    type Item = NonNull<Block>;

    fn next(&mut self) -> Option<Self::Item> {
        unsafe {
            let current_block = self.current_block?;
            self.current_block = current_block.as_ref().get_next();
            Some(current_block)
        }
    }
}

const PAGE_FLAGS: PageTableEntry = PageTableEntry::READ_WRITE;

struct KernelHeapAllocator {
    pub list_head: Mutex<Option<NonNull<Block>>>,
}

unsafe impl Sync for KernelHeapAllocator {}

unsafe impl GlobalAlloc for KernelHeapAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let maybe_list_head_lock = self.list_head.lock();
        let Some(list_head) = maybe_list_head_lock.map(|mut ptr| ptr.as_mut()) else {
            return ptr::null_mut();
        };
        // Scan through list to find free space large enough
        for mut current_block_ptr in list_head.iter_mut() {
            let current_block = current_block_ptr.as_mut();
            if current_block.used() {
                continue;
            }
            let unaligned_start_addr = current_block.start_address();
            let start_addr = unaligned_start_addr.next_multiple_of(layout.align());
            let max_addr = unaligned_start_addr + (current_block.len() - 1);
            let end_addr = start_addr + (layout.size() - 1);
            if end_addr > max_addr {
                continue;
            }
            // Found a suitable block, reserve
            current_block.set_used(true);
            // If enough space, split block into used and free blocks, otherwise keep block as is
            let new_block_addr = (end_addr + 1).next_multiple_of(align_of::<Block>());
            let new_space_start = new_block_addr + size_of::<Block>();
            if new_space_start < max_addr {
                current_block.set_len(new_block_addr - unaligned_start_addr);
                match page_allocation::map_page(new_block_addr, PAGE_FLAGS) {
                    Ok(_) => {}
                    Err(page_allocation::MapPageError::PageAlreadyExists) => {}
                    err @ Err(_) => err.unwrap(),
                }
                *(new_block_addr as *mut Block) = Block::new(
                    max_addr - new_space_start + 1,
                    false,
                    current_block.has_next(),
                );
                current_block.set_has_next(true);
            }
            // Allocate pages
            {
                let start_page = align_to_page(unaligned_start_addr);
                let end_page = align_to_page(end_addr);
                for page in (start_page..=end_page).step_by(PAGE_SIZE) {
                    // FIXME: `PageAlreadyExists` - check against old Zig code
                    match page_allocation::map_page(page, PAGE_FLAGS) {
                        Ok(_) => {}
                        Err(page_allocation::MapPageError::PageAlreadyExists) => {}
                        err @ Err(_) => err.unwrap(),
                    }
                }
            }
            return start_addr as *mut u8;
        }
        // Space not found, return failure
        ptr::null_mut()
    }

    unsafe fn dealloc(&self, ptr: *mut u8, _layout: Layout) {
        let search_addr = ptr as usize;
        let list_head = self.list_head.lock().unwrap().as_mut();
        let mut maybe_previous_block_ptr: Option<NonNull<Block>> = None;
        for mut current_block_ptr in list_head.iter_mut() {
            let current_block = current_block_ptr.as_mut();
            let min_addr = current_block.start_address();
            let max_addr = min_addr + (current_block.len() - 1);
            // Check if block contains allocation
            if min_addr <= search_addr && search_addr <= max_addr {
                // Check for double free in debug mode
                debug_assert!(current_block.used());
                current_block.set_used(false);
                // Free middle pages
                {
                    let start_page = min_addr.next_multiple_of(PAGE_SIZE);
                    let end_page = align_to_page(max_addr);
                    for page in (start_page..end_page).step_by(PAGE_SIZE) {
                        page_allocation::free_page(page);
                    }
                }
                let current_block_page = align_to_page(current_block as *mut Block as usize);
                // Merge forward if next block is free
                match current_block.get_next().map(|mut ptr| ptr.as_mut()) {
                    Some(next_block) if !next_block.used() => 'blk: {
                        let next_block_page = align_to_page(next_block as *mut Block as usize);
                        current_block
                            .set_len(current_block.len() + size_of::<Block>() + next_block.len());
                        current_block.set_has_next(next_block.has_next());
                        // Check if merged block header page can be freed
                        if current_block_page != next_block_page {
                            break 'blk;
                        }
                        let Some(next_next_block_ptr) = next_block.get_next() else {
                            break 'blk;
                        };
                        if align_to_page(next_next_block_ptr.as_ptr() as usize) != next_block_page {
                            page_allocation::unmap_and_free_page(next_block_page);
                        }
                    }
                    _ => {}
                }
                // Merge backward if next block is free
                match maybe_previous_block_ptr.map(|mut ptr| ptr.as_mut()) {
                    Some(previous_block) if !previous_block.used() => 'blk: {
                        if previous_block.used() {
                            break 'blk;
                        }
                        let previous_block_page =
                            align_to_page(previous_block as *mut Block as usize);
                        previous_block.set_len(
                            previous_block.len() + size_of::<Block>() + current_block.len(),
                        );
                        previous_block.set_has_next(current_block.has_next());
                        // Check if merged block header page can be freed
                        if previous_block_page != current_block_page {
                            break 'blk;
                        }
                        let Some(next_block_ptr) = current_block.get_next() else {
                            break 'blk;
                        };
                        if align_to_page(next_block_ptr.as_ptr() as usize) != current_block_page {
                            page_allocation::unmap_and_free_page(current_block_page);
                        }
                    }
                    _ => {}
                }
                return;
            }
            maybe_previous_block_ptr = Some(current_block_ptr);
        }
    }
}

#[global_allocator]
static ALLOCATOR: KernelHeapAllocator = KernelHeapAllocator {
    list_head: Mutex::new(None),
};

/// Initialises an area of virtual memory for use as heap space. The allocator will automatically
/// map pages, so the area should be unmapped.
///
/// # Safety
/// The caller guarantees this function is only called once.
pub unsafe fn init_heap(start_address: usize, length: usize) {
    let new_block_addr = start_address.next_multiple_of(align_of::<Block>());
    page_allocation::map_page(new_block_addr, PAGE_FLAGS).unwrap();
    let new_block_ptr = new_block_addr as *mut Block;
    new_block_ptr.write(Block::new(
        (start_address + length) - new_block_addr - size_of::<Block>(),
        false,
        false,
    ));
    *ALLOCATOR.list_head.lock() = Some(NonNull::new_unchecked(new_block_ptr));
}
