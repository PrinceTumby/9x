//! Writer based text formatting

const std = @import("std");

const ArgRef = usize;

const WriteObject = union(enum) {
    TextLiteral: []const u8,
    GenericArgRef: ArgRef,
    StringSlice: ArgRef,
    ASCIICharacter: ArgRef,
    IntegerHex: struct {
        reference: ArgRef,
        uppercase: bool,
    },
    Pointer: ArgRef,
};

fn Stack(comptime ItemType: type) type {
    return struct {
        array: []ItemType,
        top: usize,

        const Self = @This();

        pub fn new(backing_array: []ItemType) Self {
            return Self{
                .array = backing_array,
                .top = 0,
            };
        }

        pub fn push(self: *Self, item: ItemType) void {
            if (self.top >= self.array.len) {
                @panic("stack array overflow");
            }
            self.array[self.top] = item;
            self.top += 1;
        }

        pub fn pop(self: *Self) ?ItemType {
            if (self.top == 0) {
                return null;
            } else {
                defer self.top -= 1;
                return self.array[self.top];
            }
        }

        pub fn clear(self: *Self) void {
            self.top = 0;
        }

        pub fn getSlice(self: *const Self) []ItemType {
            return self.array[0..self.top];
        }
    };
}

fn parseFmtString(comptime fmt: []const u8, object_storage: []WriteObject) []const WriteObject {
    var text_slices = Stack(WriteObject).new(object_storage);
    const State = enum {
        TextSlice,
        FormatSpecifier,
    };
    var current_state: State = .TextSlice;
    var selection_start: usize = 0;
    var arg_ref: usize = 0;
    var pos: usize = 0;
    while (pos < fmt.len) {
        const char = fmt[pos];
        switch (current_state) {
            .TextSlice => switch (char) {
                '{' => {
                    pos += 1;
                    if (pos >= fmt.len) @compileError("Trailing open brace, use '{{' to escape.");
                    const next_char = fmt[pos];
                    if (next_char == '{') {
                        // Create text literal gap around escaped brace
                        text_slices.push(.{.TextLiteral = fmt[selection_start..pos]});
                        pos += 1;
                        selection_start = pos;
                    } else {
                        // Format specifier, so push slice and switch state
                        text_slices.push(.{.TextLiteral = fmt[selection_start .. pos - 1]});
                        selection_start = pos;
                        current_state = .FormatSpecifier;
                    }
                },
                '}' => {
                    pos += 1;
                    if (pos >= fmt.len) @compileError("Trailing close brace, use '}}' to escape.");
                    const next_char = fmt[pos];
                    if (next_char == '}') {
                        // Create text literal gap around escaped brace
                        text_slices.push(.{.TextLiteral = fmt[selection_start..pos]});
                        pos += 1;
                        selection_start = pos;
                    } else {
                        @compileError("Unmatched closing brace, use '}}' to escape.");
                    }
                },
                else => pos += 1,
            },
            .FormatSpecifier => switch (char) {
                '}' => {
                    // End of specifier, so push object and switch state
                    const specifier = fmt[selection_start..pos];
                    if (std.mem.eql(u8, specifier, "")) {
                        text_slices.push(.{.GenericArgRef = arg_ref});
                    } else if (std.mem.eql(u8, specifier, "s")) {
                        text_slices.push(.{.StringSlice = arg_ref});
                    } else if (std.mem.eql(u8, specifier, "c")) {
                        text_slices.push(.{.ASCIICharacter = arg_ref});
                    } else if (std.mem.eql(u8, specifier, "x")) {
                        text_slices.push(.{.IntegerHex = .{
                            .reference = arg_ref,
                            .uppercase = false,
                        }});
                    } else if (std.mem.eql(u8, specifier, "X")) {
                        text_slices.push(.{.IntegerHex = .{
                            .reference = arg_ref,
                            .uppercase = true,
                        }});
                    } else if (std.mem.eql(u8, specifier, "*")) {
                        text_slices.push(.{.Pointer = arg_ref});
                    } else {
                        @compileError("Unknown format specifier: {" ++ specifier ++ "}");
                    }
                    arg_ref += 1;
                    pos += 1;
                    selection_start = pos;
                    current_state = .TextSlice;
                },
                else => pos += 1,
            },
        }
    }
    if (current_state == .FormatSpecifier) {
        @compileError("Unmatched open brace, use '{{' to escape");
    }
    // Append final text slice
    if (selection_start < pos) {
        text_slices.push(.{.TextLiteral = fmt[selection_start..pos]});
    }
    return text_slices.getSlice();
}

