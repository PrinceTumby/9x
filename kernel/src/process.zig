//! Implementation of process, both user and kernel. Includes main structures and scheduling.

const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const elf = @import("elf.zig");
const smp = @import("smp.zig");
const heap_allocator = root.heap.heap_allocator_ptr;
const asmSymbolFmt = root.zig_extensions.asmSymbolFmt;
const VirtualPageMapper = arch.virtual_page_mapping.VirtualPageMapper;
const PageAllocator = arch.page_allocation.PageAllocator;
const Elf = elf.Elf;
const SpinLock = smp.SpinLock;
const RegisterStore = arch.common.process.RegisterStore;
const KernelMainRegisterStore = arch.common.process.KernelMainRegisterStore;
const highest_program_segment_address = arch.common.process.highest_program_segment_address;
const isProgramSegmentAddressValid = arch.common.process.isProgramSegmentAddressValid;

/// Pending processes, implemented as 256 priorities of doubly linked lists
pub const process_list = struct {
    var process_list_lock: SpinLock = SpinLock.init();
    var pending_processes = [1]Priority{.{.head = null, .tail = null}} ** 256;

    const Priority = struct {
        head: ?*Process = null,
        tail: ?*Process = null,
    };

    /// Pushes a process onto the given priority list
    pub fn push(priority: u8, process: *Process) void {
        const lock = process_list_lock.acquire();
        defer lock.release();
        const priority_ptr = &pending_processes[priority];
        process.previous_process = priority_ptr.tail;
        if (priority_ptr.tail) |tail| {
            tail.next_process = process;
            priority_ptr.tail = process;
        } else {
            priority_ptr.head = process;
            priority_ptr.tail = process;
        }
    }

    /// Tries to pop a process of any priority. Favors higher priority tasks.
    pub fn tryPop() ?*Process {
        const lock = process_list_lock.acquire();
        defer lock.release();
        for (pending_processes) |*priority| {
            const head = priority.head orelse continue;
            if (head.next_process) |next_process| next_process.previous_process = null;
            priority.head = head.next_process;
            if (priority.tail == head) priority.tail = null;
            head.previous_process = null;
            head.next_process = null;
            return head;
        } else return null;
    }
};

pub const Process = struct {
    previous_process: ?*Process = null,
    next_process: ?*Process = null,
    process_type: Type,
    id: u64,
    stack_lower_limit: u64,
    stack_upper_limit: u64,
    stack_flags: u64,
    registers: RegisterStore = .{},
    page_mapper: VirtualPageMapper,

    pub const Type = enum {
        Kernel,
        User,
    };

    comptime {
        @setEvalBranchQuota(5000);
        asm (asmSymbolFmt("Process.id", @byteOffsetOf(Process, "id")));
        asm (asmSymbolFmt(
            "Process.registers.start_register",
            @byteOffsetOf(Process, "registers") +
            RegisterStore.start_register_offset,
        ));
        asm (asmSymbolFmt(
            "Process.registers.end_register",
            @byteOffsetOf(Process, "registers") +
            RegisterStore.end_register_offset,
        ));
        asm (asmSymbolFmt(
            "Process.registers.vector_store",
            @byteOffsetOf(Process, "registers") +
            RegisterStore.vector_store_offset,
        ));
        asm (asmSymbolFmt(
            "Process.page_mapper.page_table",
            @byteOffsetOf(Process, "page_mapper") +
            @byteOffsetOf(VirtualPageMapper, "page_table"),
        ));
    }

    var process_id_counter: u64 = 0;

    pub fn initUserProcessFromElfFile(elf_file: []const u8) !Process {
        const program_elf = (try Elf.init(elf_file)).Bit64;
        var mem_mapper = try VirtualPageMapper.init(arch.page_allocation.page_allocator_ptr);
        errdefer mem_mapper.deinit();
        var gnu_stack_entry: ?Elf.Elf64.ProgramHeaderEntry = null;
        // Allocate segments
        for (program_elf.program_header) |*entry| {
            switch (entry.type) {
                .Loadable => {},
                .GnuStack => {
                    gnu_stack_entry = entry.*;
                    continue;
                },
                else => continue,
            }
            // Get segment in program file
            const segment_slice = @ptrCast(
                [*]const u8,
                &program_elf.file[entry.segment_offset],
            )[0..entry.segment_image_size];
            // Map segment to process memory
            try mem_mapper.mapMemCopyFromBuffer(
                entry.segment_virt_addr,
                entry.segment_memory_size,
                segment_slice,
            );
            // Set flags for segment
            mem_mapper.changeFlagsRelaxing(
                entry.segment_virt_addr,
                arch.paging.PageTableEntry.generateU64(.{
                    .present = true,
                    .writable = entry.flags & 2 == 2,
                    .no_execute = entry.flags & 1 == 0,
                    .user_accessable = true,
                }),
                entry.segment_memory_size,
            );
        }
        // Allocate single page for stack, rest gets dynamically allocated on page fault
        const stack_page_address = (highest_program_segment_address + 1) & ~@as(usize, 0xFFF);
        const stack_writable = if (gnu_stack_entry) |entry| entry.flags & 2 == 2 else true;
        const stack_no_execute = if (gnu_stack_entry) |entry| entry.flags & 1 == 0 else true;
        const stack_flags = arch.paging.PageTableEntry.generateU64(.{
            .present = true,
            .writable = stack_writable,
            .no_execute = stack_no_execute,
            .user_accessable = true,
        });
        try mem_mapper.mapMemCopyFromBuffer(
            stack_page_address,
            0x1000,
            &[0]u8{},
        );
        mem_mapper.changeFlags(stack_page_address, stack_flags, 0x1000);
        // Generate ID, process structure
        const pid = @atomicRmw(u64, &process_id_counter, .Add, 1, .Acquire);
        return Process{
            .id = pid,
            .stack_lower_limit = arch.common.process.highest_program_segment_address + 1,
            .stack_upper_limit = arch.common.process.highest_user_address,
            .stack_flags = stack_flags,
            .registers = RegisterStore.init(.{
                .stack_pointer = stack_page_address | 0xFF8,
                .instruction_pointer = program_elf.header.prog_entry_pos,
            }),
            .process_type = .User,
            .page_mapper = mem_mapper,
        };
    }
};

pub const KernelMainProcess = struct {
    registers: KernelMainRegisterStore = .{},
    page_allocator_ptr: *PageAllocator = arch.page_allocation.page_allocator_ptr,

    pub fn loadAddressSpace(self: *const KernelMainProcess) void {
        self.page_allocator_ptr.loadAddressSpace();
    }

    comptime {
        @setEvalBranchQuota(5000);
        asm (asmSymbolFmt(
            "KernelMainProcess.registers.start_register",
            @byteOffsetOf(KernelMainProcess, "registers") +
            KernelMainRegisterStore.start_register_offset,
        ));
        asm (asmSymbolFmt(
            "KernelMainProcess.registers.end_register",
            @byteOffsetOf(KernelMainProcess, "registers") +
            KernelMainRegisterStore.end_register_offset,
        ));
        asm (asmSymbolFmt(
            "KernelMainProcess.registers.vector_store",
            @byteOffsetOf(KernelMainProcess, "registers") +
            KernelMainRegisterStore.vector_store_offset,
        ));
        asm (asmSymbolFmt(
            "KernelMainProcess.page_allocator_ptr",
            @byteOffsetOf(KernelMainProcess, "page_allocator_ptr"),
        ));
        asm (asmSymbolFmt(
            "PageAllocator.page_table",
            @byteOffsetOf(PageAllocator, "page_table"),
        ));
    }
};
