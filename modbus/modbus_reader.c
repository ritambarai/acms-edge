/*
 * Modbus RTU Reader for Olimex Lime 2
 * No external dependencies — pure POSIX termios + raw serial.
 *
 * Usage:
 *   ./modbus_reader <func_id> <start_addr> [slave_id] [data_length] [device]
 *
 *   func_id      FC: 1=Coils 2=Discrete 3=Holding 4=Input  (required)
 *   start_addr   Register/coil start address                (required)
 *   slave_id     Slave ID                                   (default: 1)
 *   data_length  Number of registers or bits to read        (default: 1)
 *   device       Serial device                              (default: /dev/ttyUSB0)
 *
 * Optional flags (before positional args):
 *   -b <baud>    Baud rate             (default: 9600)
 *   -p <parity>  Parity N/E/O          (default: N)
 *   -S <stops>   Stop bits 1 or 2      (default: 1)
 *   -e midlittle Mid-Little Endian per register (ESP32 acms slave byte order)
 *   -v           Print raw TX/RX bytes
 *   -h           This help
 *
 * Build (cross):  make
 * Build (native): make CC=gcc
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/time.h>

#define DEFAULT_DEVICE   "/dev/ttyUSB0"
#define DEFAULT_BAUD     9600
#define DEFAULT_SLAVE_ID 1
#define DEFAULT_LENGTH   1
#define MAX_REGISTERS       125
#define RESPONSE_TIMEOUT_MS 500
/* Modbus spec: frame gap = 3.5 char times.
 * At 9600 baud: 3.5 * (1/9600) * 10 * 1000 ≈ 3.6 ms → use 4 ms */
#define FRAME_GAP_MS(baud)  (((3500 * 10) / (baud)) + 1)

typedef enum { ENDIAN_BIG, ENDIAN_MIDLITTLE } endian_t;

/* ── CRC16 (same LUT as ESP32 modbus_manager.cpp) ───────────────────────── */
static const uint8_t crc_hi[] = {
    0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,
    0x40,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,0x40,0x01,0xC0,
    0x80,0x41,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,0x40,0x01,
    0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x01,0xC0,0x80,0x41,
    0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,
    0x40,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x01,0xC0,
    0x80,0x41,0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x01,
    0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,
    0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,
    0x40,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x01,0xC0,
    0x80,0x41,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,0x40,0x01,
    0xC0,0x80,0x41,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,
    0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,
    0x40,0x01,0xC0,0x80,0x41,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x01,0xC0,
    0x80,0x41,0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x01,
    0xC0,0x80,0x41,0x00,0xC1,0x81,0x40,0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,
    0x00,0xC1,0x81,0x40,0x01,0xC0,0x80,0x41,0x01,0xC0,0x80,0x41,0x00,0xC1,0x81,
    0x40
};
static const uint8_t crc_lo[] = {
    0x00,0xC0,0xC1,0x01,0xC3,0x03,0x02,0xC2,0xC6,0x06,0x07,0xC7,0x05,0xC5,0xC4,
    0x04,0xCC,0x0C,0x0D,0xCD,0x0F,0xCF,0xCE,0x0E,0x0A,0xCA,0xCB,0x0B,0xC9,0x09,
    0x08,0xC8,0xD8,0x18,0x19,0xD9,0x1B,0xDB,0xDA,0x1A,0x1E,0xDE,0xDF,0x1F,0xDD,
    0x1D,0x1C,0xDC,0x14,0xD4,0xD5,0x15,0xD7,0x17,0x16,0xD6,0xD2,0x12,0x13,0xD3,
    0x11,0xD1,0xD0,0x10,0xF0,0x30,0x31,0xF1,0x33,0xF3,0xF2,0x32,0x36,0xF6,0xF7,
    0x37,0xF5,0x35,0x34,0xF4,0x3C,0xFC,0xFD,0x3D,0xFF,0x3F,0x3E,0xFE,0xFA,0x3A,
    0x3B,0xFB,0x39,0xF9,0xF8,0x38,0x28,0xE8,0xE9,0x29,0xEB,0x2B,0x2A,0xEA,0xEE,
    0x2E,0x2F,0xEF,0x2D,0xED,0xEC,0x2C,0xE4,0x24,0x25,0xE5,0x27,0xE7,0xE6,0x26,
    0x22,0xE2,0xE3,0x23,0xE1,0x21,0x20,0xE0,0xA0,0x60,0x61,0xA1,0x63,0xA3,0xA2,
    0x62,0x66,0xA6,0xA7,0x67,0xA5,0x65,0x64,0xA4,0x6C,0xAC,0xAD,0x6D,0xAF,0x6F,
    0x6E,0xAE,0xAA,0x6A,0x6B,0xAB,0x69,0xA9,0xA8,0x68,0x78,0xB8,0xB9,0x79,0xBB,
    0x7B,0x7A,0xBA,0xBE,0x7E,0x7F,0xBF,0x7D,0xBD,0xBC,0x7C,0xB4,0x74,0x75,0xB5,
    0x77,0xB7,0xB6,0x76,0x72,0xB2,0xB3,0x73,0xB1,0x71,0x70,0xB0,0x50,0x90,0x91,
    0x51,0x93,0x53,0x52,0x92,0x96,0x56,0x57,0x97,0x55,0x95,0x94,0x54,0x9C,0x5C,
    0x5D,0x9D,0x5F,0x9F,0x9E,0x5E,0x5A,0x9A,0x9B,0x5B,0x99,0x59,0x58,0x98,0x88,
    0x48,0x49,0x89,0x4B,0x8B,0x8A,0x4A,0x4E,0x8E,0x8F,0x4F,0x8D,0x4D,0x4C,0x8C,
    0x44,0x84,0x85,0x45,0x87,0x47,0x46,0x86,0x82,0x42,0x43,0x83,0x41,0x81,0x80,
    0x40
};

