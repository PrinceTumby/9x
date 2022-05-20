const std = @import("std");
const builtin = @import("builtin");

pub fn OverridenNamespace(comptime namespace: type, comptime overriding_namespace: type) type {
    // Check namespaces are of correct type
    if (@typeInfo(namespace) != .Struct)
        @compileError("`namespace` must be a struct");
    if (@typeInfo(overriding_namespace) != .Struct)
        @compileError("`overriding_namespace` must be a struct");
    const namespace_info = @typeInfo(namespace).Struct;
    const overriding_info = @typeInfo(overriding_namespace).Struct;
    if (namespace_info.is_tuple)
        @compileError("`namespace` must be a struct");
    if (namespace_info.is_tuple)
        @compileError("`overriding_info` must be a struct");
    // Check namespaces don't contain fields
    // if (namespace_info.fields.len != 0)
    //     @compileError("`namespace` should only contain constant declarations");
    if (overriding_info.fields.len != 0)
        @compileError("`overriding_info` should only contain constant declarations");
    // Check all fields are public variable declarations
    // for (namespace_info.decls) |decl| {
    //     if (decl.data != .Var)
    //         @compileError("`namespace` should only contain constant declarations");
    // }
    for (overriding_info.decls) |decl| {
        if (decl.data != .Var)
            @compileError("`overriding_info` should only contain constant declarations");
    }
    // Map overriding declarations onto namespace, return modified namespace
    var new_fields: [namespace_info.fields.len]builtin.TypeId.StructField = undefined;
    var new_fields_len: usize = 0;
    // outer: for (namespace_info.decls) |decl, i| {
    outer: for (namespace_info.fields) |field, i| {
        // Get the overriding declaration if it exists, otherwise copy the declaration across
        // to the modified namespace
        const overriding_decl = blk: for (overriding_info.decls) |overriding_decl| {
            // if (std.mem.eql(u8, decl.name, overriding_decl.name)) break :blk overriding_decl;
            if (std.mem.eql(u8, field.name, overriding_decl.name)) break :blk overriding_decl;
        } else {
            // new_fields[i] = builtin.TypeId.StructField{
            //     .name = decl.name,
            //     .field_type = decl.data.Var,
            //     .default_value = @field(namespace, decl.name),
            //     .is_comptime = false,
            //     .alignment = @alignOf(decl.data.Var),
            // };
            new_fields[i] = builtin.TypeId.StructField{
                .name = field.name,
                .field_type = field.field_type,
                .default_value = field.default_value,
                .is_comptime = field.is_comptime,
                .alignment = field.alignment,
            };
            new_fields_len += 1;
            continue :outer;
        };
        // Check overriding declaration type
        if (@typeInfo(overriding_decl.data.Var) != .Optional)
            @compileError("Override type of `" ++ decl.name ++ "` must be optional of original");
        // if (@typeInfo(overriding_decl.data.Var).Optional.child != decl.data.Var)
        if (@typeInfo(overriding_decl.data.Var).Optional.child != field.field_type)
            @compileError("Override type of `" ++ decl.name ++ "` must be optional of original");
        // const override = @field(overriding_namespace, decl.name);
        const override = @field(overriding_namespace, field.name);
        new_fields[i] = if (override != null) builtin.TypeId.StructField{
            // .name = decl.name,
            // .field_type = decl.data.Var,
            // .default_value = override,
            // .is_comptime = true,
            // .alignment = @alignOf(decl.data.Var),
            .name = field.name,
            .field_type = field.field_type,
            .default_value = override,
            .is_comptime = true,
            .alignment = field.alignment,
        } else builtin.TypeId.StructField{
            .name = field.name,
            .field_type = field.field_type,
            .default_value = field.default_value,
            .is_comptime = field.is_comptime,
            .alignment = field.alignment,
        };
        new_fields_len += 1;
    }
    return @Type(builtin.TypeInfo{.Struct = .{
        .layout = .Auto,
        .fields = new_fields[0..new_fields_len],
        .decls = &[0]builtin.TypeId.Declaration{},
        .is_tuple = false,
    }});
}

