const SpinLock = @import("smp.zig").SpinLock;

/// Pending tasks, implemented as 256 priorities of doubly linked lists
pub const task_list = struct {
    var task_list_lock: SpinLock = SpinLock.init();
    var pending_tasks = [1]Priority{.{.head = null, .tail = null}} ** 256;

    const Priority = struct {
        head: ?*Task = null,
        tail: ?*Task = null,
    };

    /// Pushes a task onto the given priority list
    pub fn push(priority: u8, task: *Task) void {
        const lock = task_list_lock.acquire();
        defer lock.release();
        const priority_ptr = &pending_tasks[priority];
        task.previous_task = priority_ptr.tail;
        if (priority_ptr.tail) |tail| {
            tail.next_task = task;
            priority_ptr.tail = task;
        } else {
            priority_ptr.head = task;
            priority_ptr.tail = task;
        }
    }

    /// Tries to pop a task of any priority. Favors higher priority tasks.
    pub fn tryPop() ?*Task {
        const lock = task_list_lock.acquire();
        defer lock.release();
        for (pending_tasks) |*priority| {
            const head = priority.head orelse continue;
            if (head.next_task) |next_task| next_task.previous_task = null;
            priority.head = head.next_task;
            if (priority.tail == head) priority.tail = null;
            head.previous_task = null;
            head.next_task = null;
            return head;
        }
        return null;
    }
};

pub const Task = struct {
    previous_task: ?*Task = null,
    next_task: ?*Task = null,
    // TODO Add time budgets
    task_variant: union(enum) {
        kernel: KernelTask,
    },

    pub fn run(self: *Task) void {
        switch (self.task_variant) {
            .kernel => |*task| task.run(),
        }
    }
};

pub const KernelTask = struct {
    function: fn (args_ptr: *anyopaque) void,
    args_ptr: *anyopaque,

    pub fn init(function: anytype, args_ptr: anytype) KernelTask {
        const func_info = @typeInfo(@TypeOf(function)).Fn;
        const return_type = func_info.return_type orelse void;
        if (return_type != void and return_type != noreturn) {
            @compileError(
                "Function does not have void return type, found " ++
                @typeName(return_type)
            );
        }
        if (func_info.args.len != 1) {
            @compileError("Function must take 1 argument");
        }
        const func_arg = func_info.args[0].arg_type
            orelse @compileError("Function must take tangible argument");
        if (func_arg != @TypeOf(args_ptr)) {
            @compileError(
                "Function type " ++
                @typeName(@TypeOf(function)) ++
                " is incompatible with argument type " ++
                @typeName(@TypeOf(args_ptr))
            );
        }
        return KernelTask{
            .function = @ptrCast(fn (args_ptr: *anyopaque) void, function),
            .args_ptr = args_ptr,
        };
    }

    pub fn run(self: *KernelTask) void {
        self.function(self.args_ptr);
    }
};