static uint16_t crc16(const uint8_t *buf, int len)
{
    uint8_t hi = 0xFF, lo = 0xFF;
    while (len--) {
        unsigned idx = hi ^ *buf++;
        hi = lo ^ crc_hi[idx];
        lo = crc_lo[idx];
    }
    return (uint16_t)(hi << 8 | lo);
}

/* ── Serial port ─────────────────────────────────────────────────────────── */
static speed_t baud_to_speed(int baud)
{
    switch (baud) {
    case 1200:   return B1200;
    case 2400:   return B2400;
    case 4800:   return B4800;
    case 9600:   return B9600;
    case 19200:  return B19200;
    case 38400:  return B38400;
    case 57600:  return B57600;
    case 115200: return B115200;
    default:     return B0;
    }
}

static int serial_open(const char *dev, int baud, char parity, int stop_bits)
{
    int fd = open(dev, O_RDWR | O_NOCTTY | O_NDELAY);
    if (fd < 0) { perror(dev); return -1; }

    fcntl(fd, F_SETFL, 0);   /* blocking mode */

    struct termios t;
    tcgetattr(fd, &t);
    cfmakeraw(&t);

    speed_t spd = baud_to_speed(baud);
    if (spd == B0) { fprintf(stderr, "Unsupported baud %d\n", baud); close(fd); return -1; }
    cfsetispeed(&t, spd);
    cfsetospeed(&t, spd);

    t.c_cflag &= ~(PARENB | PARODD | CSTOPB | CSIZE);
    t.c_cflag |= CS8 | CLOCAL | CREAD;
    if (parity == 'E')      t.c_cflag |= PARENB;
    else if (parity == 'O') t.c_cflag |= PARENB | PARODD;
    if (stop_bits == 2)     t.c_cflag |= CSTOPB;

    t.c_cc[VMIN]  = 0;
    t.c_cc[VTIME] = 1;   /* 100 ms inter-byte timeout */

    tcflush(fd, TCIOFLUSH);
    tcsetattr(fd, TCSANOW, &t);
    return fd;
}

/* ── Millisecond timestamp ───────────────────────────────────────────────── */
static long ms_now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000L + tv.tv_usec / 1000L;
}

/* ── Send Modbus RTU query frame ─────────────────────────────────────────── */
static void send_query(int fd, uint8_t slave, uint8_t fc,
                       uint16_t addr, uint16_t count, int verbose)
{
    uint8_t buf[8];
    buf[0] = slave;
    buf[1] = fc;
    buf[2] = (addr  >> 8) & 0xFF;
    buf[3] =  addr        & 0xFF;
    buf[4] = (count >> 8) & 0xFF;
    buf[5] =  count       & 0xFF;
    uint16_t crc = crc16(buf, 6);
    buf[6] = (crc >> 8) & 0xFF;
    buf[7] =  crc        & 0xFF;

    if (verbose) {
        printf("TX: ");
        for (int i = 0; i < 8; i++) printf("%02X ", buf[i]);
        printf("\n");
    }

    tcflush(fd, TCIFLUSH);
    if (write(fd, buf, 8) != 8) { perror("write"); }
}

/* ── Receive response frame (blocking up to RESPONSE_TIMEOUT_MS) ─────────── */
static int recv_response(int fd, uint8_t *buf, int bufsz, int frame_gap_ms, int verbose)
{
    int     len        = 0;
    long    deadline   = ms_now() + RESPONSE_TIMEOUT_MS;
    long    last_byte  = 0;

    while (ms_now() < deadline) {
        uint8_t b;
        int n = read(fd, &b, 1);
        if (n == 1) {
            if (len < bufsz) buf[len++] = b;
            last_byte = ms_now();
        } else if (len > 0 && ms_now() - last_byte >= frame_gap_ms) {
            break;
        }
        usleep(200);
    }

    if (verbose && len > 0) {
        printf("RX: ");
        for (int i = 0; i < len; i++) printf("%02X ", buf[i]);
        printf("\n");
    }
    return len;
}

/* ── Helpers ─────────────────────────────────────────────────────────────── */
static uint16_t swap_bytes(uint16_t v)
{
    return (uint16_t)((v >> 8) | (v << 8));
}