pub inline fn isComptime(
    namespace_ptr: anytype,
    comptime field: @TypeOf(.EnumLiteral),
) void {
    comptime {
        if (@typeInfo(@TypeOf(namespace_ptr)) != .Pointer)
            @compileError("`namespace_ptr` must be a pointer to a namespace");
        const namespace_ptr_info = @typeInfo(@TypeOf(namespace_ptr)).Pointer;
        if (namespace_ptr_info.size != .One)
            @compileError("`namespace_ptr` must be a single pointer to namespace");
        const namespace_type = namespace_ptr_info.child;
        if (@typeInfo(namespace_type) != .Struct)
            @compileError("`namespace_ptr` must point to a valid namespace");
        const info = @typeInfo(namespace_type).Struct;
        if (info.is_tuple)
            @compileError("`namespace_ptr` must point to a valid namespace");
        comptime var found_field = false;
        for (info.fields) |namespace_field| {
            if (comptime std.mem.eql(u8, namespace_field.name, @tagName(field))) {
                found_field = true;
                return namespace_field.is_comptime;
            }
        } else {
            @compileError("`" ++ @tagName(field) ++ "` does not exist in namespace");
        }
    }
}

pub inline fn trySet(
    namespace_ptr: anytype,
    comptime field: @TypeOf(.EnumLiteral),
    value: anytype,
) void {
    if (@typeInfo(@TypeOf(namespace_ptr)) != .Pointer)
        @compileError("`namespace_ptr` must be a pointer to a namespace");
    const namespace_ptr_info = @typeInfo(@TypeOf(namespace_ptr)).Pointer;
    if (namespace_ptr_info.size != .One)
        @compileError("`namespace_ptr` must be a single pointer to namespace");
    const namespace_type = namespace_ptr_info.child;
    if (@typeInfo(namespace_type) != .Struct)
        @compileError("`namespace_ptr` must point to a valid namespace");
    const info = @typeInfo(namespace_type).Struct;
    if (info.is_tuple)
        @compileError("`namespace_ptr` must point to a valid namespace");
    comptime var found_field = false;
    inline for (info.fields) |namespace_field| {
        if (comptime std.mem.eql(u8, namespace_field.name, @tagName(field))) {
            found_field = true;
            if (!namespace_field.is_comptime)
                @field(namespace_ptr, @tagName(field)) = value;
            return;
        }
    }
    if (!found_field)
        @compileError("`" ++ @tagName(field) ++ "` does not exist in namespace");
}

// Tests

test "basic properties" {
    // const test_props_dynamic = struct {
    //     const unmentioned: bool = false;
    //     const unaffected: usize = 2;
    //     const overriden: u8 = 0x0;
    // };
    const test_props_dynamic = struct {
        unmentioned: bool = false,
        unaffected: usize = 2,
        overriden: u8 = 0x0,
    };
    const test_props_override = struct {
        pub const unaffected: ?usize = null;
        pub const overriden: ?u8 = 0xFF;
    };
    const TestProps = OverridenNamespace(test_props_dynamic, test_props_override);
    var test_props: TestProps = TestProps{
        .unmentioned = false,
        .unaffected = 3,
        .overriden = 0xFF,
    };
    std.testing.expectEqual(false, test_props.unmentioned);
    std.testing.expectEqual(@as(usize, 3), test_props.unaffected);
    std.testing.expectEqual(@as(usize, 0xFF), test_props.overriden);
    trySet(&test_props, .unmentioned, true);
    trySet(&test_props, .unaffected, 5);
    trySet(&test_props, .overriden, 0xEE);
    std.testing.expectEqual(true, test_props.unmentioned);
    std.testing.expectEqual(@as(usize, 5), test_props.unaffected);
    std.testing.expectEqual(@as(u8, 0xFF), test_props.overriden);
}
