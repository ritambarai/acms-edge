/*
 * board_register.c
 *
 * Reads the Allwinner A20 SID (hardware-fused unique chip ID) from sysfs
 * and POSTs it to the ACMS server as JSON.
 *
 * No external dependencies — HTTP over raw POSIX sockets.
 *
 * Build (native):
 *   make
 *
 * Build (cross, ARM hard-float for Olimex Lime 2):
 *   make CROSS=arm-linux-gnueabihf-
 *
 * Usage:
 *   ./board_register <server_ip> [port]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define SID_LEN        16          /* 128-bit SID → 32 hex chars */
#define CHIP_ID_HEX    (SID_LEN * 2 + 1)
#define HOSTNAME_MAX   64
#define SERVER_COMM    "/etc/acms/server_comm"

/* sysfs paths for Allwinner A20 SID, tried in order */
static const char *SID_PATHS[] = {
    "/sys/bus/nvmem/devices/sunxi-sid0/nvmem",
    "/sys/devices/platform/soc/1c23800.sid/nvmem/sunxi-sid0/nvmem",
    NULL
};

/* ── chip ID ─────────────────────────────────────────────────────────────── */

static int read_chip_id(char *out)  /* out: CHIP_ID_HEX bytes */
{
    uint8_t buf[SID_LEN];

    for (int i = 0; SID_PATHS[i]; i++) {
        FILE *f = fopen(SID_PATHS[i], "rb");
        if (!f) continue;
        size_t n = fread(buf, 1, SID_LEN, f);
        fclose(f);
        if (n < 4) continue;
        int nonzero = 0;
        for (size_t j = 0; j < n; j++) nonzero |= buf[j];
        if (!nonzero) continue;
        for (size_t j = 0; j < n; j++)
            sprintf(out + j * 2, "%02x", buf[j]);
        out[n * 2] = '\0';
        return 0;
    }

    /* fallback: /proc/cpuinfo Serial */
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (strncasecmp(line, "serial", 6) == 0) {
                char *colon = strchr(line, ':');
                if (colon) {
                    char *s = colon + 1;
                    while (*s == ' ' || *s == '\t') s++;
                    s[strcspn(s, "\r\n")] = '\0';
                    int allzero = 1;
                    for (char *p = s; *p; p++)
                        if (*p != '0') { allzero = 0; break; }
                    if (!allzero && *s) {
                        strncpy(out, s, CHIP_ID_HEX - 1);
                        out[CHIP_ID_HEX - 1] = '\0';
                        fclose(f);
                        return 0;
                    }
                }
            }
        }
        fclose(f);
    }

    return -1;
}

/* ── hostname ────────────────────────────────────────────────────────────── */

static void read_hostname(char *out)  /* out: HOSTNAME_MAX bytes */
{
    out[0] = '\0';
    FILE *f = fopen(SERVER_COMM, "r");
    if (!f) return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "HOSTNAME=", 9) == 0) {
            char *s = line + 9;
            s[strcspn(s, "\r\n")] = '\0';
            size_t slen = strlen(s);
            if (slen >= HOSTNAME_MAX) slen = HOSTNAME_MAX - 1;
            memcpy(out, s, slen);
            out[slen] = '\0';
            break;
        }
    }
    fclose(f);
}

/* ── HTTP POST (raw socket) ──────────────────────────────────────────────── */

static int post_registration(const char *server_ip, int port,
                             const char *chip_id, const char *hostname)
{
    /* build JSON payload */
    char payload[256];
    int  payload_len;
    if (hostname[0])
        payload_len = snprintf(payload, sizeof(payload),
                               "{\"chip_id\":\"%s\",\"hostname\":\"%s\"}",
                               chip_id, hostname);
    else
        payload_len = snprintf(payload, sizeof(payload),
                               "{\"chip_id\":\"%s\"}", chip_id);

    /* build HTTP request */
    char request[512];
    int  req_len = snprintf(request, sizeof(request),
        "POST /api/register HTTP/1.0\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        server_ip, port, payload_len, payload);

    /* connect */
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }

    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port   = htons((uint16_t)port),
    };
    if (inet_pton(AF_INET, server_ip, &addr.sin_addr) != 1) {
        fprintf(stderr, "ERROR: invalid IP address: %s\n", server_ip);
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "ERROR: connect to %s:%d failed — %s\n",
                server_ip, port, strerror(errno));
        close(fd);
        return -1;
    }

    /* send */
    if (send(fd, request, req_len, 0) < 0) {
        perror("send");
        close(fd);
        return -1;
    }

    /* read response */
    char resp[512];
    ssize_t n = recv(fd, resp, sizeof(resp) - 1, 0);
    close(fd);

    if (n < 0) { perror("recv"); return -1; }
    resp[n] = '\0';

    /* print status line + body (skip headers) */
    char *body = strstr(resp, "\r\n\r\n");
    if (body) body += 4; else body = resp;
    /* first line = HTTP status */
    char *status_end = strstr(resp, "\r\n");
    if (status_end) *status_end = '\0';
    printf("Server  : %s\n", resp);
    if (*body) printf("Response: %s\n", body);

    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr,
            "Usage: %s <server_ip> [port]\n"
            "  e.g. %s 192.168.1.10\n"
            "  e.g. %s 192.168.1.10 9000\n",
            argv[0], argv[0], argv[0]);
        return 1;
    }

    const char *server_ip = argv[1];
    int port = (argc > 2) ? atoi(argv[2]) : 8000;

    char chip_id[CHIP_ID_HEX];
    if (read_chip_id(chip_id) != 0) {
        fprintf(stderr,
            "ERROR: could not read chip ID\n"
            "  Verify sunxi-sid driver is loaded:\n"
            "    ls /sys/bus/nvmem/devices/\n"
            "    sudo modprobe sunxi-sid\n");
        return 1;
    }

    char hostname[HOSTNAME_MAX];
    read_hostname(hostname);

    printf("Chip ID  : %s\n", chip_id);
    printf("Hostname : %s\n", hostname[0] ? hostname : "(not set)");
    printf("Server   : %s:%d\n", server_ip, port);

    return post_registration(server_ip, port, chip_id, hostname) == 0 ? 0 : 1;
}
