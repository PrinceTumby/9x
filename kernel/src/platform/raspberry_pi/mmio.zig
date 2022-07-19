const raspberry_pi = @import("../raspberry_pi.zig");

var base_address: usize = undefined;

const rpi_model_bases = [_]u32{
    0x20000000, // Raspberry Pi 1, Zero
    0x3F000000, // Raspberry Pi 2, 3
    0xFE000000, // Raspberry Pi 4
};

const registers_base_offset: usize = 0x200000;

pub const gpio = struct {
    const base_offset = registers_base_offset;

    pub const Register = enum(usize) {
        gpf_sel0 = 0x00,
        gpf_sel1 = 0x04,
        gpf_sel2 = 0x08,
        gpf_sel3 = 0x0C,
        gpf_sel4 = 0x10,
        gpf_sel5 = 0x14,
        gp_set0 = 0x1C,
        gp_set1 = 0x20,
        gp_clr0 = 0x28,
        gp_lev0 = 0x34,
        gp_lev1 = 0x38,
        gp_eds0 = 0x40,
        gp_eds1 = 0x44,
        gp_hen0 = 0x64,
        gp_hen1 = 0x68,
        gppud = 0x94,
        gppud_clk0 = 0x98,
        gppud_clk1 = 0x9C,
    };

    pub inline fn readRegister(register: Register) u32 {
        const address = base_address + base_offset + @enumToInt(register);
        return @intToPtr(*volatile u32, address).*;
    }

    pub inline fn writeRegister(register: Register, value: u32) void {
        const address = base_address + base_offset + @enumToInt(register);
        @intToPtr(*volatile u32, address).* = value;
    }
};

