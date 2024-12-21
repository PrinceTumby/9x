use crate::arch;
use crate::arch::paging::{PageTableData, PAGE_SIZE};
use crate::arch::user_page_mapping::{UnmapMemTask, UserPageMapper};
use crate::physical_block_allocator::{PageBox, PhysicalBlockAllocator};
use core::alloc::AllocError;
use core::cmp::Ordering;
use core::mem::size_of;
use core::ptr::NonNull;
use core::task::Poll;
use memoffset::offset_of;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Segment {
    pub start: usize,
    pub len: usize,
    pub flags: SegmentFlags,
}

// TODO Replace this with a bitfield structure to be taken straight from syscall

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SegmentFlags {
    read: bool,
    write: bool,
    execute: bool,
}

impl From<SegmentFlags> for usize {
    fn from(flags: SegmentFlags) -> Self {
        flags.read as usize | (flags.write as usize) << 1 | (flags.execute as usize) << 2
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VMAAllocationError {
    OutOfPagesLeft,
    OutOfMemory,
    OutOfAddressSpace,
}

pub struct VMAAllocator {
    page_mapper: UserPageMapper,
    node_storage: NodeStorageList,
    tree: VMATree,
}

// TODO: Change pretty much all of this:
// 1. Remove force_map_at, it just isn't needed and complicates the kernel a lot. This then allows
//    for rewriting the state machine to be just scanning and mapping. Also makes things much
//    easier to make atomic whenever multithreaded gets implemented.
// 2. Remove any logic that automatically recombines segments (not sure if there is any).
// 3. Change syscalls that send pages/shipments/whatever to instead send a single segment.
// 4. Add functions for manually unmapping, truncating, extending, splitting, and recombining
//    segments.

impl VMAAllocator {
    pub fn new(page_mapper: UserPageMapper) -> Result<Self, AllocError> {
        Ok(Self {
            page_mapper,
            node_storage: NodeStorageList::new()?,
            tree: VMATree::new(),
        })
    }

    /// Panics if the start and length of `new_segment` are not page aligned, or if the end address
    /// is not less than or equal to `arch::process::HIGHEST_USER_ADDRESS`.
    pub fn start_force_map_at(
        &mut self,
        new_segment: Segment,
        pages_left: &mut Option<&mut u64>,
    ) -> Result<MapTask, AllocError> {
        debug_assert_eq!(new_segment.start % arch::paging::PAGE_SIZE, 0);
        debug_assert_eq!(new_segment.len % arch::paging::PAGE_SIZE, 0);
        let new_segment_end = new_segment.start + new_segment.len - 1;
        debug_assert!(new_segment_end <= arch::process::HIGHEST_USER_ADDRESS);
        // 1. Get information about segment start.
        // 2. If we're in a gap large enough to map the segment, just create a task starting at
        //    PageMapping.
        // 3. If we're in a gap, but not one large enough to map the segment, grab the next node
        //    and create a MappingRemoval task with the pointer to the mapping and the new memory
        //    unmapping task.
        // 4. If we're in a segment, do the same as above just using the mapping we're already
        //    inside.
        let current_mapping = match self.tree.get_area_info(new_segment.start) {
            AddressInfo::Space {
                start,
                length,
                // left_node: _,
                right_node,
            } => {
                let space_end = start + length - 1;
                match space_end >= new_segment_end {
                    true => {
                        return Ok(MapTask {
                            state: MapState::PageMapping {
                                current_address: new_segment.start,
                            },
                            new_segment,
                        })
                    }
                    false => match right_node {
                        Some(mut node_ptr) => unsafe { node_ptr.as_mut() },
                        None => return Err(AllocError),
                    },
                }
            }
            AddressInfo::Segment(mut node_ptr) => unsafe { node_ptr.as_mut() },
        };
        let next_mapping = current_mapping.next();
        let current_mapping_end = current_mapping.start() + current_mapping.len;
        let new_segment_end = new_segment.start + new_segment.len;
        let new_vs_old_start = usize::cmp(&new_segment.start, &current_mapping.start());
        let new_vs_old_end = usize::cmp(&new_segment_end, &current_mapping_end);
        let (unmap_start, unmap_num_pages) = match (new_vs_old_start, new_vs_old_end) {
            //    |     old mapping     |
            // <--|     new mapping     |-->
            (Ordering::Less | Ordering::Equal, Ordering::Equal | Ordering::Greater) => {
                let unmap_start = current_mapping.start();
                let unmap_num_pages = current_mapping.len / arch::paging::PAGE_SIZE;
                self.tree.delete(current_mapping);
                (unmap_start, unmap_num_pages)
            }
            // |     old mapping     |
            //   |    new mapping    |-->
            (Ordering::Greater, Ordering::Equal | Ordering::Greater) => {
                let unmap_num_pages =
                    (current_mapping_end - new_segment.start) / arch::paging::PAGE_SIZE;
                current_mapping.len = new_segment.start - current_mapping.start();
                (new_segment.start, unmap_num_pages)
            }
            //    |     old mapping     |
            // <--|    new mapping    |
            (Ordering::Less | Ordering::Equal, Ordering::Less) => {
                let unmap_start = current_mapping.start();
                let unmap_num_pages = (new_segment_end - unmap_start) / arch::paging::PAGE_SIZE;
                current_mapping.len = current_mapping_end - new_segment_end;
                current_mapping.set_start(new_segment_end);
                (unmap_start, unmap_num_pages)
            }
            // |     old mapping     |
            //   |   new mapping   |
            (Ordering::Greater, Ordering::Less) => unsafe {
                // Split current mapping into two mappings, before and after new mapping
                current_mapping.len = new_segment.start - current_mapping.start();
                // TODO Create a NodeBox type, because this shouldn't have to be unsafe
                let new_split_node = self
                    .node_storage
                    .find_and_reserve_node(pages_left)
                    .expect("out of memory when reserving VMA node")
                    .as_mut();
                new_split_node.set_start(new_segment_end);
                new_split_node.len = current_mapping_end - new_segment_end;
                new_split_node.flags = current_mapping.flags;
                self.tree.insert(new_split_node);
                (new_segment.start, new_segment.len / arch::paging::PAGE_SIZE)
            },
        };
        Ok(MapTask {
            state: MapState::MappingRemoval {
                current_unmap_task: UnmapMemTask::new(unmap_start, unmap_num_pages),
                next_mapping,
            },
            new_segment,
        })
    }

    /// Panics if the start and length of `new_segment` are not page aligned, or if the end address
    /// is not less than or equal to `arch::process::HIGHEST_USER_ADDRESS`.
    pub fn start_try_map_at(&mut self, new_segment: Segment) -> Result<MapTask, AllocError> {
        debug_assert_eq!(new_segment.start % arch::paging::PAGE_SIZE, 0);
        debug_assert_eq!(new_segment.len % arch::paging::PAGE_SIZE, 0);
        let new_segment_end = new_segment.start + new_segment.len - 1;
        debug_assert!(new_segment_end <= arch::process::HIGHEST_USER_ADDRESS);
        match self.tree.get_area_info(new_segment.start) {
            AddressInfo::Space {
                start,
                length,
                // left_node: _,
                right_node: _,
            } => {
                let space_end = start + length - 1;
                match space_end >= new_segment_end {
                    true => Ok(MapTask {
                        state: MapState::PageMapping {
                            current_address: new_segment.start,
                        },
                        new_segment,
                    }),
                    false => Err(AllocError),
                }
            }
            AddressInfo::Segment(_) => Err(AllocError),
        }
    }

    /// The start of `new_segment` is intepreted as a hint of where to put the mapping.
    /// Panics if the start and length of `new_segment` are not page aligned, or if the end address
    /// is not less than or equal to `arch::process::HIGHEST_USER_ADDRESS`.
    pub fn start_find_map(&mut self, new_segment: Segment) -> Result<MapTask, AllocError> {
        // 1. Get information about segment start.
        // 2. If we're in a gap large enough to map the segment, just create a task starting at
        //    PageMapping.
        // 3. If we're in a gap, but not one large enough to map the segment, just create a search
        //    task starting at `right_node`.1
        // 4. If we're in a segment, do the same as above just using the mapping we're already
        //    inside.
        debug_assert_eq!(new_segment.start % arch::paging::PAGE_SIZE, 0);
        debug_assert_eq!(new_segment.len % arch::paging::PAGE_SIZE, 0);
        let new_segment_end = new_segment.start + new_segment.len - 1;
        debug_assert!(new_segment_end <= arch::process::HIGHEST_USER_ADDRESS);
        Ok(match self.tree.get_area_info(new_segment.start) {
            AddressInfo::Space {
                start,
                length,
                // left_node: _,
                right_node,
            } => {
                let space_end = start + length - 1;
                match space_end >= new_segment_end {
                    true => MapTask {
                        state: MapState::PageMapping {
                            current_address: new_segment.start,
                        },
                        new_segment,
                    },
                    false => MapTask {
                        state: MapState::GapSearch {
                            current_mapping: match right_node {
                                Some(ptr) => ptr,
                                None => return Err(AllocError),
                            },
                        },
                        new_segment,
                    },
                }
            }
            AddressInfo::Segment(node_ptr) => MapTask {
                state: MapState::GapSearch {
                    current_mapping: node_ptr,
                },
                new_segment,
            },
        })
    }
}

// TODO Implement VMAAllocator functions [force_map_at (map at addr, replace overlapping mappings),
// try_map_at (check memory range, fail if overlapping), map_arbitrary (pick random addresses N
// times until either a space is found, or we give up and pick the nearest gap)]. All functions
// are tasks, as mapping memory can take an arbitrary length of time.
// ADDENDUM: map_arbitrary shouldn't pick random addresses, just take an address suggestion from
// userspace (they can pick random addresses) and do gap search if that fails.
// TODO Copy code to testing crate for Miri
// TODO Consider linking nodes together? Combination of Red-Black Tree and Linked List.

enum AddressInfo {
    Segment(NonNull<Node>),
    Space {
        start: usize,
        length: usize,
        // left_node: Option<NonNull<Node>>,
        right_node: Option<NonNull<Node>>,
    },
}

#[derive(Default)]
struct VMATree {
    root: Option<NonNull<Node>>,
}

impl VMATree {
    pub const fn new() -> Self {
        Self { root: None }
    }

    /// Gets information about either the mapping or the gap containing the address.
    pub fn get_area_info(&self, address: usize) -> AddressInfo {
        unsafe {
            let Some(mut current_node_ptr) = self.root else {
                return AddressInfo::Space {
                    start: 0,
                    length: arch::process::HIGHEST_USER_ADDRESS,
                    // left_node: None,
                    right_node: None,
                };
            };
            let (gap_left_node, gap_right_node) = 'gap: loop {
                let current_node = current_node_ptr.as_mut();
                if current_node.start() > address {
                    // current_node is to the right of address
                    current_node_ptr = match current_node.children[Side::Left] {
                        Some(left_child) => left_child,
                        None => {
                            let gap_left_node = current_node.previous();
                            break 'gap (gap_left_node, Some(current_node_ptr));
                        }
                    }
                } else {
                    if current_node.start() + current_node.len > address {
                        // current_node contains address
                        return AddressInfo::Segment(current_node_ptr);
                    } else {
                        // current_node is to the left of address
                        current_node_ptr = match current_node.children[Side::Right] {
                            Some(right_child) => right_child,
                            None => {
                                let gap_right_node = current_node.next();
                                break 'gap (Some(current_node_ptr), gap_right_node);
                            }
                        }
                    }
                }
            };
            let gap_start = gap_left_node.map_or(0, |ptr| {
                let node = ptr.as_ref();
                node.start() + node.len
            });
            let gap_length = gap_right_node
                .map_or(arch::process::HIGHEST_USER_ADDRESS - gap_start, |ptr| {
                    ptr.as_ref().start() - 1
                });
            AddressInfo::Space {
                start: gap_start,
                length: gap_length,
                // left_node: gap_left_node,
                right_node: gap_right_node,
            }
        }
    }

    pub fn insert(&mut self, node: &mut Node) {
        unsafe {
            let Some(mut root) = self.root else {
                node.set_color(NodeColor::Black);
                self.root = Some(NonNull::from(node));
                return;
            };
            let mut current_node = root.as_mut();
            loop {
                if current_node.start() > node.start() {
                    current_node = match current_node.children[Side::Left] {
                        Some(mut left_child) => left_child.as_mut(),
                        None => {
                            self.insert_under(node, current_node, Side::Left);
                            return;
                        }
                    };
                } else if current_node.start() < node.start() {
                    current_node = match current_node.children[Side::Right] {
                        Some(mut left_child) => left_child.as_mut(),
                        None => {
                            self.insert_under(node, current_node, Side::Right);
                            return;
                        }
                    };
                } else {
                    unreachable!();
                }
            }
        }
    }

    pub fn delete(&mut self, node: &mut Node) {
        unsafe {
            if self.root == Some(NonNull::new_unchecked(node as *mut Node))
                && node.children == [None; 2]
            {
                self.root = None;
                Node::deinit(node);
                return;
            }
            if let [Some(_), Some(mut right_child)] = node.children {
                // Swap tree position with right minimal node
                Node::swap_positions(node, right_child.as_mut().minimum().as_mut());
            }
            // Node now has at most 1 child
            if node.color() == NodeColor::Red {
                // Node cannot have any children, remove
                node.parent.unwrap().as_mut().children[node.which_child_of_parent()] = None;
                node.parent = None;
            } else {
                // Node is black
                if let Some(left_child) = node.children[0].map(|mut ptr| ptr.as_mut()) {
                    left_child.set_color(NodeColor::Black);
                    left_child.parent = node.parent;
                    node.parent.unwrap().as_mut().children[node.which_child_of_parent()] =
                        Some(NonNull::from(left_child));
                } else if let Some(right_child) = node.children[1].map(|mut ptr| ptr.as_mut()) {
                    right_child.set_color(NodeColor::Black);
                    right_child.parent = node.parent;
                    node.parent.unwrap().as_mut().children[node.which_child_of_parent()] =
                        Some(NonNull::from(right_child));
                } else {
                    // Node has no children
                    self.delete_black_non_root_leaf(node);
                }
            }
            Node::deinit(node);
        }
    }

    unsafe fn insert_under<'a>(
        &mut self,
        mut node: &'a mut Node,
        mut new_parent: &'a mut Node,
        side: Side,
    ) {
        node.set_color(NodeColor::Red);
        debug_assert_eq!(node.parent, None);
        debug_assert_eq!(node.children, [None; 2]);
        node.parent = Some(NonNull::new_unchecked(new_parent as *mut Node));
        debug_assert_eq!(new_parent.children[side], None);
        new_parent.children[side] = Some(NonNull::new_unchecked(node as *mut Node));
        // Parent node of `new_parent`
        let mut grandparent: &mut Node;
        loop {
            if new_parent.color() == NodeColor::Black {
                // Case_I1 (new_parent black)
                return;
            }
            // From now on new_parent is red
            grandparent = match new_parent.parent {
                Some(mut new_grandparent) => new_grandparent.as_mut(),
                None => {
                    // Case_I4
                    new_parent.set_color(NodeColor::Black);
                    return;
                }
            };
            // Now new_parent is red and g is not null
            let new_side = new_parent.which_child_of_parent();
            if grandparent.children[!new_side]
                .map_or(true, |mut ptr| ptr.as_mut().color() == NodeColor::Black)
            {
                // Case_I56
                if Some(NonNull::from(node)) == new_parent.children[!side] {
                    // Case_I6
                    self.rotate_dir(new_parent, side);
                    // TODO New value of `node` isn't used after this, why is this even assigned in
                    // the Zig code?
                    node = new_parent;
                    _ = node;
                    // drop(node);
                    // node.set_color(NodeColor::Red);
                    new_parent = grandparent.children[side].unwrap().as_mut();
                }
                // Case_I6
                self.rotate_dir(grandparent, !side);
                new_parent.set_color(NodeColor::Black);
                grandparent.set_color(NodeColor::Red);
                return;
            }
            let uncle = grandparent.children[!new_side].unwrap().as_mut();
            // Case_I2
            new_parent.set_color(NodeColor::Black);
            uncle.set_color(NodeColor::Black);
            node = grandparent;
            // Iterate 1 black level higher (= 2 tree levels)
            if let Some(mut new_new_parent) = node.parent {
                new_parent = new_new_parent.as_mut();
            } else {
                return;
            }
        }
        // Case_I3: node is the root and red
    }

