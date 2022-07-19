pub const Resource = struct {
    id: u64,
    data: ResourceData,

    pub const Type = enum(u64) {
        Pipe,
    };

    pub const ResourceData = union(Type) {
        Pipe: PipeData,

        pub const PipeData = struct {
            control_page_address: *align(4096) PipePage,
            direction: Direction,

            pub const Direction = enum {
                KernelToUser,
                UserToKernel,
            };
        };
    };

    var id_counter: u64 = 0;

    pub fn init(data: ResourceData) Resource {
        const id = @atomicRmw(u64, &id_counter, .Add, 1, .Acquire);
        return Resource{
            .id = id,
            .data = data,
        };
    }
};

pub const PipePage = extern struct {
    num_pages: u64,
    tail: u64,
    head: u64,
    pages: [509]*align(4096) [4096]u8,
};
