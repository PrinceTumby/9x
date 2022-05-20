#include <stddef.h>
#include <stdarg.h>

// Standard definitions
typedef long long ssize_t;
typedef unsigned char uint8_t;

// Zig exposed functions
typedef enum {
    Left = 0,
    Center = 1,
    Right = 2,
} Alignment;
extern void AcpiCustomOsPanic(char* code);
extern void AcpiCustomOsPrintPrefix(void);
extern void AcpiCustomOsPrintString(char* ptr, size_t len);
extern void AcpiCustomOsPrintStringWithOptions(
    char* ptr,
    size_t len,
    size_t precision,
    size_t width,
    uint8_t alignment,
    uint8_t fill
);
extern void AcpiCustomOsPrintChar(char character);
extern void AcpiCustomOsPrintSignedInt(
    ssize_t num,
    size_t precision,
    size_t width,
    uint8_t alignment,
    uint8_t fill
);
extern void AcpiCustomOsPrintInt(
    size_t num,
    uint8_t base,
    uint8_t uppercase,
    size_t precision,
    size_t width,
    uint8_t alignment,
    uint8_t fill
);
extern void AcpiCustomOsPrintNewline(void);

void AcpiOsVprintf(char* format, va_list args) {
    /* { */
    /*     // TESTING: REMOVE LATER */
    /*     size_t i = 0; */
    /*     while (format[i] != '\0') i++; */
    /*     /1* AcpiCustomOsPrintPrefix(); *1/ */
    /*     AcpiCustomOsPrintString(format, i); */
    /*     AcpiCustomOsPrintNewline(); */
    /*     /1* return; *1/ */
    /* } */
    /* AcpiCustomOsPrintPrefix(); */
    typedef enum {
        RawString,
        FormatStart,
        Flags,
        Width,
        Precision,
        Type,
    } State;
    State current_state = RawString;
    size_t i = 0;
    uint8_t next_char = *format;
    char* current_string_start = format;
    size_t current_string_len = 0;
    // Format specifier components
    uint8_t alignment = Right;
    char fill = ' ';
    size_t width = 0;
    size_t precision = 1;
    while (next_char != '\0') {
        /* AcpiCustomOsPrintChar(next_char); */
        /* AcpiCustomOsPrintInt(current_state, 10, 0, 1, 0, 0, ' '); */
        switch (current_state) {
            case RawString:
                if (next_char == '%') {
                    // Print string, start format specifier
                    if (current_string_len > 0)
                        AcpiCustomOsPrintString(current_string_start, current_string_len);
                    current_state = FormatStart;
                } else {
                    current_string_len++;
                }
                break;
            case FormatStart:
                switch (next_char) {
                    // Flags
                    case '-':
                        current_state = Flags;
                        alignment = Left;
                        break;
                    case '0':
                        current_state = Flags;
                        fill = '0';
                        break;
                    case '+': case ' ': case '#':
                        AcpiCustomOsPrintChar(next_char);
                        AcpiCustomOsPanic("unimplemented flag (see above output)");
                        break;
                    // Width
                    case '1': case '2': case '3': case '4': case '5':
                    case '6': case '7': case '8': case '9':
                        current_state = Width;
                        width = width * 10 + (next_char - 48);
                        break;
                    // Precision
                    case '.':
                        current_state = Precision;
                        precision = 0;
                        break;
                    // Type
                    case 'c': case 'C': case 'd': case 'i': case 'o': case 'u': case 'x':
                    case 'X': case 'e': case 'E': case 'f': case 'F': case 'g': case 'G':
                    case 'a': case 'A': case 'n': case 'p': case 's': case 'S': case 'Z':
                        current_state = Type;
                        i--;
                        break;
                    // Escape character
                    case '%':
                        AcpiCustomOsPrintChar('%');
                        current_state = RawString;
                        current_string_start = format + i + 1;
                        current_string_len = 0;
                        break;
                    default:
                        AcpiCustomOsPanic("malformed printf format specifier");
                        break;
                }
                break;
            case Flags:
                switch (next_char) {
                    // Flags
                    case '-':
                        alignment = Left;
                        break;
                    case '0':
                        fill = '0';
                        break;
                    case '+': case ' ': case '#':
                        AcpiCustomOsPrintChar(next_char);
                        AcpiCustomOsPanic("unimplemented flag (see above output)");
                        break;
                    // Width
                    case '1': case '2': case '3': case '4': case '5':
                    case '6': case '7': case '8': case '9':
                        current_state = Width;
                        width = width * 10 + (next_char - 48);
                        break;
                    // Precision
                    case '.':
                        current_state = Precision;
                        precision = 0;
                        break;
                    // Type
                    case 'c': case 'C': case 'd': case 'i': case 'o': case 'u': case 'x':
                    case 'X': case 'e': case 'E': case 'f': case 'F': case 'g': case 'G':
                    case 'a': case 'A': case 'n': case 'p': case 's': case 'S': case 'Z':
                        current_state = Type;
                        i--;
                        break;
                    default:
                        AcpiCustomOsPanic("malformed printf format specifier");
                        break;
                }
                break;
            case Width:
                switch (next_char) {
                    // Width
                    case '1': case '2': case '3': case '4': case '5':
                    case '6': case '7': case '8': case '9': case '0':
                        width = width * 10 + (next_char - 48);
                        break;
                    // Precision
                    case '.':
                        current_state = Precision;
                        precision = 0;
                        break;
                    // Type
                    case 'c': case 'C': case 'd': case 'i': case 'o': case 'u': case 'x':
                    case 'X': case 'e': case 'E': case 'f': case 'F': case 'g': case 'G':
                    case 'a': case 'A': case 'n': case 'p': case 's': case 'S': case 'Z':
                        current_state = Type;
                        i--;
                        break;
                    default:
                        AcpiCustomOsPanic("malformed printf format specifier");
                        break;
                }
                break;
            case Precision:
                switch (next_char) {
                    // Precision
                    case '1': case '2': case '3': case '4': case '5':
                    case '6': case '7': case '8': case '9': case '0':
                        precision = precision * 10 + (next_char - 48);
                        break;
                    case '*':
                        AcpiCustomOsPanic("unimplemented precision specifier '*'");
                        break;
                    // Type
                    case 'c': case 'C': case 'd': case 'i': case 'o': case 'u': case 'x':
                    case 'X': case 'e': case 'E': case 'f': case 'F': case 'g': case 'G':
                    case 'a': case 'A': case 'n': case 'p': case 's': case 'S': case 'Z':
                        current_state = Type;
                        i--;
                        break;
                    default:
                        AcpiCustomOsPanic("malformed printf format specifier");
                        break;
                }
                break;
            case Type:
                switch (next_char) {
                    case 'c':
                        {
                            char print_character = va_arg(args, int);
                            AcpiCustomOsPrintChar(print_character);
                            break;
                        }
                    case 's':
                        {
                            char* ptr = va_arg(args, char*);
                            size_t len = 0;
                            if (precision > 1) {
                                while (ptr[len] != '\0' && len < precision) len++;
                            } else {
                                while (ptr[len] != '\0') len++;
                            }
                            AcpiCustomOsPrintStringWithOptions(
                                ptr,
                                len,
                                precision,
                                width,
                                alignment,
                                fill
                            );
                            break;
                        }
                    case 'd': case 'i':
                        {
                            int print_num = va_arg(args, int);
                            AcpiCustomOsPrintSignedInt(
                                print_num,
                                precision,
                                width,
                                2 - alignment,
                                fill
                            );
                            break;
                        }
                    case 'u': case 'o': case 'x': case 'X':
                        {
                            uint8_t base = 10;
                            switch (next_char) {
                                case 'x': case 'X':
                                    base = 16;
                                    break;
                                case 'o':
                                    base = 8;
                                    break;
                                default:
                                    break;
                            }
                            uint8_t uppercase = next_char == 'X';
                            int print_num = va_arg(args, int);
                            AcpiCustomOsPrintInt(
                                print_num,
                                base,
                                uppercase,
                                precision,
                                width,
                                2 - alignment,
                                fill
                            );
                            break;
                        }
                    default:
                        AcpiCustomOsPrintChar(next_char);
                        AcpiCustomOsPanic("unknown printf type specifier (see above output)");
                        break;
                }
                current_state = RawString;
                current_string_start = format + i + 1;
                current_string_len = 0;
                alignment = Right;
                fill = ' ';
                width = 0;
                precision = 1;
                break;
        }
        i++;
        next_char = format[i];
    }
    if (current_string_len > 0)
        AcpiCustomOsPrintString(current_string_start, current_string_len);
}

void AcpiOsPrintf(char* format, ...) {
    va_list args;
    va_start(args, format);
    /* size_t i = 0; */
    /* while (*(format + i) != '\0') { */
    /*     i++; */
    /* } */
    /* AcpiCustomOsPrintPrefix(); */
    /* AcpiCustomOsPrintString(format, i); */
    /* AcpiCustomOsPrintNewline(); */
    AcpiOsVprintf(format, args);
    va_end(args);
}
