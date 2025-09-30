bitfield::bitfield! {
    #[repr(transparent)]
    pub struct Status(u32);
    impl Debug;
    u16;
    pub exception, _: 11, 0;
    pub code, _: 15, 12;
}

#[repr(u8)]
pub enum Code {
    Environment = 0,
    Programmer = 1,
    AcpiTables = 2,
    Aml = 3,
    Control = 4,
}

impl Status {
    pub const OK: Status = Status(0);
    // Environmental exceptions
    pub const NO_MEMORY: Status = Status::new(Code::Environment, 0x4);
    pub const TIME: Status = Status::new(Code::Environment, 0x11);
    // Programmer exceptions
    pub const BAD_PARAMETER: Status = Status::new(Code::Programmer, 0x1);

    pub const fn new(code: Code, exception: u16) -> Self {
        Self(exception as u32 & 0xFFF | (code as u32 & 0xF << 12))
    }
}

#[repr(u32)]
pub enum Boolean {
    False = 0,
    True = 1,
}

impl From<bool> for Boolean {
    fn from(val: bool) -> Self {
        match val {
            false => Boolean::False,
            true => Boolean::True,
        }
    }
}

impl From<Boolean> for bool {
    fn from(val: Boolean) -> Self {
        match val {
            Boolean::False => false,
            Boolean::True => true,
        }
    }
}

pub mod subsystem {
    use super::Status;

    unsafe extern "C" {
        #[link_name = "AcpiInitializeSubsystem"]
        pub unsafe fn initialise() -> Status;
    }
}

pub mod table_manager {
    use super::*;

    unsafe extern "C" {
        #[link_name = "AcpiInitializeTables"]
        pub unsafe fn initialise(
            table_array: Option<&u32>,
            table_count: u32,
            allow_resize: Boolean,
        ) -> Status;

        #[link_name = "AcpiGetTable"]
        pub unsafe fn get_table(
            signature: &[u8; 4],
            // One-based
            instance: u32,
            out_table: &mut *const (),
        ) -> Status;
    }
}
