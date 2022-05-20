// Functions and data structures to decode the cpio format (used in initrd)

const std = @import("std");

pub const CpioNode = extern struct {
    magic: [6]u8 = magic_marker,
    device: [6]u8,
    i_number: [6]u8,
    mode: [6]u8,
    user_id: [6]u8,
    group_id: [6]u8,
    num_links: [6]u8,
    r_device: [6]u8,
    modified_time: [11]u8,
    name_len: [6]u8,
    file_len: [11]u8,

    const name_offset = 76;
    const magic_const: [6]u8 = [_]u8{ '0', '7', '0', '7', '0', '7' };
};

pub fn octalToBinary(string: []const u8) u64 {
    var number: u64 = 0;
    for (string) |digit| {
        number <<= 3;
        number += digit -% '0';
    }
    return number;
}

test "Octal To Binary" {
    std.testing.expectEqual(0o070707, comptime octalToBinary("070707"));
    std.testing.expectEqual(0o32, comptime octalToBinary("000032"));
    std.testing.expectEqual(0o4040, comptime octalToBinary("00000004040"));
}

pub fn cpioFindFile(archive: []const u8, file_name: []const u8) ?[]const u8 {
    var cur_pos: usize = 0;
    loop: while (cur_pos < archive.len) {
        const node = @ptrCast(*const CpioNode, &archive[cur_pos]);
        const node_file_size = octalToBinary(node.file_len[0..node.file_len.len]);
        const node_name_len = octalToBinary(node.name_len[0..node.name_len.len]);
        const node_file_name = archive[cur_pos + CpioNode.name_offset .. cur_pos + CpioNode.name_offset + node_name_len - 1];
        // Check magic
        {
            comptime var i: usize = 0;
            inline while (i < node.magic.len) : (i += 1) {
                if (node.magic[i] != CpioNode.magic_const[i]) {
                    return null;
                }
            }
        }
        // Check file name
        {
            if (node_name_len - 1 != file_name.len) {
                cur_pos += 76 + node_name_len + node_file_size;
                continue :loop;
            }
            var i: usize = 0;
            while (i < node_name_len - 1) : (i += 1) {
                if (node_file_name[i] != file_name[i]) {
                    cur_pos += CpioNode.name_offset + node_name_len + node_file_size;
                    continue :loop;
                }
            }
        }
        return archive[cur_pos + CpioNode.name_offset + node_name_len .. cur_pos + CpioNode.name_offset + node_name_len + node_file_size];
    }
    return null;
}
