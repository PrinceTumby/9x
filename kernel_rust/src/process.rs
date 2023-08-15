//! User and kernel processes, as well as scheduling.

use crate::arch;
use crate::physical_block_allocator::{PageBox, PhysicalBlockAllocator};
use core::marker::PhantomData;
use core::ptr::NonNull;
use spin::Mutex;

/// Pending processes, implemented as a doubly linked list
pub mod process_list {
    use super::{Mutex, NonNull, PageBox, PhantomData, PhysicalBlockAllocator, Process};

    static PENDING_PROCESSES: Mutex<ProcessList> = Mutex::new(ProcessList {
        head: None,
        tail: None,
        marker: PhantomData,
    });

    struct ProcessList {
        head: Option<NonNull<Process>>,
        tail: Option<NonNull<Process>>,
        marker: PhantomData<PageBox<Process>>,
    }

    unsafe impl Send for ProcessList {}

    /// Pushes a process onto the list.
    #[inline]
    pub fn push_back(process: PageBox<Process>) {
        unsafe {
            debug_assert_eq!(process.next, None);
            let mut list = PENDING_PROCESSES.lock();
            let process_ptr = NonNull::new_unchecked(PageBox::into_raw(process));
            if let Some(tail) = list.tail.as_mut().map(|ptr| ptr.as_mut()) {
                debug_assert_eq!(tail.next, None);
                tail.next = Some(process_ptr);
            }
            list.tail = Some(process_ptr);
        }
    }

    /// Pops the process from the front of the list, returning it.
    #[inline]
    pub fn pop_front() -> Option<PageBox<Process>> {
        unsafe {
            let mut list = PENDING_PROCESSES.lock();
            if let Some(head) = list.head.as_mut() {
                let return_process = PageBox::from_raw_in(head.as_ptr(), PhysicalBlockAllocator);
                list.head = return_process.next;
                Some(return_process)
            } else {
                None
            }
        }
    }
}

pub struct Process {
    pub next: Option<NonNull<Process>>,
    pub registers: arch::process::RegisterStore,
}
