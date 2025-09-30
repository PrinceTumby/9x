use core::mem::size_of;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Node {
    pub magic: [u8; 6],
    pub device: [u8; 6],
    pub i_number: [u8; 6],
    pub mode: [u8; 6],
    pub user_id: [u8; 6],
    pub group_id: [u8; 6],
    pub num_links: [u8; 6],
    pub r_device: [u8; 6],
    pub modified_time: [u8; 11],
    name_len_octal: [u8; 6],
    file_size_octal: [u8; 11],
}

impl Node {
    pub const NAME_OFFSET: usize = 76;
    pub const MAGIC: &[u8; 6] = b"070707";

    /// Returns the length of the node's ASCII name plus the NULL byte at the end.
    pub fn get_name_cstring_len(&self) -> usize {
        octal_to_binary(&self.name_len_octal)
    }

    pub fn get_file_size(&self) -> usize {
        octal_to_binary(&self.file_size_octal)
    }
}

pub fn octal_to_binary(octal: &[u8]) -> usize {
    let mut number = 0;
    for digit in octal {
        number <<= 3;
        number += (digit - b'0') as usize;
    }
    number
}

pub fn find_file<'a>(archive: &'a [u8], file_name: &[u8]) -> Option<&'a [u8]> {
    let mut current_pos = 0;
    while current_pos < archive.len() {
        let node = unsafe {
            // Check enough bytes exist for a Node
            if archive.len() - current_pos + 1 < size_of::<Node>() {
                break;
            }
            (&archive[current_pos] as *const u8 as *const Node)
                .as_ref()
                .unwrap_unchecked()
        };
        let node_name_len = node.get_name_cstring_len();
        let node_file_size = node.get_file_size();
        let node_name = &archive[current_pos + Node::NAME_OFFSET..][0..node_name_len - 1];
        // Check magic
        if &node.magic != Node::MAGIC {
            break;
        }
        // Check file name
        if file_name != node_name {
            current_pos += 76 + node_name_len + node_file_size;
            continue;
        }
        return Some(
            &archive[current_pos + Node::NAME_OFFSET + node_name_len..][0..node_file_size],
        );
    }
    None
}