    unsafe fn rotate_dir(&mut self, subtree_root: &mut Node, side: Side) {
        let sibling = subtree_root.children[!side].unwrap().as_mut();
        let grandparent_maybe = subtree_root.parent;
        let cousin_maybe = sibling.children[side];
        subtree_root.children[!side] = cousin_maybe;
        if let Some(mut cousin) = cousin_maybe {
            cousin.as_mut().parent = Some(NonNull::new_unchecked(subtree_root as *mut Node));
        }
        sibling.children[side] = Some(NonNull::new_unchecked(subtree_root as *mut Node));
        subtree_root.parent = Some(NonNull::new_unchecked(sibling as *mut Node));
        sibling.parent = grandparent_maybe;
        if let Some(mut grandparent) = grandparent_maybe {
            grandparent.as_mut().children[subtree_root.which_child_of_parent()] =
                Some(NonNull::from(sibling));
        } else {
            self.root = Some(NonNull::from(sibling));
        }
    }

    unsafe fn delete_black_non_root_leaf(&mut self, mut node: &mut Node) {
        let mut parent_maybe = node.parent.map(|mut ptr| ptr.as_mut());
        let mut side = node.which_child_of_parent();
        parent_maybe.as_mut().unwrap().children[side] = None;
        while let Some(parent) = parent_maybe {
            let mut sibling = parent.children[!side].unwrap().as_mut();
            let mut distant_nephew = sibling.children[!side].map(|mut ptr| ptr.as_mut());
            let mut close_nephew = sibling.children[side].map(|mut ptr| ptr.as_mut());
            if sibling.color() == NodeColor::Red {
                // Case_D3
                self.rotate_dir(parent, side);
                parent.set_color(NodeColor::Red);
                sibling.set_color(NodeColor::Black);
                sibling = close_nephew.unwrap();
                distant_nephew = sibling.children[!side].map(|mut ptr| ptr.as_mut());
                if let Some(distant_nephew) = distant_nephew.as_mut() {
                    if distant_nephew.color() == NodeColor::Red {
                        self.delete_case_d6(parent, sibling, distant_nephew, side);
                        return;
                    }
                }
                close_nephew = sibling.children[side].map(|mut ptr| ptr.as_mut());
                if let Some(close_nephew) = close_nephew {
                    if close_nephew.color() == NodeColor::Red {
                        self.delete_case_d5(parent, sibling, close_nephew, side);
                        return;
                    }
                }
                self.delete_case_d4(parent, sibling);
                return;
            }
            if let Some(distant_nephew) = distant_nephew.as_mut() {
                if distant_nephew.color() == NodeColor::Red {
                    self.delete_case_d6(parent, sibling, distant_nephew, side);
                    return;
                }
            }
            if let Some(close_nephew) = close_nephew {
                if close_nephew.color() == NodeColor::Red {
                    self.delete_case_d5(parent, sibling, close_nephew, side);
                    return;
                }
            }
            if parent.color() == NodeColor::Red {
                self.delete_case_d4(parent, sibling);
                return;
            }
            sibling.set_color(NodeColor::Red);
            node = parent;
            side = node.which_child_of_parent();
            // Iterate 1 black level higher (= 1 tree level)
            parent_maybe = node.parent.map(|mut ptr| ptr.as_mut());
        }
        // Case_D2: node is the root
    }

