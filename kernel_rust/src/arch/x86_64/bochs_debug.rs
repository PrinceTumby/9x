use super::port;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BochsWriter;

impl BochsWriter {
    /// Returns whether the Bochs debug port exists at port E9.
    pub unsafe fn test_port_exists() -> bool {
        unsafe { port::read_byte(port::BOCHS_DEBUG) == 0xE9 }
    }

    unsafe fn write_byte(&self, byte: u8) {
        unsafe {
            if byte == b'\n' {
                port::write_byte(port::BOCHS_DEBUG, b'\r');
            }
            port::write_byte(port::BOCHS_DEBUG, byte);
        }
    }
}

impl core::fmt::Write for BochsWriter {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for byte in s.bytes() {
            unsafe {
                self.write_byte(byte);
            }
        }
        Ok(())
    }
}