pub const uart0 = struct {
    const base_offset = registers_base_offset + 0x1000;

    pub const Register = enum(usize) {
        dr = 0x00,
        rsrecr = 0x04,
        fr = 0x18,
        ilpr = 0x20,
        ibrd = 0x24,
        fbrd = 0x28,
        lcrh = 0x2C,
        cr = 0x30,
        ifls = 0x34,
        imsc = 0x38,
        ris = 0x3C,
        mis = 0x40,
        icr = 0x44,
        dmacr = 0x48,
        itcr = 0x80,
        itip = 0x84,
        itop = 0x88,
        tdr = 0x8C,
    };

    pub inline fn readByte() u8 {
        // Wait for a byte to be received
        while (readRegister(.fr) & (1 << 4) != 0) {}
        return @truncate(u8, readRegister(.dr));
    }

    pub inline fn writeByte(byte: u8) void {
        // Wait for UART to be ready to transmit
        while (readRegister(.fr) & (1 << 5) != 0) {}
        writeRegister(.dr, byte);
    }

    pub inline fn readRegister(register: Register) u32 {
        const address = base_address + base_offset + @enumToInt(register);
        return @intToPtr(*volatile u32, address).*;
    }

    pub inline fn writeRegister(register: Register, value: u32) void {
        const address = base_address + base_offset + @enumToInt(register);
        @intToPtr(*volatile u32, address).* = value;
    }

    pub fn init(model: raspberry_pi.Model) void {
        // Disable UARTs
        writeRegister(.cr, 0);
        uart_aux.writeRegister(.enable, 0);
        // Set up clock for consistent divisor values
        while (mailbox.isInputFull()) {}
        const r = (@truncate(
            u32,
            @ptrToInt(&mailbox.uart_3mhz_message),
        ) & ~@as(u32, 0xF)) | 8;
        mailbox.writeRegister(.write, r);
        while (mailbox.isOutputEmpty() or mailbox.readRegister(.read) != r) {}
        // Map UART0 to GPIO pins
        var pin_r = gpio.readRegister(.gpf_sel1);
        // GPIO 14, GPIO 15
        pin_r &= ~@as(u32, (7 << 12) | (7 << 15));
        // Alt0
        pin_r |= (4 << 12) | (4 << 15);
        gpio.writeRegister(.gpf_sel1, pin_r);
        // Enable pins 14 and 15
        gpio.writeRegister(.gppud, 0);
        delay(150);
        gpio.writeRegister(.gppud_clk0, (1 << 14) | (1 << 15));
        delay(150);
        // Flush GPIO setup
        gpio.writeRegister(.gppud_clk0, 0);
        // Clear interrupts
        writeRegister(.icr, 0x7FF);
        // 115,200 baud
        writeRegister(.ibrd, 2);
        writeRegister(.fbrd, 0xB);
        // 8n1
        writeRegister(.lcrh, 0x3 << 5);
        // Enable TX, RX, FIFO
        writeRegister(.cr, 0x301);
    }

    // pub fn init(model: raspberry_pi.Model) void {
    //     // Disable UART0
    //     writeRegister(.cr, 0);
    //     // Disable UART1
    //     uart_aux.writeRegister(.enable, 0);
    //     // Disable pull up/down for all GPIO pins and delay for 150 cycles
    //     gpio.writeRegister(.gppud, 0);
    //     delay(150);
    //     // Disable pull up/down for pins 14 and 15, delay for 150 cycles
    //     gpio.writeRegister(.gppud_clk0, (1 << 14) | (1 << 15));
    //     delay(150);
    //     // Write 0 to GPPUDCLK0 to make it take effect
    //     gpio.writeRegister(.gppud_clk0, 0);
    //     // Clear pending interrupts
    //     writeRegister(.icr, 0x7FF);
    //     // Set integer and fractional part of baud rate
    //     // Divider = UART_CLOCK/(16 * Baud)
    //     // Fraction part register = (Fractional part * 64) + 0.5
    //     // Baud = 115200
    //     // For Raspi 3 and 4 the UART_CLOCK is dependent on system clock by default.
    //     // Set it to 3Mhz so we can consistently set baud rate
    //     if (model == .three or model == .four) {
    //         // UART_CLOCK = 30000000
    //         const r = (@truncate(
    //             u32,
    //             @ptrToInt(&mailbox.uart_3mhz_message),
    //         ) & ~@as(u32, 0xF)) | 8;
    //         // Wait until we can talk to the VideoCore
    //         while (mailbox.isInputFull()) {}
    //         // Send our message to property channel and wait for response
    //         mailbox.writeRegister(.write, r);
    //         while (mailbox.isOutputEmpty() or mailbox.readRegister(.read) != r) {}
    //     }
    //     // Divider = 3000000 / (16 * 115200) = 1.67 = ~1
    //     writeRegister(.ibrd, 1);
    //     // Fractional part register = (.627 * 64) + 0.5 = 40.6 = ~40
    //     writeRegister(.fbrd, 40);
    //     // Enable FIFO set 8 data bits, 1 stop bits, no parity
    //     writeRegister(.lcrh, (1 << 4) | (1 << 5) | (1 << 6));
    //     // Mask all interrupts
    //     writeRegister(.imsc, 0x7F2);
    //     // Enable UART0, receive and transfer parts
    //     writeRegister(.cr, (1 << 0) | (1 << 8) | (1 << 9));
    // }
};

pub const uart_aux = struct {
    const base_offset = registers_base_offset + 0x15000;

    pub const Register = enum(usize) {
        enable = 0x4,
    };

    pub inline fn readRegister(register: Register) u32 {
        const address = base_address + base_offset + @enumToInt(register);
        return @intToPtr(*volatile u32, address).*;
    }

    pub inline fn writeRegister(register: Register, value: u32) void {
        const address = base_address + base_offset + @enumToInt(register);
        @intToPtr(*volatile u32, address).* = value;
    }
};