    unsafe fn delete_case_d4(&mut self, parent: &mut Node, sibling: &mut Node) {
        sibling.set_color(NodeColor::Red);
        parent.set_color(NodeColor::Black);
    }

    unsafe fn delete_case_d5(
        &mut self,
        parent: &mut Node,
        sibling: &mut Node,
        close_nephew: &mut Node,
        side: Side,
    ) {
        self.rotate_dir(sibling, !side);
        sibling.set_color(NodeColor::Red);
        close_nephew.set_color(NodeColor::Black);
        self.delete_case_d6(parent, close_nephew, sibling, side);
    }

    unsafe fn delete_case_d6(
        &mut self,
        parent: &mut Node,
        sibling: &mut Node,
        distant_nephew: &mut Node,
        side: Side,
    ) {
        self.rotate_dir(parent, side);
        sibling.set_color(parent.color());
        parent.set_color(NodeColor::Black);
        distant_nephew.set_color(NodeColor::Black);
    }
}

struct NodeStorageList {
    head: NonNull<NodeStoragePage>,
}

impl NodeStorageList {
    pub fn new() -> Result<Self, AllocError> {
        let head_page = PageBox::try_new_in(NodeStoragePage::new(), PhysicalBlockAllocator)?;
        Ok(Self {
            head: unsafe { NonNull::new_unchecked(PageBox::into_raw(head_page)) },
        })
    }