/* ── Usage ───────────────────────────────────────────────────────────────── */
static void print_usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [flags] <func_id> <start_addr> [slave_id] [data_length] [device]\n"
        "\n"
        "  func_id      1=Coils 2=Discrete 3=Holding 4=Input  (required)\n"
        "  start_addr   Register/coil start address           (required)\n"
        "  slave_id     Slave ID                              (default: 1)\n"
        "  data_length  Registers/bits to read                (default: 1)\n"
        "  device       Serial device                         (default: /dev/ttyUSB0)\n"
        "\n"
        "Flags:\n"
        "  -b <baud>    Baud rate             (default: 9600)\n"
        "  -p <parity>  Parity N/E/O          (default: N)\n"
        "  -S <stops>   Stop bits 1 or 2      (default: 1)\n"
        "  -e midlittle Mid-Little Endian per register (ESP32 acms slave)\n"
        "  -v           Print raw TX/RX bytes\n"
        "  -h           This help\n",
        prog);
}

/* ── main ────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[])
{
    int      baud      = DEFAULT_BAUD;
    char     parity    = 'N';
    int      stop_bits = 1;
    endian_t endian    = ENDIAN_BIG;
    int      verbose   = 0;
    int      opt;

    while ((opt = getopt(argc, argv, "b:p:S:e:vh")) != -1) {
        switch (opt) {
        case 'b': baud      = atoi(optarg); break;
        case 'p': parity    = optarg[0];    break;
        case 'S': stop_bits = atoi(optarg); break;
        case 'e':
            if (strcmp(optarg, "midlittle") == 0) endian = ENDIAN_MIDLITTLE;
            else if (strcmp(optarg, "big") != 0) {
                fprintf(stderr, "Unknown endianness '%s'\n", optarg); return 1;
            }
            break;
        case 'v': verbose = 1; break;
        case 'h': print_usage(argv[0]); return 0;
        default:  print_usage(argv[0]); return 1;
        }
    }

    int pos = argc - optind;
    if (pos < 2) { print_usage(argv[0]); return 1; }

    uint8_t     fc         = (uint8_t)atoi(argv[optind]);
    uint16_t    start_addr = (uint16_t)atoi(argv[optind + 1]);
    uint8_t     slave_id   = (pos >= 3) ? (uint8_t)atoi(argv[optind + 2]) : DEFAULT_SLAVE_ID;
    uint16_t    data_len   = (pos >= 4) ? (uint16_t)atoi(argv[optind + 3]) : DEFAULT_LENGTH;
    const char *device     = (pos >= 5) ? argv[optind + 4] : DEFAULT_DEVICE;

    if (fc < 1 || fc > 4)                         { fprintf(stderr, "func_id must be 1-4\n");            return 1; }
    if (data_len < 1 || data_len > MAX_REGISTERS)  { fprintf(stderr, "data_length must be 1-%d\n", MAX_REGISTERS); return 1; }

    int frame_gap_ms = FRAME_GAP_MS(baud);

    printf("Device  : %s  %d baud 8%c%d  frame_gap %d ms\n",
           device, baud, parity, stop_bits, frame_gap_ms);
    printf("Slave %d  FC%d  Addr %u  Len %d\n", slave_id, fc, start_addr, data_len);
    printf("Press Ctrl+C to stop.\n\n");

    int fd = serial_open(device, baud, parity, stop_bits);
    if (fd < 0) return 1;

    uint8_t  rx[256];
    int      first = 1;
    int      i;

    for (;;) {
        send_query(fd, slave_id, fc, start_addr, data_len, verbose);

        int rxlen = recv_response(fd, rx, sizeof(rx), frame_gap_ms, verbose);

        /* Move cursor up to overwrite previous output after first print */
        if (!first)
            printf("\033[%dA", data_len);
        first = 0;

        if (rxlen < 4) {
            for (i = 0; i < data_len; i++)
                printf("[%u] = ERR \n", start_addr + i);
            continue;
        }

        uint16_t got_crc  = (uint16_t)((rx[rxlen - 2] << 8) | rx[rxlen - 1]);
        uint16_t calc_crc = crc16(rx, rxlen - 2);
        if (got_crc != calc_crc || (rx[1] & 0x80)) {
            for (i = 0; i < data_len; i++)
                printf("[%u] = ERR \n", start_addr + i);
            continue;
        }

        if (fc == 1 || fc == 2) {
            for (i = 0; i < data_len; i++) {
                int state = (rx[3 + i / 8] >> (i % 8)) & 0x01;
                printf("[%u] = %d  \n", start_addr + i, state);
            }
        } else {
            int reg_count = rx[2] / 2;
            uint16_t regs[MAX_REGISTERS];
            for (i = 0; i < reg_count && i < MAX_REGISTERS; i++) {
                regs[i] = (uint16_t)((rx[3 + i * 2] << 8) | rx[4 + i * 2]);
                if (endian == ENDIAN_MIDLITTLE)
                    regs[i] = swap_bytes(regs[i]);
            }
            for (i = 0; i < reg_count; i++)
                printf("[%u] = %u  \n", start_addr + i, (unsigned int)regs[i]);
        }

        fflush(stdout);
    }

    close(fd);
    return 0;
}