pub fn format(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    comptime var object_backing_array: [256]WriteObject = undefined;
    comptime const format_objects = parseFmtString(fmt, &object_backing_array);
    inline for (format_objects) |object| {
        switch (object) {
            .TextLiteral => |slice| try writer.writeAll(slice),
            .StringSlice => |index| {
                if (index >= args.len) @compileError("{s} specifier missing matching argument");
                try writer.writeAll(args[index]);
            },
            .ASCIICharacter => |index| {
                if (index >= args.len) @compileError("{c} specifier missing matching argument");
                try writer.writeByte(args[index]);
            },
            .GenericArgRef => |index| {
                if (index >= args.len) @compileError("{} specifier missing matching argument");
                const ArgType = @TypeOf(args[index]);
                switch (@typeInfo(ArgType)) {
                    .Type => try writer.writeAll(@typeName(args[index])),
                    .Void => try writer.writeAll("void"),
                    .Bool => try writeBool(writer, args[index]),
                    .Int => try writeInt(writer, args[index]),
                    .ComptimeInt => try writeComptimeInt(writer, args[index]),
                    .Enum => |info| {
                        const enum_name = @typeName(ArgType);
                        try writer.writeAll(enum_name);
                        try writer.writeByte('.');
                        if (!info.is_exhaustive) {
                            const enum_value = @enumToInt(args[index]);
                            var found_value = false;
                            inline for (info.fields) |field| blk: {
                                if (enum_value == field.value) {
                                    try writer.writeAll(@tagName(args[index]));
                                    found_value = true;
                                    break :blk;
                                }
                            }
                            if (!found_value) {
                                try writeInt(writer, enum_value);
                            }
                        } else {
                            try writer.writeAll(@tagName(args[index]));
                        }
                    },
                    else => @compileError(
                        "{} specifier doesn't know how to parse argument of type " ++
                        @typeName(ArgType)
                    ),
                }
            },
            .IntegerHex => |hex| {
                if (hex.uppercase == false and hex.reference >= args.len) {
                    @compileError("{x} specifier missing matching argument");
                } else if (hex.uppercase == true and hex.reference >= args.len) {
                    @compileError("{X} specifier missing matching argument");
                }
                try writeHex(writer, args[hex.reference], hex.uppercase);
            },
            .Pointer => |index| {
                if (index >= args.len) @compileError("{*} specifier missing matching argument");
                const info = @typeInfo(@TypeOf(args[index]));
                if (info != .Pointer) @compileError(
                    "{*} expected pointer argument, got type " ++
                    @typeName(@TypeOf(args[index])));
                try writer.writeAll(@typeName(info.Pointer.child));
                try writer.writeByte('@');
                try writeHex(writer, @ptrToInt(args[index]), false);
            }
        }
    }
}

fn writeBool(writer: anytype, arg: bool) !void {
    switch (arg) {
        false => try writer.writeAll("false"),
        true => try writer.writeAll("true"),
    }
}

fn writeComptimeInt(writer: anytype, num: comptime_int) !void {
    if (num >= 0) {
        try writeUnsignedInt(writer, @as(usize, num));
    } else {
        try writeSignedInt(writer, @as(isize, num));
    }
}

fn writeInt(writer: anytype, num: anytype) !void {
    const info = @typeInfo(@TypeOf(num));
    if (info != .Int) @compileError("Expected an integer type, got " ++ @typeName(@TypeOf(num)));
    switch (info.Int.is_signed) {
        false => try writeUnsignedInt(writer, num),
        true => try writeSignedInt(writer, num),
    }
}

fn writeUnsignedInt(writer: anytype, num: anytype) !void {
    const NumType = @TypeOf(num);
    const num_digits = comptime @floatToInt(usize, @log2(@intToFloat(f64, @bitSizeOf(NumType))));
    if (num == 0) {
        try writer.writeByte('0');
        return;
    }
    var digit_buffer: [num_digits]u8 = undefined;
    var current_num = num;
    var digit_buffer_end: usize = 0;
    while (current_num != 0) : (digit_buffer_end += 1) {
        var digit = @truncate(u8, current_num % 10);
        digit_buffer[digit_buffer_end] = '0' + digit;
        current_num /= 10;
    }
    var index: usize = digit_buffer_end;
    while (index > 0) : (index -= 1) {
        try writer.writeByte(digit_buffer[index - 1]);
    }
}

fn writeSignedInt(writer: anytype, num: anytype) !void {
    // TODO Implement signed integer formatting
    unreachable;
}

fn writeHex(writer: anytype, num: anytype, uppercase: bool) !void {
    const NumType = @TypeOf(num);
    const info = @typeInfo(NumType);
    if (info != .Int) {
        @compileError("Hex formatting only allowed for integer types, got " ++ @typeName(NumType));
    } else if (info.Int.is_signed == true) {
        @compileError("Hex formatting only allowed for unsigned integers");
    } else if (info.Int.bits > @bitSizeOf(usize)) {
        @compileError("Hex formatting only allowed for integer sizes up to `u64`");
    }
    if (num == 0) {
        try writer.writeByte('0');
        return;
    }
    var current_num: u64 = num;
    var seen_digit: bool = false;
    var count: usize = 0;
    while (count < @bitSizeOf(@TypeOf(current_num)) / 4) : (count += 1) {
        const digit: u8 = @truncate(u8, current_num >> 60) & 0xF;
        if (digit == 0 and seen_digit) {
            try writer.writeByte('0');
        } else {
            if (digit != 0) seen_digit = true;
            switch (digit) {
                1...9 => try writer.writeByte('0' + digit),
                10...15 => switch (uppercase) {
                    false => try writer.writeByte('a' + digit - 10),
                    true => try writer.writeByte('A' + digit - 10),
                },
                else => {},
            }
        }
        current_num <<= 4;
    }
}
