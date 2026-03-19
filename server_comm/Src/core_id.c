/*
 * core_id.c
 *
 * Reads the Allwinner A20 SID (hardware-fused unique chip ID) from sysfs
 * and saves it as CoreID in /etc/acms/server_comm.
 *
 * Existing lines in server_comm are preserved; CoreID is inserted or
 * replaced atomically via a temp-file rename.
 *
 * Build:
 *   make core_id
 *
 * Usage (run as root):
 *   ./core_id
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/stat.h>

#define SID_LEN      16              /* 128-bit SID → 32 hex chars */
#define CHIP_ID_HEX  (SID_LEN * 2 + 1)
#define SERVER_COMM  "/etc/acms/server_comm"

static const char *SID_PATHS[] = {
    "/sys/bus/nvmem/devices/sunxi-sid0/nvmem",
    "/sys/devices/platform/soc/1c23800.sid/nvmem/sunxi-sid0/nvmem",
    NULL
};

/* ── chip ID ─────────────────────────────────────────────────────────────── */

static int read_chip_id(char *out)  /* out must be CHIP_ID_HEX bytes */
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

/* ── save CoreID ─────────────────────────────────────────────────────────── */

static int save_core_id(const char *chip_id)
{
    char tmp_path[] = "/etc/acms/.server_comm.XXXXXX";

    int fd = mkstemp(tmp_path);
    if (fd < 0) { perror("mkstemp"); return -1; }

    FILE *tmp = fdopen(fd, "w");
    if (!tmp) { perror("fdopen"); close(fd); unlink(tmp_path); return -1; }

    /* copy existing lines, skipping any stale CoreID */
    FILE *cur = fopen(SERVER_COMM, "r");
    if (cur) {
        char line[256];
        while (fgets(line, sizeof(line), cur))
            if (strncmp(line, "CoreID=", 7) != 0)
                fputs(line, tmp);
        fclose(cur);
    }

    fprintf(tmp, "CoreID=%s\n", chip_id);
    fclose(tmp);

    chmod(tmp_path, 0640);

    if (rename(tmp_path, SERVER_COMM) != 0) {
        perror("rename");
        unlink(tmp_path);
        return -1;
    }

    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(void)
{
    char chip_id[CHIP_ID_HEX];

    if (read_chip_id(chip_id) != 0) {
        fprintf(stderr,
            "ERROR: could not read chip ID\n"
            "  Verify sunxi-sid driver is loaded:\n"
            "    ls /sys/bus/nvmem/devices/\n"
            "    sudo modprobe sunxi-sid\n");
        return 1;
    }

    printf("CoreID: %s\n", chip_id);

    if (save_core_id(chip_id) != 0) {
        fprintf(stderr, "ERROR: could not save CoreID to %s\n", SERVER_COMM);
        return 1;
    }

    printf("Saved to %s\n", SERVER_COMM);
    return 0;
}