    /// Searches storage pages for a node space. If no space is found, this will attempt to
    /// allocate a new storage page, which may fail.
    pub fn find_and_reserve_node(
        &mut self,
        pages_left: &mut Option<&mut u64>,
    ) -> Result<NonNull<Node>, VMAAllocationError> {
        unsafe {
            let mut current_page = self.head.as_mut();
            loop {
                if current_page.free_entries > 0 {
                    return Ok(current_page.find_and_reserve_node().unwrap());
                } else {
                    let Some(mut current_page_ptr) = current_page.next_page else {
                        break;
                    };
                    current_page = current_page_ptr.as_mut();
                }
            }
            // No space found, allocate new page
            if let Some(pages_left) = pages_left {
                if **pages_left == 0 {
                    return Err(VMAAllocationError::OutOfPagesLeft);
                }
                **pages_left -= 1;
            }
            let Ok(mut new_page) =
                PageBox::try_new_in(NodeStoragePage::new(), PhysicalBlockAllocator)
            else {
                return Err(VMAAllocationError::OutOfMemory);
            };
            let node = new_page.find_and_reserve_node().unwrap();
            current_page.next_page = Some(NonNull::new_unchecked(PageBox::into_raw(new_page)));
            Ok(node)
        }
    }
}

#[repr(C)]
struct NodeStoragePage {
    pub entries: [Node; Self::MAX_NODES],
    pub next_page: Option<NonNull<NodeStoragePage>>,
    pub free_entries: usize,
    pub usage_bitmap: [u8; Self::BITMAP_LEN],
}