pub const mailbox = struct {
    const base_offset = 0xB880;

    pub const Register = enum(usize) {
        /// Bits 0-3 are the channel, bits 4-31 are the data
        read = 0x00,
        peek = 0x10,
        sender = 0x14,
        status = 0x18,
        config = 0x1C,
        /// Bits 0-3 are the channel, bits 4-31 are the data
        write = 0x20,
    };

    pub const Channel = enum(u4) {
        power_management_interface = 0,
        framebuffer_old = 1,
        uart = 2,
        vchiq_interface = 3,
        leds_interface = 4,
        buttons_interface = 5,
        touch_screen_interface = 6,
    };

    pub const uart_3mhz_message align(16) = [9]u32{
        8 * 4,
        0,
        0x38002,
        12,
        8,
        2,
        4000000,
        0,
        0,
    };

    // pub const uart_3mhz_message align(16) = [9]u32{
    //     9 * 4,
    //     0,
    //     0x38002,
    //     12,
    //     8,
    //     2,
    //     3000000,
    //     0,
    //     0,
    // };

    // Raw register access functions

    pub inline fn readRegister(register: Register) u32 {
        const address = base_address + base_offset + @enumToInt(register);
        return @intToPtr(*volatile u32, address).*;
    }

    pub inline fn writeRegister(register: Register, value: u32) void {
        const address = base_address + base_offset + @enumToInt(register);
        @intToPtr(*volatile u32, address).* = value;
    }

    pub inline fn memoryBarrier() void {
        asm volatile (
            \\mov r3, #0                    // Zero out read register
            \\mcr p15, 0, r3, c7, c5, 0     // Invalidate instruction cache
            \\mcr p15, 0, r3, c7, c5, 6     // Invalidate BTB
            \\mcr p15, 0, r3, c7, c10, 4    // Drain write buffer
            \\mcr p15, 0, r3, c7, c5, 4     // Prefetch flush
            :
            :
            : "r3", "memory"
        );
    }

    // Helper functions

    pub inline fn isOutputEmpty() bool {
        return readRegister(.status) & (1 << 30) != 0;
    }

    pub inline fn isInputFull() bool {
        return readRegister(.status) & (1 << 31) != 0;
    }

    pub inline fn waitForOutputMessage() void {
        while (isOutputEmpty()) memoryBarrier();
    }

    pub inline fn waitForInputSpace() void {
        while (isInputFull()) memoryBarrier();
    }

    pub fn writeToChannelBlocking(channel: Channel, data: u32) void {
        const value = (@as(u32, data) & ~@as(u32, 0xF)) | @as(u32, @enumToInt(channel));
        waitForInputSpace();
        mailbox.writeRegister(.write, value);
    }

    pub const framebuffer_old = struct {
        pub const MailboxMessage = extern struct {
            display_width: u32,
            display_height: u32,
            virtual_width: u32,
            virtual_height: u32,
            pitch: u32 = 0,
            bpp: u32,
            x_offset: u32 = 0,
            y_offset: u32 = 0,
            ptr: ?[*]volatile u8 = null,
            size: u32 = 0,
        };

        pub fn init(
            width: u32,
            height: u32,
            comptime bpp: u32,
        ) MailboxMessage {
            comptime {
                if (bpp != 24) @compileError("Only 24 is currently supported for BPP");
            }
            var message align(16) = MailboxMessage{
                .display_width = width,
                .display_height = height,
                .virtual_width = width,
                .virtual_height = height,
                .bpp = bpp,
            };
            writeToChannelBlocking(.framebuffer_old, @ptrToInt(&message));
            memoryBarrier();
            while (true) {
                waitForOutputMessage();
                memoryBarrier();
                const response = readRegister(.read);
                if ((response & 0xF) == 0x1) break;
            }
            return message;
        }
    };
};

pub fn init(model: raspberry_pi.Model) void {
    base_address = switch (model) {
        .zero, .one => rpi_model_bases[0],
        .two, .three => rpi_model_bases[1],
        .four => rpi_model_bases[2],
    };
}

inline fn delay(iterations: usize) void {
    asm volatile (
        \\__delay_%=: subs %[iterations], %[iterations], #1
        \\bne __delay_%=
        : [out] "=r" (iterations)
        : [iterations] "0" (iterations)
        : "cc"
    );
}
