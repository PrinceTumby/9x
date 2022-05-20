const std = @import("std");
const Declaration = std.builtin.TypeInfo.Declaration;
const Interface = @This();

internal: type,

// TODO Implement support for nesting interfaces

pub fn init(comptime interface_struct: type) Interface {
    if (@typeInfo(interface_struct) != .Struct)
        @compileError("Interface reference type must be a struct type");
    const info = @typeInfo(interface_struct).Struct;
    if (info.is_tuple)
        @compileError("Interface reference type must not be a tuple");
    for (info.decls) |decl| {
        if (!decl.is_pub)
            @compileError("Interface reference type must only contain public declarations");
        if (decl.data != .Type and !(decl.data == .Var and decl.data.Var == Interface))
            @compileError("Interface reference type must only contain type declarations or" ++
                " nested interfaces");
    }
    return Interface{ .internal = interface_struct };
}

pub fn verifyImplementation(comptime self: Interface, comptime implementation: type) void {
    comptime {
        if (@typeInfo(implementation) != .Struct)
            @compileError("Implementation must be a struct type");
        if (self.verifyImplementationInner(implementation)) |err_msg| {
            @compileError(err_msg);
        }
    }
}

fn verifyImplementationInner(comptime self: Interface, comptime implementation: type) ?[]const u8 {
    comptime {
        if (@typeInfo(implementation) != .Struct)
            return "Nested implementation must be a struct type";
        const interface_info = @typeInfo(self.internal).Struct;
        const implementation_info = @typeInfo(implementation).Struct;
        // Check that all interface declarations exist in implementation
        for (interface_info.decls) |interface_decl| {
            implementation_loop: for (implementation_info.decls) |implementation_decl| {
                // Check the name, check if it's public, check they're the same type
                if (!std.mem.eql(u8, interface_decl.name, implementation_decl.name)) continue;
                if (!implementation_decl.is_pub) return "`" ++
                    interface_decl.name ++
                    "` exists in implementation but is not public";
                if (interface_decl.data == .Var) {
                    // Check nested interface
                    const inner_interface = @field(self, interface_decl.name);
                    const inner_module = @field(implementation, interface_decl.name);
                    if (inner_interface.verifyImplementationInner(inner_module)) |err_msg| {
                        return err_msg ++ "\nNested inside " ++ interface_decl.name;
                    }
                }
                const maybe_impl_type: ?type = switch (implementation_decl.data) {
                    .Type => if (interface_decl.data.Type != type) blk: {
                        break :blk implementation_decl.data.Type;
                    } else null,
                    .Var => |var_type| if (interface_decl.data.Type != var_type) blk: {
                        break :blk var_type;
                    } else null,
                    .Fn => |func_info| if (interface_decl.data.Type != func_info.fn_type) blk: {
                        break :blk func_info.fn_type;
                    } else null,
                };
                if (maybe_impl_type) |impl_type| {
                    return "Type of `" ++
                        interface_decl.name ++
                        "` differs between interface and implementation, interface has type " ++
                        @typeName(interface_decl.data.Type) ++
                        ", implementation has type " ++
                        @typeName(impl_type);
                }
                break;
            } else {
                return "`" ++
                    interface_decl.name ++
                    "` in interface does not appear in implementation";
            }
        }
        // Check that all public implementation declarations appear in interface
        for (implementation_info.decls) |implementation_decl| {
            if (!implementation_decl.is_pub) continue;
            for (interface_info.decls) |interface_decl| {
                if (std.mem.eql(u8, interface_decl.name, implementation_decl.name)) break;
            } else {
                "`" ++
                    implementation_decl.name ++
                    "` is public in implementation but does not appear in interface";
            }
        }
        return null;
    }
}