impl NodeStoragePage {
    const MAX_NODES: usize = {
        // Iteratively reduce array length until both the array and bitmap can fit
        let max_array_and_bitmap_space: usize = PAGE_SIZE - (2 * size_of::<usize>());
        let mut current_num_entries = max_array_and_bitmap_space / size_of::<Node>();
        loop {
            let extra_bitmap_len = (current_num_entries % 8 > 0) as usize;
            let bitmap_byte_size = (current_num_entries / 8) + extra_bitmap_len;
            let entries_byte_size = current_num_entries * size_of::<Node>();
            if entries_byte_size + bitmap_byte_size <= max_array_and_bitmap_space {
                break;
            }
            current_num_entries -= 1;
        }
        current_num_entries
    };
    const BITMAP_LEN: usize = (Self::MAX_NODES / 8) + (Self::MAX_NODES % 8 > 0) as usize;
    const INITIAL_USAGE_BITMAP: [u8; Self::BITMAP_LEN] = match Self::MAX_NODES % 8 {
        0 => [0; Self::BITMAP_LEN],
        last_byte_entries => {
            // If there are not enough entries to fill the last byte, fill the
            // least significant bits past the end of the entries bitmap to
            // indicate that they are not free.
            // This technically probably isn't required, as the `num_entries_free`
            // field already tracks the number of free entries, and should mean
            // that bits past the end of the usable bitmap are never used anyway,
            // but this is just to be on the safe side.
            let mut bitmap = [0; Self::BITMAP_LEN];
            bitmap[Self::BITMAP_LEN - 1] = !((0x80 >> (last_byte_entries - 1)) - 1);
            bitmap
        }
    };

