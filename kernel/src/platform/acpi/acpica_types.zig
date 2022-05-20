const root = @import("root");
const compileErrorFmt = root.zig_extensions.compileErrorFmt;

pub const AcpiStatus = packed struct {
    exception: u12,
    code: Code,
    reserved: u16 = 0,

    pub const Code = packed enum(u4) {
        Environment = 0,
        Programmer = 1,
        AcpiTables = 2,
        Aml = 3,
        Control = 4,
        _,
    };

    // -- List of exceptions --
    pub const Ok = AcpiStatus{ .exception = 0x0, .code = .Environment };
    // Environmental exceptions
    pub const Error = AcpiStatus{ .exception = 0x1, .code = .Environment };
    pub const NoAcpiTables = AcpiStatus{ .exception = 0x2, .code = .Environment };
    pub const NoNamespace = AcpiStatus{ .exception = 0x3, .code = .Environment };
    pub const NoMemory = AcpiStatus{ .exception = 0x4, .code = .Environment };
    pub const NotFound = AcpiStatus{ .exception = 0x5, .code = .Environment };
    pub const NotExist = AcpiStatus{ .exception = 0x6, .code = .Environment };
    pub const AlreadyExists = AcpiStatus{ .exception = 0x7, .code = .Environment };
    pub const Type = AcpiStatus{ .exception = 0x8, .code = .Environment };
    pub const NullObject = AcpiStatus{ .exception = 0x9, .code = .Environment };
    pub const NullEntry = AcpiStatus{ .exception = 0xA, .code = .Environment };
    pub const BufferOverflow = AcpiStatus{ .exception = 0xB, .code = .Environment };
    pub const StackOverflow = AcpiStatus{ .exception = 0xC, .code = .Environment };
    pub const StackUnderflow = AcpiStatus{ .exception = 0xD, .code = .Environment };
    pub const NotImplemented = AcpiStatus{ .exception = 0xE, .code = .Environment };
    pub const Support = AcpiStatus{ .exception = 0xF, .code = .Environment };
    pub const Limit = AcpiStatus{ .exception = 0x10, .code = .Environment };
    pub const Time = AcpiStatus{ .exception = 0x11, .code = .Environment };
    pub const AcquireDeadlock = AcpiStatus{ .exception = 0x12, .code = .Environment };
    pub const ReleaseDeadlock = AcpiStatus{ .exception = 0x13, .code = .Environment };
    pub const NotAcquired = AcpiStatus{ .exception = 0x14, .code = .Environment };
    pub const AlreadyAcquired = AcpiStatus{ .exception = 0x15, .code = .Environment };
    pub const NoHardwareResponse = AcpiStatus{ .exception = 0x16, .code = .Environment };
    pub const NoGlobalLock = AcpiStatus{ .exception = 0x17, .code = .Environment };
    pub const AbortMethod = AcpiStatus{ .exception = 0x18, .code = .Environment };
    pub const SameHandler = AcpiStatus{ .exception = 0x19, .code = .Environment };
    pub const NoHandler = AcpiStatus{ .exception = 0x1A, .code = .Environment };
    pub const OwnerIdLimit = AcpiStatus{ .exception = 0x1B, .code = .Environment };
    pub const NotConfigured = AcpiStatus{ .exception = 0x1C, .code = .Environment };
    pub const Access = AcpiStatus{ .exception = 0x1D, .code = .Environment };
    pub const IoError = AcpiStatus{ .exception = 0x1E, .code = .Environment };
    pub const NumericOverflow = AcpiStatus{ .exception = 0x1F, .code = .Environment };
    pub const HexOverflow = AcpiStatus{ .exception = 0x20, .code = .Environment };
    pub const DecimalOverflow = AcpiStatus{ .exception = 0x21, .code = .Environment };
    pub const OctalOverflow = AcpiStatus{ .exception = 0x22, .code = .Environment };
    pub const EndOfTable = AcpiStatus{ .exception = 0x23, .code = .Environment };
    // Programmer exceptions
    pub const BadParameter = AcpiStatus{ .exception = 0x1, .code = .Programmer };
    pub const BadCharacter = AcpiStatus{ .exception = 0x2, .code = .Programmer };
    pub const BadPathName = AcpiStatus{ .exception = 0x3, .code = .Programmer };
    pub const BadData = AcpiStatus{ .exception = 0x4, .code = .Programmer };
    pub const BadHexConstant = AcpiStatus{ .exception = 0x5, .code = .Programmer };
    pub const BadOctalConstant = AcpiStatus{ .exception = 0x6, .code = .Programmer };
    pub const BadDecimalConstant = AcpiStatus{ .exception = 0x7, .code = .Programmer };
    pub const MissingArguments = AcpiStatus{ .exception = 0x8, .code = .Programmer };
    pub const BadAddress = AcpiStatus{ .exception = 0x9, .code = .Programmer };
    // Table exceptions
    pub const BadSignature = AcpiStatus{ .exception = 0x1, .code = .AcpiTables };
    pub const BadHeader = AcpiStatus{ .exception = 0x2, .code = .AcpiTables };
    pub const BadChecksum = AcpiStatus{ .exception = 0x3, .code = .AcpiTables };
    pub const BadValue = AcpiStatus{ .exception = 0x4, .code = .AcpiTables };
    pub const InvalidTableLength = AcpiStatus{ .exception = 0x5, .code = .AcpiTables };
    // AML exceptions
    pub const AmlBadOpcode = AcpiStatus{ .exception = 0x1, .code = .Aml };
    pub const AmlNoOperand = AcpiStatus{ .exception = 0x2, .code = .Aml };
    pub const AmlOperandType = AcpiStatus{ .exception = 0x3, .code = .Aml };
    pub const AmlOperandValue = AcpiStatus{ .exception = 0x4, .code = .Aml };
    pub const AmlUnitializedLocal = AcpiStatus{ .exception = 0x5, .code = .Aml };
    pub const AmlUnitializedArg = AcpiStatus{ .exception = 0x6, .code = .Aml };
    pub const AmlUnitializedElement = AcpiStatus{ .exception = 0x7, .code = .Aml };
    pub const AmlNumericOverflow = AcpiStatus{ .exception = 0x8, .code = .Aml };
    pub const AmlRegionLimit = AcpiStatus{ .exception = 0x9, .code = .Aml };
    pub const AmlBufferLimit = AcpiStatus{ .exception = 0xA, .code = .Aml };
    pub const AmlPackageLimit = AcpiStatus{ .exception = 0xB, .code = .Aml };
    pub const AmlDivideByZero = AcpiStatus{ .exception = 0xC, .code = .Aml };
    pub const AmlBadName = AcpiStatus{ .exception = 0xD, .code = .Aml };
    pub const AmlNameNotFound = AcpiStatus{ .exception = 0xE, .code = .Aml };
    pub const AmlInternal = AcpiStatus{ .exception = 0xF, .code = .Aml };
    pub const AmlInvalidSpaceId = AcpiStatus{ .exception = 0x10, .code = .Aml };
    pub const AmlStringLimit = AcpiStatus{ .exception = 0x11, .code = .Aml };
    pub const AmlNoReturnValue = AcpiStatus{ .exception = 0x12, .code = .Aml };
    pub const AmlMethodLimit = AcpiStatus{ .exception = 0x13, .code = .Aml };
    pub const AmlNotOwner = AcpiStatus{ .exception = 0x14, .code = .Aml };
    pub const AmlMutexOrder = AcpiStatus{ .exception = 0x15, .code = .Aml };
    pub const AmlMutexNotAcquired = AcpiStatus{ .exception = 0x16, .code = .Aml };
    pub const AmlInvalidResourceType = AcpiStatus{ .exception = 0x17, .code = .Aml };
    pub const AmlInvalidIndex = AcpiStatus{ .exception = 0x18, .code = .Aml };
    pub const AmlRegisterLimit = AcpiStatus{ .exception = 0x19, .code = .Aml };
    pub const AmlNoWhile = AcpiStatus{ .exception = 0x1A, .code = .Aml };
    pub const AmlAligment = AcpiStatus{ .exception = 0x1B, .code = .Aml };
    pub const AmlNoResourceEndTag = AcpiStatus{ .exception = 0x1C, .code = .Aml };
    pub const AmlBadResourceValue = AcpiStatus{ .exception = 0x1D, .code = .Aml };
    pub const AmlCircularReference = AcpiStatus{ .exception = 0x1E, .code = .Aml };
    pub const AmlBadResourceLength = AcpiStatus{ .exception = 0x1F, .code = .Aml };
    pub const AmlIllegalAddress = AcpiStatus{ .exception = 0x20, .code = .Aml };
    pub const AmlLoopTimeout = AcpiStatus{ .exception = 0x21, .code = .Aml };
    pub const AmlInitializedNode = AcpiStatus{ .exception = 0x22, .code = .Aml };
    pub const AmlTargetType = AcpiStatus{ .exception = 0x23, .code = .Aml };
    pub const AmlProtocol = AcpiStatus{ .exception = 0x24, .code = .Aml };
    pub const AmlBufferLength = AcpiStatus{ .exception = 0x25, .code = .Aml };
    // Internal exceptions used for control
    pub const CtrlReturnValue = AcpiStatus{ .exception = 0x1, .code = .Control };
    pub const CtrlPending = AcpiStatus{ .exception = 0x2, .code = .Control };
    pub const CtrlTerminate = AcpiStatus{ .exception = 0x3, .code = .Control };
    pub const CtrlTrue = AcpiStatus{ .exception = 0x4, .code = .Control };
    pub const CtrlFalse = AcpiStatus{ .exception = 0x5, .code = .Control };
    pub const CtrlDepth = AcpiStatus{ .exception = 0x6, .code = .Control };
    pub const CtrlEnd = AcpiStatus{ .exception = 0x7, .code = .Control };
    pub const CtrlTransfer = AcpiStatus{ .exception = 0x8, .code = .Control };
    pub const CtrlBreak = AcpiStatus{ .exception = 0x9, .code = .Control };
    pub const CtrlContinue = AcpiStatus{ .exception = 0xA, .code = .Control };
    pub const CtrlParseContinue = AcpiStatus{ .exception = 0xB, .code = .Control };
    pub const CtrlParsePending = AcpiStatus{ .exception = 0xC, .code = .Control };

    pub fn isOk(self: AcpiStatus) bool {
        return self.exception == Ok.exception and self.code == Ok.code;
    }

    pub fn isErr(self: AcpiStatus) bool {
        return !self.isOk();
    }

    comptime {
        if (@bitSizeOf(AcpiStatus) != @bitSizeOf(u32)) {
            compileErrorFmt("ACPI status should be {} bits, is {}", .{
                @bitSizeOf(u32),
                @bitSizeOf(AcpiStatus),
            });
        }
        if (@sizeOf(AcpiStatus) != @sizeOf(u32)) {
            compileErrorFmt("ACPI status should be {} bytes, is {}", .{
                @sizeOf(u32),
                @sizeOf(AcpiStatus),
            });
        }
    }
};

pub const AcpiBoolean = enum(u8) {
    False = 0,
    True = 1,
    _,

    pub fn fromBool(value: bool) AcpiBoolean {
        if (value) return .True else return .False;
    }
};

pub const AcpiNameUnion = extern union {
    integer: u32,
    ascii: [4]u8,
};

pub const AcpiTableDesc = extern struct {
    address: u64,
    pointer: *c_void,
    length: u32,
    signature: u32,
    owner_id: u16,
    flags: u8,
    validation_count: u16,
};
