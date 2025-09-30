use crate::arch;
use crate::arch::paging::PAGE_SIZE;
use crate::arch::user_page_mapping::{UnmapMemTask, MapMemTask, UserPageMapper, MapMemError};
use crate::physical_block_allocator::{PageBox, PhysicalBlockAllocator};
use core::alloc::AllocError;
use core::mem::{size_of, offset_of};
use core::ptr::NonNull;
use core::task::Poll;
use spin::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Segment {
    pub start: usize,
    pub len: usize,
    pub flags: SegmentFlags,
}

// TODO: Replace this with a bitfield structure, to be taken straight from syscall

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SegmentFlags {
    pub read: bool,
    pub write: bool,
    pub execute: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum VMAMapError {
    #[error("a segment already exists in the requested mapping area")]
    SegmentAlreadyExists,
    #[error("out of memory")]
    OutOfMemory,
    #[error("out of address space")]
    OutOfAddressSpace,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum VMAUnmapError {
    #[error("the segment is already unmapped")]
    SegmentAlreadyUnmapped,
    #[error("the segment is currently locked")]
    SegmentLocked,
}

pub struct VMAAllocator {
    page_mapper: UserPageMapper,
    tree: Mutex<VMATree>,
}

impl VMAAllocator {
    pub fn new(page_mapper: UserPageMapper, pages_used: &mut usize) -> Result<Self, AllocError> {
        Ok(Self {
            page_mapper,
            tree: Mutex::new(VMATree::new(pages_used)?),
        })
    }

    /// Unmaps the segment containing `segment_address`.
    /// Returns `VMAUnmapError::SegmentAlreadyUnmapped` if `segment_address` does not belong to a
    /// segment, or `VMAUnmapError::SegmentLocked` if the segment is currently locked for mapping
    /// or unmapping by another task.
    pub fn start_unmap(&self, segment_address: usize) -> Result<UnmapTask, VMAUnmapError> {
        unsafe {
            let tree = self.tree.lock();
            let LeafInfo {
                leaf,
                parent_and_side: _,
                start,
                end,
            } = tree.get_leaf_containing(segment_address);
            let leaf = leaf.unwrap_leaf();
            match &mut *leaf.raw() {
                LeafNode::Empty { .. } => Err(VMAUnmapError::SegmentAlreadyUnmapped),
                LeafNode::Used { flags } => {
                    if flags.locked() {
                        return Err(VMAUnmapError::SegmentLocked);
                    }
                    flags.set_locked(true);
                    Ok(UnmapTask {
                        start_address: start,
                        unmap_mem_task: UnmapMemTask::new(start, (end + 1 - start) / PAGE_SIZE),
                    })
                }
            }
        }
    }

    /// # Safety
    ///
    /// The start and length of `new_segment` must be page aligned, and the end address must be
    /// less than or equal to `arch::process::HIGHEST_USER_ADDRESS`.
    pub unsafe fn start_try_map_at(
        &mut self,
        pages_used: &mut usize,
        new_segment: Segment,
    ) -> Result<MapTask, VMAMapError> {
        unsafe {
            debug_assert_eq!(new_segment.start % PAGE_SIZE, 0);
            debug_assert_eq!(new_segment.len % PAGE_SIZE, 0);
            let mut tree = self.tree.lock();
            let new_segment_end = new_segment.start + new_segment.len - 1;
            debug_assert!(new_segment_end <= arch::process::HIGHEST_USER_ADDRESS);
            let LeafInfo { leaf, end, .. } = tree.get_leaf_containing(new_segment.start);
            if end < new_segment_end {
                return Err(VMAMapError::SegmentAlreadyExists);
            }
            let leaf = leaf.unwrap_leaf();
            match leaf.read() {
                LeafNode::Empty { .. } => {
                    let new_leaf = tree.insert(
                        pages_used,
                        new_segment.start,
                        new_segment.len,
                        new_segment.flags.into(),
                    )?
                    .unwrap_leaf();
                    let flags_ptr = new_leaf.unwrap_used_flags_ptr();
                    (*flags_ptr.as_ptr()).set_locked(true);
                    Ok(MapTask {
                        map_mem_task: MapMemTask::new(
                            new_segment.start,
                            new_segment.len / PAGE_SIZE,
                            new_segment.flags,
                        ),
                    })
                }
                LeafNode::Used { .. } => Err(VMAMapError::SegmentAlreadyExists),
            }
        }
    }

    // /// # Safety
    // ///
    // /// The start of `new_segment` is intepreted as a hint of where to put the mapping.
    // /// Panics if the start and length of `new_segment` are not page aligned, or if the end address
    // /// is not less than or equal to `arch::process::HIGHEST_USER_ADDRESS`.
    // pub fn start_find_map(
    //     &mut self,
    //     pages_used: &mut usize,
    //     new_segment: Segment,
    // ) -> Result<MapTask, AllocError> {
    //     // 1. Get information about segment start.
    //     // 2. If we're in a gap large enough to map the segment, just create a task starting at
    //     //    PageMapping.
    //     // 3. If we're in a gap, but not one large enough to map the segment, just create a search
    //     //    task starting at `right_node`.1
    //     // 4. If we're in a segment, do the same as above just using the mapping we're already
    //     //    inside.
    //     debug_assert_eq!(new_segment.start % PAGE_SIZE, 0);
    //     debug_assert_eq!(new_segment.len % PAGE_SIZE, 0);
    //     let new_segment_end = new_segment.start + new_segment.len - 1;
    //     debug_assert!(new_segment_end <= arch::process::HIGHEST_USER_ADDRESS);
    //     Ok(match self.tree.get_area_info(new_segment.start) {
    //         AddressInfo::Space {
    //             start,
    //             length,
    //             // left_node: _,
    //             right_node,
    //         } => {
    //             MapTask {
    //                 state: if start + length - 1 >= new_segment_end {
    //                     let mut node = self
    //                         .node_storage
    //                         .find_and_reserve_node(pages_used)
    //                         .unwrap();
    //                     node.set_start(new_segment.start);
    //                     node.len = new_segment.len;
    //                     node.flags = new_segment.flags.into();
    //                     let node_ptr = self.tree.insert(node).as_ptr();
    //                     MapState::PageMapping {
    //                         current_address: new_segment.start,
    //                         new_mapping: node_ptr,
    //                     }
    //                 } else {
    //                     MapState::GapSearch {
    //                         current_mapping: match right_node {
    //                             Some(ptr) => ptr,
    //                             None => return Err(AllocError),
    //                         },
    //                     }
    //                 },
    //                 new_segment,
    //             }
    //         }
    //         AddressInfo::Segment(node_ptr) => MapTask {
    //             state: MapState::GapSearch {
    //                 current_mapping: node_ptr,
    //             },
    //             new_segment,
    //         },
    //     })
    // }
}

struct NodeStorageList {
    head: NonNull<NodeStoragePage>,
    /// Used in node deletion operations.
    temp_node: Node,
}

impl NodeStorageList {
    pub fn new() -> Result<Self, AllocError> {
        let head_page = PageBox::try_new_in(
            NodeStoragePage::new_with_prev_page(None),
            PhysicalBlockAllocator,
        )?;
        Ok(Self {
            head: unsafe { NonNull::new_unchecked(PageBox::into_raw_with_allocator(head_page).0) },
            temp_node: Node::placeholder(),
        })
    }

    /// Searches storage pages for a node space.
    /// If no space is found, this will attempt to allocate a new storage page, which may fail.
    fn find_and_reserve_node(&mut self, pages_used: &mut usize) -> Result<NodePtr, VMAMapError> {
        unsafe {
            let mut current_page_ptr = self.head;
            let mut current_page = current_page_ptr.as_mut();
            loop {
                if current_page.free_entries > 0 {
                    return Ok(current_page.find_and_reserve_node().unwrap());
                } else {
                    match current_page.next_page {
                        Some(next_page_ptr) => current_page_ptr = next_page_ptr,
                        None => break,
                    }
                    current_page = current_page_ptr.as_mut();
                }
            }
            // No space found, allocate new page
            *pages_used += 1;
            let Ok(mut new_page) = PageBox::try_new_in(
                NodeStoragePage::new_with_prev_page(Some(current_page_ptr)),
                PhysicalBlockAllocator,
            ) else {
                return Err(VMAMapError::OutOfMemory);
            };
            let node = new_page.find_and_reserve_node().unwrap();
            current_page.next_page = Some(NonNull::new_unchecked(
                PageBox::into_raw_with_allocator(new_page).0,
            ));
            Ok(node)
        }
    }

    pub fn new_empty_leaf(
        &mut self,
        pages_used: &mut usize,
        size: usize,
    ) -> Result<NodePtr, VMAMapError> {
        unsafe {
            let node_ptr = self.find_and_reserve_node(pages_used)?;
            node_ptr.write(Node::Leaf(LeafNode::Empty { size }));
            Ok(node_ptr)
        }
    }

    pub fn new_used_leaf(
        &mut self,
        pages_used: &mut usize,
        flags: NodeFlags,
    ) -> Result<NodePtr, VMAMapError> {
        unsafe {
            let node_ptr = self.find_and_reserve_node(pages_used)?;
            node_ptr.write(Node::Leaf(LeafNode::Used { flags }));
            Ok(node_ptr)
        }
    }

    pub fn new_branch(
        &mut self,
        pages_used: &mut usize,
        pivot: usize,
        parent: Option<BranchNodePtr>,
        left: NodePtr,
        right: NodePtr,
    ) -> Result<NodePtr, VMAMapError> {
        unsafe {
            let node_ptr = self.find_and_reserve_node(pages_used)?;
            node_ptr.write(Node::Branch(BranchNode::new(
                pivot,
                false,
                NodeColor::Black,
                parent,
                left,
                right,
            )));
            Ok(node_ptr)
        }
    }

    pub fn get_temp_node(&mut self) -> NodePtr {
        NodePtr(NonNull::from(&mut self.temp_node))
    }
}

#[repr(C)]
struct NodeStoragePage {
    pub entries: [Node; Self::MAX_NODES],
    pub next_page: Option<NonNull<NodeStoragePage>>,
    pub prev_page: Option<NonNull<NodeStoragePage>>,
    pub free_entries: usize,
    pub usage_bitmap: [u8; Self::BITMAP_LEN],
}

impl NodeStoragePage {
    const MAX_NODES: usize = {
        // Iteratively reduce array length until both the array and bitmap can fit
        let max_array_and_bitmap_space: usize = PAGE_SIZE - (3 * size_of::<usize>());
        let mut current_num_entries = max_array_and_bitmap_space / size_of::<Node>();
        loop {
            let extra_bitmap_len = !current_num_entries.is_multiple_of(8) as usize;
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

    pub fn new_with_prev_page(prev_page: Option<NonNull<NodeStoragePage>>) -> Self {
        Self {
            entries: core::array::from_fn(|_| Node::placeholder()),
            next_page: None,
            prev_page,
            free_entries: Self::MAX_NODES,
            usage_bitmap: Self::INITIAL_USAGE_BITMAP,
        }
    }

    #[inline]
    pub fn find_and_reserve_node(&mut self) -> Option<NodePtr> {
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
                return Some(NodePtr(NonNull::from(&mut self.entries[entry_index])));
            }
        }
        unreachable!();
    }

    /// Mark the node at the given index as no longer reserved.
    /// If this returns `true`, then this page is now empty, and has unlinked itself.
    /// This means it should be now be freed.
    #[must_use]
    pub unsafe fn unreserve_node(&mut self, i: usize) -> bool {
        debug_assert!(i < Self::MAX_NODES);
        // Check if the page is now completely empty, and that we're not the head page.
        if self.free_entries + 1 == Self::MAX_NODES
            && let Some(mut prev_page) = self.prev_page
        {
            // If this is empty, unlink it and report that this page should be freed.
            unsafe {
                if let Some(mut next_page) = self.next_page {
                    next_page.as_mut().prev_page = self.prev_page;
                }
                prev_page.as_mut().next_page = self.next_page;
                true
            }
        } else {
            // If the page still isn't empty, just mark the node as no longer reserved.
            let byte_index = i / 8;
            let bit_index = i % 8;
            self.usage_bitmap[byte_index] &= !(0x80 >> bit_index);
            self.free_entries += 1;
            false
        }
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

bitfield::bitfield! {
    #[derive(Clone, Copy, PartialEq, Eq)]
    #[repr(transparent)]
    pub struct NodeFlags(u32);
    impl Debug;
    pub readable, set_readable: 0;
    pub writable, set_writable: 1;
    pub executable, set_executable: 2;
    pub locked, set_locked: 31;
}

impl From<SegmentFlags> for NodeFlags {
    fn from(flags: SegmentFlags) -> Self {
        let mut out = Self(0);
        out.set_readable(flags.read);
        out.set_writable(flags.write);
        out.set_executable(flags.execute);
        out
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Node {
    Branch(BranchNode),
    Leaf(LeafNode),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LeafNode {
    Empty { size: usize },
    Used { flags: NodeFlags },
}

#[derive(Debug, PartialEq, Eq)]
struct BranchNode {
    /// 0: Node color
    /// 1: Is temp null?
    /// 2-(usize::BITS-1): pivot (masked, not shifted)
    packed_fields: usize,
    max_empty_area_size: usize,
    parent: Option<BranchNodePtr>,
    left: NodePtr,
    right: NodePtr,
}

unsafe impl Sync for BranchNode {}

impl core::ops::Index<Side> for BranchNode {
    type Output = NodePtr;

    fn index(&self, side: Side) -> &Self::Output {
        match side {
            Side::Left => &self.left,
            Side::Right => &self.right,
        }
    }
}

impl core::ops::IndexMut<Side> for BranchNode {
    fn index_mut(&mut self, side: Side) -> &mut Self::Output {
        match side {
            Side::Left => &mut self.left,
            Side::Right => &mut self.right,
        }
    }
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
struct NodePtr(pub NonNull<Node>);

#[repr(transparent)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BranchNodePtr(pub NonNull<BranchNode>);

#[repr(transparent)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct LeafNodePtr(pub NonNull<LeafNode>);

impl Node {
    pub const fn placeholder() -> Self {
        Self::Leaf(LeafNode::Empty { size: 0 })
    }
}

impl BranchNode {
    pub fn new(
        pivot: usize,
        is_temp_null: bool,
        color: NodeColor,
        parent: Option<BranchNodePtr>,
        left: NodePtr,
        right: NodePtr,
    ) -> Self {
        Self {
            packed_fields: (pivot & !0b11) | ((is_temp_null as usize) << 1) | (color as usize),
            max_empty_area_size: 0,
            parent,
            left,
            right,
        }
    }

    pub fn pivot(&self) -> usize {
        self.packed_fields & !0b11
    }

    pub fn color(&self) -> NodeColor {
        match self.packed_fields & 0b01 {
            0 => NodeColor::Red,
            1 => NodeColor::Black,
            _ => unreachable!(),
        }
    }
}

impl NodePtr {
    pub unsafe fn read(self) -> Node {
        unsafe { self.0.read() }
    }

    pub unsafe fn write(self, value: Node) {
        unsafe {
            self.0.write(value);
        }
    }

    pub fn raw(self) -> *mut Node {
        self.0.as_ptr()
    }

    pub unsafe fn free(self) {
        unsafe {
            self.write(Node::placeholder());
            // Get NodeStoragePage containing self
            let page_address = (self.raw() as usize) & !(PAGE_SIZE - 1);
            let node_storage_page = page_address as *mut NodeStoragePage;
            // Calculate index of self
            let address_in_page = (self.raw() as usize) & (PAGE_SIZE - 1);
            const ARRAY_OFFSET: usize = offset_of!(NodeStoragePage, entries);
            let entry_index = (address_in_page - ARRAY_OFFSET) / size_of::<Node>();
            let storage_page_needs_freeing = (*node_storage_page).unreserve_node(entry_index);
            // If the unreserve operation returned true, then it's already unlinked itself from the
            // storage page list, and we need to free it.
            if storage_page_needs_freeing {
                drop(PageBox::from_raw_in(node_storage_page, PhysicalBlockAllocator));
            }
        }
    }

    pub unsafe fn color(self) -> NodeColor {
        unsafe {
            match self.0.read() {
                Node::Branch(branch) => branch.color(),
                Node::Leaf(_) => NodeColor::Black,
            }
        }
    }

    pub unsafe fn is_branch(self) -> bool {
        unsafe {
            match self.0.read() {
                Node::Branch(_) => true,
                Node::Leaf(_) => false,
            }
        }
    }

    pub unsafe fn is_leaf(self) -> bool {
        unsafe {
            match self.0.read() {
                Node::Branch(_) => false,
                Node::Leaf(_) => true,
            }
        }
    }

    pub unsafe fn is_empty_leaf(self) -> bool {
        unsafe {
            match self.0.read() {
                Node::Branch(_) => false,
                Node::Leaf(LeafNode::Empty { .. }) => true,
                Node::Leaf(LeafNode::Used { .. }) => false,
            }
        }
    }

    pub unsafe fn is_used_leaf(self) -> bool {
        unsafe {
            match self.0.read() {
                Node::Branch(_) => false,
                Node::Leaf(LeafNode::Empty { .. }) => false,
                Node::Leaf(LeafNode::Used { .. }) => true,
            }
        }
    }

    pub unsafe fn branch(self) -> Option<BranchNodePtr> {
        unsafe {
            if matches!(self.0.read(), Node::Branch(_)) {
                Some(self.unwrap_branch())
            } else {
                None
            }
        }
    }

    pub unsafe fn unwrap_branch(self) -> BranchNodePtr {
        unsafe {
            debug_assert!(matches!(self.0.read(), Node::Branch(_)));
            BranchNodePtr(
                self.0
                    .byte_add(core::mem::offset_of!(Node, Branch.0))
                    .cast::<BranchNode>(),
            )
        }
    }

    pub unsafe fn unwrap_leaf(self) -> LeafNodePtr {
        unsafe {
            debug_assert!(matches!(self.0.read(), Node::Leaf(_)));
            LeafNodePtr(
                self.0
                    .byte_add(core::mem::offset_of!(Node, Leaf.0))
                    .cast::<LeafNode>(),
            )
        }
    }
}

impl BranchNodePtr {
    pub unsafe fn read(self) -> BranchNode {
        unsafe { self.0.read() }
    }

    pub fn raw(self) -> *mut BranchNode {
        self.0.as_ptr()
    }

    pub unsafe fn node_ptr(self) -> NodePtr {
        unsafe {
            NodePtr(
                self.0
                    .byte_sub(core::mem::offset_of!(Node, Branch.0))
                    .cast::<Node>(),
            )
        }
    }

    pub unsafe fn pivot(self) -> usize {
        unsafe { (*self.raw()).packed_fields & !0b11 }
    }

    pub unsafe fn color(self) -> NodeColor {
        unsafe {
            match (*self.raw()).packed_fields & 0b01 {
                0 => NodeColor::Red,
                1 => NodeColor::Black,
                _ => unreachable!(),
            }
        }
    }

    pub unsafe fn is_temp_null(self) -> bool {
        unsafe { (*self.raw()).packed_fields & 0b10 != 0 }
    }

    pub unsafe fn set_pivot(self, pivot: usize) {
        unsafe {
            let ptr = self.raw();
            (*ptr).packed_fields &= 0b11;
            (*ptr).packed_fields |= pivot & !0b11;
        }
    }

    pub unsafe fn set_color(self, color: NodeColor) {
        unsafe {
            let ptr = self.raw();
            (*ptr).packed_fields &= !0b01;
            (*ptr).packed_fields |= color as usize;
        }
    }

    pub unsafe fn set_max_empty_area_size(self, new_size: usize) {
        unsafe {
            let ptr = self.raw();
            (*ptr).max_empty_area_size = new_size;
        }
    }

    pub unsafe fn is_left_side(self) -> Option<bool> {
        unsafe { Some(self.node_ptr() == (*(*self.raw()).parent?.raw()).left) }
    }

    pub unsafe fn is_right_side(self) -> Option<bool> {
        unsafe { Some(self.node_ptr() == (*(*self.raw()).parent?.raw()).right) }
    }

    pub unsafe fn get_parent(self) -> Self {
        unsafe { (*self.raw()).parent.unwrap() }
    }

    pub unsafe fn get_grandparent(self) -> Self {
        unsafe { self.get_parent().get_parent() }
    }

    pub unsafe fn get_sibling(self) -> NodePtr {
        unsafe {
            let self_node = self.node_ptr();
            let parent = self.get_parent();
            if self_node == (*parent.raw()).left {
                (*parent.raw()).right
            } else if self_node == (*parent.raw()).right {
                (*parent.raw()).left
            } else {
                unreachable!();
            }
        }
    }

    pub unsafe fn recalculate_max_empty_area_size(self) {
        unsafe {
            let self_branch = self.0.read();
            let left_max_size = match self_branch.left.read() {
                Node::Branch(child_branch) => child_branch.max_empty_area_size,
                Node::Leaf(LeafNode::Used { .. }) => 0,
                Node::Leaf(LeafNode::Empty { size }) => size,
            };
            let right_max_size = match self_branch.right.read() {
                Node::Branch(child_branch) => child_branch.max_empty_area_size,
                Node::Leaf(LeafNode::Used { .. }) => 0,
                Node::Leaf(LeafNode::Empty { size }) => size,
            };
            (*self.raw()).max_empty_area_size = usize::max(left_max_size, right_max_size);
        }
    }
}

impl LeafNodePtr {
    pub unsafe fn read(self) -> LeafNode {
        unsafe { self.0.read() }
    }

    pub fn raw(self) -> *mut LeafNode {
        self.0.as_ptr()
    }

    pub unsafe fn is_empty(self) -> bool {
        unsafe {
            match self.0.read() {
                LeafNode::Empty { .. } => true,
                LeafNode::Used { .. } => false,
            }
        }
    }

    pub unsafe fn unwrap_flags(self) -> NodeFlags {
        unsafe {
            match self.0.read() {
                LeafNode::Used { flags } => flags,
                LeafNode::Empty { .. } => panic!(),
            }
        }
    }

    pub unsafe fn unwrap_empty_size_ptr(self) -> NonNull<usize> {
        unsafe {
            debug_assert!(matches!(self.0.read(), LeafNode::Empty { .. }));
            self.0
                .byte_add(core::mem::offset_of!(LeafNode, Empty.size))
                .cast::<usize>()
        }
    }

    pub unsafe fn unwrap_empty_set_size(self, new_size: usize) {
        unsafe {
            self.unwrap_empty_size_ptr().write(new_size);
        }
    }

    pub unsafe fn unwrap_used_flags_ptr(self) -> NonNull<NodeFlags> {
        unsafe {
            debug_assert!(matches!(self.0.read(), LeafNode::Used { .. }));
            self.0
                .byte_add(core::mem::offset_of!(LeafNode, Used.flags))
                .cast::<NodeFlags>()
        }
    }
}

struct VMATree {
    root: NodePtr,
    node_storage: NodeStorageList,
}

struct LeafInfo {
    pub leaf: NodePtr,
    pub parent_and_side: Option<(BranchNodePtr, Side)>,
    pub start: usize,
    pub end: usize,
}

impl VMATree {
    pub fn new(pages_used: &mut usize) -> Result<Self, AllocError> {
        let mut node_storage = NodeStorageList::new()?;
        let root = node_storage
            .new_empty_leaf(pages_used, arch::process::HIGHEST_USER_ADDRESS)
            .unwrap();
        Ok(Self { root, node_storage })
    }

    /// Returns a pointer to the newly inserted leaf node.
    pub fn insert(
        &mut self,
        pages_used: &mut usize,
        start: usize,
        len: usize,
        flags: NodeFlags,
    ) -> Result<NodePtr, VMAMapError> {
        unsafe {
            let end = start + len - 1;
            let LeafInfo {
                leaf: gap_node,
                parent_and_side,
                start: gap_start,
                end: gap_end,
            } = self.get_leaf_containing(start);
            assert!(gap_node.is_empty_leaf());
            assert!(gap_start <= start);
            assert!(end <= gap_end);
            if gap_start == start && end == gap_end {
                gap_node.write(Node::Leaf(LeafNode::Used { flags }));
                if let Some((parent, _side)) = parent_and_side {
                    self.update_max_empty_area_data(parent);
                }
                Ok(gap_node)
            } else if gap_start < start && end == gap_end {
                let new_used_leaf = self.node_storage.new_used_leaf(pages_used, flags)?;
                let new_branch = self
                    .node_storage
                    .new_branch(
                        pages_used,
                        start,
                        parent_and_side.map(|(parent, _)| parent),
                        gap_node,
                        new_used_leaf,
                    )
                    .inspect_err(|_| new_used_leaf.free())?;
                gap_node
                    .unwrap_leaf()
                    .unwrap_empty_set_size(start - gap_start);
                self.link_in_branch(new_branch, parent_and_side);
                Ok(new_used_leaf)
            } else if gap_start == start && end < gap_end {
                let new_used_leaf = self.node_storage.new_used_leaf(pages_used, flags)?;
                let new_branch = self
                    .node_storage
                    .new_branch(
                        pages_used,
                        end + 1,
                        parent_and_side.map(|(parent, _)| parent),
                        new_used_leaf,
                        gap_node,
                    )
                    .inspect_err(|_| new_used_leaf.free())?;
                gap_node.unwrap_leaf().unwrap_empty_set_size(gap_end - end);
                self.link_in_branch(new_branch, parent_and_side);
                Ok(new_used_leaf)
            } else if gap_start < start && end < gap_end {
                let new_used_leaf = self.node_storage.new_used_leaf(pages_used, flags)?;
                let new_empty_leaf = self
                    .node_storage
                    .new_empty_leaf(pages_used, gap_end - end)
                    .inspect_err(|_| new_used_leaf.free())?;
                let new_end_branch = self
                    .node_storage
                    .new_branch(
                        pages_used,
                        end + 1,
                        parent_and_side.map(|(parent, _)| parent),
                        new_used_leaf,
                        new_empty_leaf,
                    )
                    .inspect_err(|_| {
                        new_empty_leaf.free();
                        new_used_leaf.free();
                    })?;
                // We allocate all nodes before linking them into the tree, so that we don't have
                // to deal with unlinking them in case of error.
                // In the case of this start branch though, that means we have to delay writing the
                // actual branch data until we've done the first bit of linking.
                let new_start_branch = self
                    .node_storage
                    .find_and_reserve_node(pages_used)
                    .inspect_err(|_| {
                        new_end_branch.free();
                        new_empty_leaf.free();
                        new_used_leaf.free();
                    })?;
                self.link_in_branch(new_end_branch, parent_and_side);
                let LeafInfo {
                    leaf: used_node,
                    parent_and_side,
                    start: _,
                    end: gap_end,
                } = self.get_leaf_containing(start);
                debug_assert_eq!(gap_end, end);
                // Now we actually write the start branch data.
                new_start_branch.write(Node::Branch(BranchNode::new(
                    start,
                    false,
                    NodeColor::Black,
                    parent_and_side.map(|(parent, _)| parent),
                    gap_node,
                    used_node,
                )));
                gap_node
                    .unwrap_leaf()
                    .unwrap_empty_set_size(start - gap_start);
                self.link_in_branch(new_start_branch, parent_and_side);
                Ok(used_node)
            } else {
                unreachable!();
            }
        }
    }

    pub fn get_leaf_containing(&self, addr: usize) -> LeafInfo {
        unsafe {
            debug_assert!(addr <= arch::process::HIGHEST_USER_ADDRESS);
            let mut current_parent_and_side: Option<(BranchNodePtr, Side)> = None;
            let mut current_node: NodePtr = self.root;
            let mut current_start: usize = 0;
            let mut current_end: usize = arch::process::HIGHEST_USER_ADDRESS.saturating_add(1);
            while let Node::Branch(branch) = current_node.read() {
                if addr < branch.pivot() {
                    debug_assert!(branch.pivot() <= current_end);
                    current_end = branch.pivot();
                    current_parent_and_side = Some((current_node.unwrap_branch(), Side::Left));
                    current_node = branch.left;
                } else {
                    debug_assert!(branch.pivot() >= current_start);
                    current_start = branch.pivot();
                    current_parent_and_side = Some((current_node.unwrap_branch(), Side::Right));
                    current_node = branch.right;
                }
            }
            LeafInfo {
                leaf: current_node,
                parent_and_side: current_parent_and_side,
                start: current_start,
                end: current_end - 1,
            }
        }
    }

    unsafe fn link_in_branch(
        &mut self,
        new_branch: NodePtr,
        new_parent_and_side: Option<(BranchNodePtr, Side)>,
    ) {
        unsafe {
            match new_parent_and_side {
                Some((new_parent, side)) => {
                    (&mut *new_parent.raw())[side] = new_branch;
                    new_branch.unwrap_branch().set_color(NodeColor::Red);
                    // Fix the tree if the properties are violated
                    if (*new_parent.raw()).parent.is_some() {
                        self.fix_insert(new_branch);
                    }
                }
                None => self.root = new_branch,
            }
            self.update_max_empty_area_data(new_branch.unwrap_branch());
        }
    }

    unsafe fn fix_insert(&mut self, node: NodePtr) {
        unsafe {
            let mut k = if node.is_branch() {
                node.unwrap_branch()
            } else {
                panic!();
            };
            while k.get_parent().color() == NodeColor::Red {
                if k.get_parent().is_right_side().unwrap() {
                    let u = (*k.get_grandparent().raw()).left;
                    match u.color() {
                        NodeColor::Red => {
                            u.unwrap_branch().set_color(NodeColor::Black);
                            k.get_parent().set_color(NodeColor::Black);
                            k.get_grandparent().set_color(NodeColor::Red);
                            k = k.get_grandparent();
                        }
                        NodeColor::Black => {
                            if k.is_left_side().unwrap() {
                                k = k.get_parent();
                                self.right_rotate(k);
                            }
                            k.get_parent().set_color(NodeColor::Black);
                            k.get_grandparent().set_color(NodeColor::Red);
                            self.left_rotate(k.get_grandparent());
                        }
                    }
                } else {
                    let u = (*k.get_grandparent().raw()).right;
                    match u.color() {
                        NodeColor::Red => {
                            u.unwrap_branch().set_color(NodeColor::Black);
                            k.get_parent().set_color(NodeColor::Black);
                            k.get_grandparent().set_color(NodeColor::Red);
                            k = k.get_grandparent();
                        }
                        NodeColor::Black => {
                            if k.is_right_side().unwrap() {
                                k = k.get_parent();
                                self.left_rotate(k);
                            }
                            k.get_parent().set_color(NodeColor::Black);
                            k.get_grandparent().set_color(NodeColor::Red);
                            self.right_rotate(k.get_grandparent());
                        }
                    }
                }
                if k.node_ptr() == self.root {
                    break;
                }
            }
            self.root.unwrap_branch().set_color(NodeColor::Black);
        }
    }

    /// Panics if `addr` does not belong to a used leaf node.
    pub fn delete(&mut self, addr: usize) {
        unsafe {
            let LeafInfo {
                leaf,
                parent_and_side,
                start: leaf_start,
                end: leaf_end,
            } = self.get_leaf_containing(addr);
            assert!(
                matches!(leaf.read(), Node::Leaf(LeafNode::Used { .. })),
                "{:?}",
                leaf.read()
            );
            (*leaf.raw()) = Node::Leaf(LeafNode::Empty {
                size: leaf_end + 1 - leaf_start,
            });
            if let Some((parent, side)) = parent_and_side {
                let sibling = parent.read()[!side];
                if sibling.is_empty_leaf() {
                    // If sibling is also an empty leaf, then combine their sizes and delete the
                    // parent.
                    let leaf_size = leaf.unwrap_leaf().unwrap_empty_size_ptr();
                    let sibling_size = sibling.unwrap_leaf().unwrap_empty_size_ptr();
                    let combined_size = leaf_size.read() + sibling_size.read();
                    leaf_size.write(combined_size);
                    sibling_size.write(combined_size);
                    self.delete_branch(parent);
                }
                'gap_join_loop: loop {
                    let LeafInfo {
                        leaf: _,
                        parent_and_side,
                        start: _,
                        end: _,
                    } = self.get_leaf_containing(addr);
                    // Update area sizes up to root
                    if let Some((parent, _side)) = parent_and_side {
                        self.update_max_empty_area_data(parent);
                    }
                    // Traverse up the tree from the new segment, delete useless pivots
                    let mut current_branch = parent_and_side.map(|(p, _)| p);
                    while let Some(branch) = current_branch {
                        let left_max = self.max_leaf((*branch.raw()).left);
                        let right_min = self.min_leaf((*branch.raw()).right);
                        if left_max.is_empty() && right_min.is_empty() {
                            // Combine sizes
                            let left_max_size = left_max.unwrap_empty_size_ptr();
                            let right_min_size = right_min.unwrap_empty_size_ptr();
                            let combined_size = left_max_size.read() + right_min_size.read();
                            left_max_size.write(combined_size);
                            right_min_size.write(combined_size);
                            // Delete splitting pivot
                            self.delete_branch(branch);
                            continue 'gap_join_loop;
                        } else {
                            current_branch = (*branch.raw()).parent;
                        }
                    }
                    break;
                }
            }
        }
    }

    unsafe fn delete_branch(&mut self, delete_branch: BranchNodePtr) {
        unsafe {
            let delete_node = delete_branch.node_ptr();
            let moved_up_node: NodePtr;
            let moved_up_node_parent: Option<BranchNodePtr>;
            let delete_node_color: NodeColor;
            if (*delete_branch.raw()).left.is_leaf() || (*delete_branch.raw()).right.is_leaf() {
                (moved_up_node, moved_up_node_parent) =
                    self.delete_node_with_zero_or_one_child(delete_branch);
                delete_node_color = delete_branch.color();
                delete_node.free();
            } else {
                // Node has two children
                let successor = self.find_min((*delete_branch.raw()).right.unwrap_branch());
                delete_branch.set_pivot(successor.pivot());
                delete_branch.set_max_empty_area_size((*successor.raw()).max_empty_area_size);
                (moved_up_node, moved_up_node_parent) =
                    self.delete_node_with_zero_or_one_child(successor);
                delete_node_color = successor.color();
                successor.node_ptr().free();
            }
            if delete_node_color == NodeColor::Black {
                let moved_up_branch = moved_up_node.unwrap_branch();
                self.fix_delete(moved_up_branch);
                if moved_up_branch.is_temp_null() {
                    let left_child = (*moved_up_branch.raw()).left;
                    let right_child = (*moved_up_branch.raw()).right;
                    if left_child.is_used_leaf() {
                        debug_assert!(
                            !right_child.is_used_leaf(),
                            "{:?}",
                            right_child.unwrap_leaf().unwrap_flags(),
                        );
                        (*moved_up_node.raw()) = (*moved_up_branch.raw()).left.read();
                        left_child.free();
                        right_child.free();
                    } else {
                        (*moved_up_node.raw()) = (*moved_up_branch.raw()).right.read();
                        left_child.free();
                        right_child.free();
                    }
                }
            }
            // Update adjacent subtree area sizes
            if let Some(parent) = moved_up_node_parent {
                self.update_max_empty_area_data(parent);
            }
        }
    }

    unsafe fn delete_node_with_zero_or_one_child(
        &mut self,
        node: BranchNodePtr,
    ) -> (NodePtr, Option<BranchNodePtr>) {
        unsafe {
            let parent = (*node.raw()).parent;
            if (*node.raw()).left.is_branch() {
                self.replace_node(node, (*node.raw()).left);
                debug_assert!(
                    !(*node.raw()).right.is_used_leaf(),
                    "{:?}",
                    (*node.raw()).right.unwrap_leaf().unwrap_flags(),
                );
                (*node.raw()).right.free();
                ((*node.raw()).left, parent)
            } else if (*node.raw()).right.is_branch() {
                self.replace_node(node, (*node.raw()).right);
                debug_assert!(
                    !(*node.raw()).left.is_used_leaf(),
                    "{:?}",
                    (*node.raw()).left.unwrap_leaf().unwrap_flags(),
                );
                (*node.raw()).left.free();
                ((*node.raw()).right, parent)
            } else {
                let new_child = match node.color() {
                    NodeColor::Black => {
                        let temp_node_ptr = self.node_storage.get_temp_node();
                        temp_node_ptr.write(Node::Branch(BranchNode::new(
                            0,
                            true,
                            NodeColor::Black,
                            None,
                            (*node.raw()).left,
                            (*node.raw()).right,
                        )));
                        temp_node_ptr
                    }
                    NodeColor::Red => {
                        if (*node.raw()).left.is_used_leaf() {
                            debug_assert!(
                                !(*node.raw()).right.is_used_leaf(),
                                "{:?}",
                                (*node.raw()).right.unwrap_leaf().unwrap_flags(),
                            );
                            (*node.raw()).right.free();
                            (*node.raw()).left
                        } else {
                            debug_assert!(
                                !(*node.raw()).left.is_used_leaf(),
                                "{:?}",
                                (*node.raw()).left.unwrap_leaf().unwrap_flags(),
                            );
                            (*node.raw()).left.free();
                            (*node.raw()).right
                        }
                    }
                };
                self.replace_node(node, new_child);
                (new_child, parent)
            }
        }
    }

    unsafe fn fix_delete(&mut self, mut node: BranchNodePtr) {
        unsafe {
            while node.node_ptr() != self.root {
                let mut sibling = node.get_sibling().unwrap_branch();
                if sibling.color() == NodeColor::Red {
                    self.handle_red_sibling(node, sibling);
                    sibling = node.get_sibling().unwrap_branch();
                }
                if (*sibling.raw()).left.color() == NodeColor::Black
                    && (*sibling.raw()).right.color() == NodeColor::Black
                {
                    sibling.set_color(NodeColor::Red);
                    if node.get_parent().color() == NodeColor::Red {
                        node.get_parent().set_color(NodeColor::Black);
                    } else {
                        node = node.get_parent();
                        continue;
                    }
                } else {
                    self.handle_black_sibling_at_least_one_red_child(node, sibling);
                }
                break;
            }
            if node.node_ptr() == self.root {
                node.set_color(NodeColor::Black);
            }
        }
    }

    unsafe fn handle_red_sibling(&mut self, node: BranchNodePtr, sibling: BranchNodePtr) {
        unsafe {
            sibling.set_color(NodeColor::Black);
            node.get_parent().set_color(NodeColor::Red);
            if node.is_left_side().unwrap() {
                self.left_rotate(node.get_parent());
            } else if node.is_right_side().unwrap() {
                self.right_rotate(node.get_parent());
            } else {
                unreachable!();
            }
        }
    }

    unsafe fn handle_black_sibling_at_least_one_red_child(
        &mut self,
        node: BranchNodePtr,
        mut sibling: BranchNodePtr,
    ) {
        unsafe {
            let is_left = node.is_left_side().unwrap();
            if is_left && (*sibling.raw()).right.color() == NodeColor::Black {
                (*sibling.raw())
                    .left
                    .unwrap_branch()
                    .set_color(NodeColor::Black);
                sibling.set_color(NodeColor::Red);
                self.right_rotate(sibling);
                sibling = (*node.get_parent().raw()).right.unwrap_branch();
            } else if !is_left && (*sibling.raw()).left.color() == NodeColor::Black {
                (*sibling.raw())
                    .right
                    .unwrap_branch()
                    .set_color(NodeColor::Black);
                sibling.set_color(NodeColor::Red);
                self.left_rotate(sibling);
                sibling = (*node.get_parent().raw()).left.unwrap_branch();
            }
            sibling.set_color(node.get_parent().color());
            node.get_parent().set_color(NodeColor::Black);
            if is_left {
                (*sibling.raw())
                    .right
                    .unwrap_branch()
                    .set_color(NodeColor::Black);
                self.left_rotate(node.get_parent());
            } else {
                (*sibling.raw())
                    .left
                    .unwrap_branch()
                    .set_color(NodeColor::Black);
                self.right_rotate(node.get_parent());
            }
        }
    }

    fn find_min(&self, mut node: BranchNodePtr) -> BranchNodePtr {
        unsafe {
            while (*node.raw()).left.is_branch() {
                node = (*node.raw()).left.unwrap_branch();
            }
            node
        }
    }

    fn min_leaf(&self, mut node: NodePtr) -> LeafNodePtr {
        unsafe {
            while let Some(branch) = node.branch() {
                node = (*branch.raw()).left;
            }
            node.unwrap_leaf()
        }
    }

    fn max_leaf(&self, mut node: NodePtr) -> LeafNodePtr {
        unsafe {
            while let Some(branch) = node.branch() {
                node = (*branch.raw()).right;
            }
            node.unwrap_leaf()
        }
    }

    fn update_max_empty_area_data(&mut self, lowest_branch: BranchNodePtr) {
        unsafe {
            let mut current_branch_ptr = Some(lowest_branch);
            while let Some(branch_ptr) = current_branch_ptr {
                let branch = branch_ptr.read();
                let mut current_max = 0;
                for child in [branch.left, branch.right] {
                    let child_max_empty_area_size = match child.read() {
                        Node::Branch(child_branch) => child_branch.max_empty_area_size,
                        Node::Leaf(LeafNode::Used { .. }) => 0,
                        Node::Leaf(LeafNode::Empty { size }) => size,
                    };
                    current_max = usize::max(current_max, child_max_empty_area_size);
                }
                branch_ptr.set_max_empty_area_size(current_max);
                current_branch_ptr = branch.parent;
            }
        }
    }

    unsafe fn replace_node(&mut self, old_branch: BranchNodePtr, new_node: NodePtr) {
        unsafe {
            match old_branch.is_left_side() {
                Some(true) => (*old_branch.get_parent().raw()).left = new_node,
                Some(false) => (*old_branch.get_parent().raw()).right = new_node,
                None => self.root = new_node,
            }
            if let Some(branch) = new_node.branch() {
                (*branch.raw()).parent = (*old_branch.raw()).parent;
            }
        }
    }

    unsafe fn left_rotate(&mut self, node: BranchNodePtr) {
        unsafe {
            let right_node = (*node.raw()).right;
            let right = right_node.unwrap_branch();
            (*node.raw()).right = (*right.raw()).left;
            if let Node::Branch(branch) = &mut *(*right.raw()).left.raw() {
                branch.parent = Some(node);
            }
            (*right.raw()).parent = (*node.raw()).parent;
            match node.is_left_side() {
                Some(true) => (*node.get_parent().raw()).left = right_node,
                Some(false) => (*node.get_parent().raw()).right = right_node,
                None => self.root = right_node,
            }
            (*right.raw()).left = node.node_ptr();
            (*node.raw()).parent = Some(right);
            node.recalculate_max_empty_area_size();
            right.recalculate_max_empty_area_size();
        }
    }

    unsafe fn right_rotate(&mut self, node: BranchNodePtr) {
        unsafe {
            let left_node = (*node.raw()).left;
            let left = left_node.unwrap_branch();
            (*node.raw()).left = (*left.raw()).right;
            if let Node::Branch(branch) = &mut *(*left.raw()).right.raw() {
                branch.parent = Some(node);
            }
            (*left.raw()).parent = (*node.raw()).parent;
            match node.is_left_side() {
                Some(true) => (*node.get_parent().raw()).left = left_node,
                Some(false) => (*node.get_parent().raw()).right = left_node,
                None => self.root = left_node,
            }
            (*left.raw()).right = node.node_ptr();
            (*node.raw()).parent = Some(left);
            node.recalculate_max_empty_area_size();
            left.recalculate_max_empty_area_size();
        }
    }
}

impl Drop for VMATree {
    fn drop(&mut self) {
        // Drop the tree recursively.
        // As this is a roughly-balanced binary tree, the maximum depth should be pretty low, so
        // we shouldn't have any issues around overflowing the kernel stack.
        unsafe fn drop_subtree(node: NodePtr) {
            unsafe {
                if let Node::Branch(branch) = &*node.raw() {
                    drop_subtree(branch.left);
                    drop_subtree(branch.right);
                }
                node.free();
            }
        }
        unsafe {
            drop_subtree(self.root);
        }
    }
}

#[derive(Debug)]
pub struct MapTask {
    map_mem_task: MapMemTask,
}

impl MapTask {
    /// If this completes, returns the total number of pages freed.
    pub fn run<F>(&mut self, allocator: &mut VMAAllocator, mut should_suspend: F) -> Poll<Result<usize, MapMemError>>
    where
        F: FnMut() -> bool,
    {
        match self
            .map_mem_task
            .run(&mut allocator.page_mapper, &mut should_suspend)
        {
            Poll::Pending => Poll::Pending,
            err @ Poll::Ready(Err(_)) => err,
            Poll::Ready(Ok(pages_allocated)) => {
                let mut tree = allocator.tree.lock();
                let start_address = self.map_mem_task.start_address();
                let LeafInfo { leaf, .. } = tree.get_leaf_containing(start_address);
                unsafe {
                    let flags = leaf.unwrap_leaf().unwrap_used_flags_ptr().as_ptr();
                    debug_assert!((*flags).locked());
                    (&mut *flags).set_locked(false);
                }
                tree.delete(start_address);
                Poll::Ready(Ok(pages_allocated))
            }
        }
    }
}

#[derive(Debug)]
pub struct UnmapTask {
    start_address: usize,
    unmap_mem_task: UnmapMemTask,
}

impl UnmapTask {
    /// If this completes, returns the total number of pages freed.
    pub fn run<F>(&mut self, allocator: &mut VMAAllocator, mut should_suspend: F) -> Poll<usize>
    where
        F: FnMut() -> bool,
    {
        match self
            .unmap_mem_task
            .run(&mut allocator.page_mapper, &mut should_suspend)
        {
            Poll::Pending => Poll::Pending,
            Poll::Ready(pages_freed) => {
                let mut tree = allocator.tree.lock();
                tree.delete(self.start_address);
                Poll::Ready(pages_freed)
            }
        }
    }
}