    pub fn new() -> Self {
        Self {
            entries: core::array::from_fn(|_| Node::placeholder()),
            next_page: None,
            free_entries: Self::MAX_NODES,
            usage_bitmap: Self::INITIAL_USAGE_BITMAP,
        }
    }

    #[inline]
    pub fn find_and_reserve_node(&mut self) -> Option<NonNull<Node>> {
        if self.free_entries == 0 {
            return None;
        }
        for (byte_index, byte) in self.usage_bitmap.iter_mut().enumerate() {
            if *byte != 0xFF {
                let bit_index = (!*byte).leading_zeros() as usize;
                *byte |= 0x80 >> bit_index;
                self.free_entries -= 1;
                let entry_index = (byte_index * 8) + bit_index;
                debug_assert!(entry_index < Self::MAX_NODES);
                return Some(NonNull::from(&mut self.entries[entry_index]));
            }
        }
        unreachable!();
    }

    /// Marks its place as no longer reserved.
    pub fn unreserve_node(&mut self, i: usize) {
        debug_assert!(i < Self::MAX_NODES);
        let byte_index = i / 8;
        let bit_index = i % 8;
        self.usage_bitmap[byte_index] &= !(0x80 >> bit_index);
        self.free_entries += 1;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NodeColor {
    Red = 0,
    Black = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Side {
    Left = 0,
    Right = 1,
}

impl core::ops::Not for Side {
    type Output = Self;

    fn not(self) -> Self::Output {
        match self {
            Side::Left => Side::Right,
            Side::Right => Side::Left,
        }
    }
}

impl core::ops::Index<Side> for [Option<NonNull<Node>>; 2] {
    type Output = Option<NonNull<Node>>;

    fn index(&self, side: Side) -> &Self::Output {
        &self[side as usize]
    }
}

impl core::ops::IndexMut<Side> for [Option<NonNull<Node>>; 2] {
    fn index_mut(&mut self, side: Side) -> &mut Self::Output {
        &mut self[side as usize]
    }
}

#[derive(Debug)]
struct Node {
    start_and_color: usize,
    pub len: usize,
    pub flags: usize,
    parent: Option<NonNull<Node>>,
    children: [Option<NonNull<Node>>; 2],
}

impl Node {
    pub const fn placeholder() -> Self {
        Self {
            start_and_color: 0,
            len: 0,
            flags: 0,
            parent: None,
            children: [None; 2],
        }
    }

    pub unsafe fn deinit(node: *mut Self) {
        node.write(Node::placeholder());
        // Get NodeStoragePage containing self
        let page_address = (node as usize) & !(PAGE_SIZE - 1);
        let node_storage_page = &mut *(page_address as *mut NodeStoragePage);
        // Calculate index of self
        let address_in_page = (node as usize) & (PAGE_SIZE - 1);
        const ARRAY_OFFSET: usize = offset_of!(NodeStoragePage, entries);
        let entry_index = (address_in_page - ARRAY_OFFSET) / size_of::<Node>();
        node_storage_page.unreserve_node(entry_index);
    }

    pub fn start(&self) -> usize {
        self.start_and_color & !1
    }

    pub fn color(&self) -> NodeColor {
        match self.start_and_color & 1 {
            0 => NodeColor::Red,
            1 => NodeColor::Black,
            _ => unreachable!(),
        }
    }

    pub fn set_start(&mut self, address: usize) {
        let new_start = address & !1;
        let color = self.start_and_color & 1;
        self.start_and_color = new_start | color;
    }

    pub fn set_color(&mut self, color: NodeColor) {
        let new_color = color as usize;
        let start = self.start();
        self.start_and_color = start | new_color;
    }

    /// Panics if the node has no parent.
    pub fn which_child_of_parent(&self) -> Side {
        unsafe {
            self.parent.unwrap().as_ref().children[Side::Right].map_or(Side::Left, |child| {
                match child.as_ptr() == self as *const Self as *mut Self {
                    false => Side::Left,
                    true => Side::Right,
                }
            })
        }
    }

    pub fn minimum(&self) -> NonNull<Self> {
        unsafe {
            let mut current_node = NonNull::from(self);
            while let Some(left_child) = current_node.as_ref().children[0] {
                current_node = left_child;
            }
            current_node
        }
    }

    pub fn maximum(&self) -> NonNull<Self> {
        unsafe {
            let mut current_node = NonNull::from(self);
            while let Some(right_child) = current_node.as_ref().children[1] {
                current_node = right_child;
            }
            current_node
        }
    }

    pub fn previous(&self) -> Option<NonNull<Self>> {
        unsafe {
            if let Some(left_child) = self.children[0] {
                return Some(left_child.as_ref().maximum());
            }
            let mut current_node = self;
            loop {
                let Some(parent) = current_node.parent else {
                    return None;
                };
                match current_node.which_child_of_parent() {
                    Side::Left => current_node = parent.as_ref(),
                    Side::Right => return Some(parent),
                }
            }
        }
    }

    pub fn next(&self) -> Option<NonNull<Self>> {
        unsafe {
            if let Some(left_child) = self.children[1] {
                return Some(left_child.as_ref().minimum());
            }
            let mut current_node = self;
            loop {
                let Some(parent) = current_node.parent else {
                    return None;
                };
                match current_node.which_child_of_parent() {
                    Side::Left => return Some(parent),
                    Side::Right => current_node = parent.as_ref(),
                }
            }
        }
    }

    /// Swaps tree positions between two nodes including parents, children and color.
    pub fn swap_positions(x: &mut Self, y: &mut Self) {
        unsafe {
            // Update child pointer in parents
            if let Some(mut parent) = x.parent {
                let side = x.which_child_of_parent();
                parent.as_mut().children[side] = Some(NonNull::new_unchecked(y as *mut Self));
            }
            if let Some(mut parent) = y.parent {
                let side = y.which_child_of_parent();
                parent.as_mut().children[side] = Some(NonNull::new_unchecked(x as *mut Self));
            }
            // Swap parent pointers
            core::mem::swap(&mut x.parent, &mut y.parent);
            // Swap color
            let x_color = x.color();
            let y_color = y.color();
            x.set_color(y_color);
            y.set_color(x_color);
            // Update parent pointer in children
            for child in &mut x.children {
                if let Some(child) = child {
                    child.as_mut().parent = Some(NonNull::new_unchecked(y as *mut Self));
                }
            }
            for child in &mut y.children {
                if let Some(child) = child {
                    child.as_mut().parent = Some(NonNull::new_unchecked(x as *mut Self));
                }
            }
            // Swap children
            core::mem::swap(&mut x.children, &mut y.children);
        }
    }
}

#[derive(Debug)]
pub struct MapTask {
    state: MapState,
    new_segment: Segment,
}

#[derive(Debug)]
enum MapState {
    /// Old VMA mappings are being removed or truncated, and memory pages are being unmapped.
    MappingRemoval {
        current_unmap_task: UnmapMemTask,
        next_mapping: Option<NonNull<Node>>,
    },
    /// A gap in VMA mappings large enough for the new mapping is being searched for.
    GapSearch { current_mapping: NonNull<Node> },
    /// New memory pages are being mapped, followed by a new VMA mapping being created.
    PageMapping { current_address: usize },
}

impl MapTask {
    pub fn run<F>(
        &mut self,
        allocator: &mut VMAAllocator,
        pages_left: &mut Option<&mut u64>,
        mut should_suspend: F,
    ) -> Poll<Result<(), VMAAllocationError>>
    where
        F: FnMut() -> bool,
    {
        unsafe {
            loop {
                match &mut self.state {
                    MapState::MappingRemoval {
                        current_unmap_task,
                        next_mapping,
                    } => match current_unmap_task
                        .run(&mut allocator.page_mapper, &mut should_suspend)
                    {
                        // Unmap task suspend, so we suspend too
                        Poll::Pending => return Poll::Pending,
                        // Current unmap task done, move on
                        Poll::Ready(_) => {
                            let next_mapping = match next_mapping {
                                None => {
                                    self.state = MapState::PageMapping {
                                        current_address: self.new_segment.start,
                                    };
                                    continue;
                                }
                                Some(ptr) => ptr.as_mut(),
                            };
                            // Get new next mapping for removal next cycle, if needs removing
                            let new_next_mapping = next_mapping.next().and_then(|new_next| {
                                match self.new_segment.start + self.new_segment.len
                                    <= new_next.as_ref().start()
                                {
                                    false => Some(new_next),
                                    true => None,
                                }
                            });
                            let next_mapping_end = next_mapping.start() + next_mapping.len;
                            let new_segment_end = self.new_segment.start + self.new_segment.len;
                            let new_vs_old_start =
                                usize::cmp(&self.new_segment.start, &next_mapping.start());
                            let new_vs_old_end = usize::cmp(&new_segment_end, &next_mapping_end);
                            let (unmap_start, unmap_num_pages) =
                                match (new_vs_old_start, new_vs_old_end) {
                                    //    |     old mapping     |
                                    // <--|     new mapping     |-->
                                    (
                                        Ordering::Less | Ordering::Equal,
                                        Ordering::Equal | Ordering::Greater,
                                    ) => {
                                        let unmap_start = next_mapping.start();
                                        let unmap_num_pages =
                                            next_mapping.len / arch::paging::PAGE_SIZE;
                                        allocator.tree.delete(next_mapping);
                                        (unmap_start, unmap_num_pages)
                                    }
                                    // |     old mapping     |
                                    //   |    new mapping    |-->
                                    (Ordering::Greater, Ordering::Equal | Ordering::Greater) => {
                                        let unmap_num_pages = (next_mapping_end
                                            - self.new_segment.start)
                                            / arch::paging::PAGE_SIZE;
                                        next_mapping.len =
                                            self.new_segment.start - next_mapping.start();
                                        (self.new_segment.start, unmap_num_pages)
                                    }
                                    //    |     old mapping     |
                                    // <--|    new mapping    |
                                    (Ordering::Less | Ordering::Equal, Ordering::Less) => {
                                        let unmap_start = next_mapping.start();
                                        let unmap_num_pages = (new_segment_end - unmap_start)
                                            / arch::paging::PAGE_SIZE;
                                        next_mapping.len = next_mapping_end - new_segment_end;
                                        next_mapping.set_start(new_segment_end);
                                        (unmap_start, unmap_num_pages)
                                    }
                                    // |     old mapping     |
                                    //   |   new mapping   |
                                    (Ordering::Greater, Ordering::Less) => {
                                        // Split current mapping into two mappings, before and after new mapping
                                        next_mapping.len =
                                            self.new_segment.start - next_mapping.start();
                                        // TODO Create a NodeBox type, because this shouldn't have to be unsafe
                                        let new_split_node = allocator
                                            .node_storage
                                            .find_and_reserve_node(pages_left)
                                            .expect("out of memory when reserving VMA node")
                                            .as_mut();
                                        new_split_node.set_start(new_segment_end);
                                        new_split_node.len = next_mapping_end - new_segment_end;
                                        new_split_node.flags = next_mapping.flags;
                                        allocator.tree.insert(new_split_node);
                                        (
                                            self.new_segment.start,
                                            self.new_segment.len / arch::paging::PAGE_SIZE,
                                        )
                                    }
                                };
                            self.state = MapState::MappingRemoval {
                                current_unmap_task: UnmapMemTask::new(unmap_start, unmap_num_pages),
                                next_mapping: new_next_mapping,
                            };
                        }
                    },
                    MapState::GapSearch { current_mapping } => {
                        let current_mapping = current_mapping.as_ref();
                        let next_mapping = current_mapping.next();
                        let gap_size = match next_mapping {
                            Some(next_mapping) => {
                                next_mapping.as_ref().start()
                                    - (current_mapping.start() + current_mapping.len)
                            }
                            None => {
                                arch::process::HIGHEST_USER_ADDRESS
                                    - (current_mapping.start() + current_mapping.len)
                            }
                        };
                        if gap_size >= self.new_segment.len {
                            // Found large enough gap, place mapping here
                            // TODO Implement some kind of ASLR?
                            self.state = MapState::PageMapping {
                                current_address: self.new_segment.start,
                            };
                        } else {
                            self.state = match next_mapping {
                                Some(mapping) => MapState::GapSearch {
                                    current_mapping: mapping,
                                },
                                None => {
                                    return Poll::Ready(Err(VMAAllocationError::OutOfAddressSpace))
                                }
                            };
                        }
                    }
                    MapState::PageMapping { current_address } => {
                        // 1. Check if we're done yet, add new segment and finish if we are (put
                        //    unreachable in case of error adding new segment).
                        // 2. Map new page (check document to see what should be done about
                        //    errors).
                        // 3. Update state for new address.
                        // TODO Decide what to do about ^this comment (probably just clean up and
                        // explain other branches as well)
                        // Insert segment if finished
                        if *current_address >= self.new_segment.start + self.new_segment.len {
                            // TODO NEXT Add pages_left (note 2023/8/4: is this done?)
                            let node = allocator
                                .node_storage
                                .find_and_reserve_node(pages_left)
                                .unwrap()
                                .as_mut();
                            node.set_start(self.new_segment.start);
                            node.len = self.new_segment.len;
                            node.flags = self.new_segment.flags.into();
                            allocator.tree.insert(node);
                            return Poll::Ready(Ok(()));
                        } else {
                            // TODO NEXT What are we doing with readable flag?
                            // TODO NEXT Sort out some platform independent page flag system, fix
                            // this to use this
                            let mut flag_data = PageTableData::default();
                            flag_data.writable = self.new_segment.flags.write;
                            flag_data.no_execute = !self.new_segment.flags.execute;
                            flag_data.user_accessable = true;
                            // TODO NEXT Add pages_left
                            allocator
                                .page_mapper
                                .map_blank_page(*current_address, flag_data.into(), pages_left)
                                .unwrap();
                            *current_address += PAGE_SIZE;
                        }
                    }
                }
                if should_suspend() {
                    return Poll::Pending;
                }
            }
        }
    }
}
