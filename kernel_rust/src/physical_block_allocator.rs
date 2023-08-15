use crate::arch::page_allocation::{self, PhysicalPage, RawPage};
use crate::arch::paging::PAGE_SIZE;
use alloc::alloc::{AllocError, Allocator, Layout};
use alloc::boxed::Box;
use alloc::vec::Vec;
use core::mem::size_of;
use core::ptr::NonNull;

pub type PageBox<T> = Box<T, PhysicalBlockAllocator>;
pub type PageVec<T> = Vec<T, PhysicalBlockAllocator>;

/// Allocator for types smaller than or equal in size and alignment to a page.
/// Allocates a page for each allocation.
pub struct PhysicalBlockAllocator;

unsafe impl Allocator for PhysicalBlockAllocator {
    fn allocate(&self, layout: Layout) -> Result<NonNull<[u8]>, AllocError> {
        // debug_assert!(layout.size() <= PAGE_SIZE);
        debug_assert!(layout.align() <= PAGE_SIZE);
        if layout.size() > PAGE_SIZE {
            return Err(AllocError);
        }
        let ptr = page_allocation::find_and_reserve_page().map_err(|_| AllocError)?;
        unsafe { Ok(NonNull::new_unchecked(ptr.into_raw())) }
    }

    unsafe fn deallocate(&self, ptr: NonNull<u8>, _layout: Layout) {
        drop(PhysicalPage::from_raw(ptr.as_ptr() as *mut RawPage));
    }
}

pub trait MaxCapacity {
    fn new_with_max_capacity() -> Self;
}

impl<T> MaxCapacity for PageVec<T> {
    /// Creates a new, empty `PageVec<T>` with the maximum capacity for a page.
    fn new_with_max_capacity() -> Self {
        Self::new_in(PhysicalBlockAllocator);
        Self::with_capacity_in(PAGE_SIZE / size_of::<T>(), PhysicalBlockAllocator)
    }
}
