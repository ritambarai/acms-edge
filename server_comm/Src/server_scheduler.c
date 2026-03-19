/*
 * server_scheduler.c
 *
 * Perpetual ACMS board lifecycle scheduler.
 *
 * Runs as a systemd service after acms-network-setup. Manages child
 * processes non-blocking via SIGCHLD + sigsuspend(); children run
 * independently and the scheduler advances only on their completion.
 *
 * Decision files (in /etc/acms/):
 *   board_state     — stateCode + filePath + any extra vars
 *                     created with stateCode=2 if absent
 *   server_response — server's reply after send_state; contains stateCode
 *                     for the next board state
 *
 * Flow per iteration:
 *   1. Read board_state (create if absent)
 *   2. Spawn primary child for stateCode (e.g. stateCode=2 → core_id)
 *   3. Primary exits → spawn send_state with stateCode + filePath vars as kwargs
 *   4. send_state exits → read server_response → update board_state stateCode
 *   5. Loop to 1
 *
 * Primary programs by stateCode:
 *   2 (Board_Registration) → core_id
 *   others                 → no primary (send_state called directly)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <errno.h>

/* Override at compile time for testing:
 *   -DACMS_DIR='"/tmp/test/acms"' -DBIN_PREFIX='"/tmp/test/bin/"' */
#ifndef ACMS_DIR
#define ACMS_DIR   "/etc/acms"
#endif
#ifndef BIN_PREFIX
#define BIN_PREFIX "/usr/local/bin/"
#endif

#define BOARD_STATE         ACMS_DIR   "/board_state"
#define SERVER_RESPONSE     ACMS_DIR   "/server_response"
#define STATE_TABLE         ACMS_DIR   "/state_table"
#define SEND_STATE_BIN      BIN_PREFIX "send_state"
#define INSTALL_PACKAGE_BIN BIN_PREFIX "install_package"

#define KV_MAX   32
#define KEY_MAX  64
#define VAL_MAX  256
#define ARG_MAX  (KV_MAX * 2 + 4)
#define ARG_BUF  (KEY_MAX + VAL_MAX + 4)  /* key + '=' + val + NUL + slack */

/* ── state machine ───────────────────────────────────────────────────────── */

typedef enum {
    SCHED_READ_BOARD,       /* read board_state, spawn primary child      */
    SCHED_WAIT_PRIMARY,     /* waiting for primary child to exit          */
    SCHED_WAIT_SEND_STATE,  /* waiting for send_state child to exit       */
} SchedState;

/* ── key/value store ─────────────────────────────────────────────────────── */

typedef struct { char key[KEY_MAX]; char val[VAL_MAX]; } KV;

static int read_kvs(const char *path, KV *kvs, int max)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int n = 0;
    char line[512];
    while (n < max && fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0') continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        size_t klen = (size_t)(eq - p);
        if (klen == 0 || klen >= KEY_MAX) continue;
        char *v = eq + 1;
        v[strcspn(v, "\r\n")] = '\0';
        memcpy(kvs[n].key, p, klen);
        kvs[n].key[klen] = '\0';
        strncpy(kvs[n].val, v, VAL_MAX - 1);
        kvs[n].val[VAL_MAX - 1] = '\0';
        n++;
    }
    fclose(f);
    return n;
}

static const char *kv_get(const KV *kvs, int n, const char *key)
{
    for (int i = 0; i < n; i++)
        if (strcmp(kvs[i].key, key) == 0) return kvs[i].val;
    return NULL;
}

/* Reads key=value pairs from a named [section] in a file. */
static int read_section(const char *path, const char *section, KV *kvs, int max)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;

    char want[KEY_MAX + 2];
    snprintf(want, sizeof(want), "[%s]", section);

    char line[512];
    int in_section = 0, n = 0;

    while (n < max && fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0') continue;

        if (*p == '[') {
            p[strcspn(p, "\r\n")] = '\0';
            in_section = (strcmp(p, want) == 0);
            continue;
        }

        if (!in_section) continue;

        char *eq = strchr(p, '=');
        if (!eq) continue;
        size_t klen = (size_t)(eq - p);
        if (klen == 0 || klen >= KEY_MAX) continue;
        char *v = eq + 1;
        v[strcspn(v, "\r\n")] = '\0';
        memcpy(kvs[n].key, p, klen);
        kvs[n].key[klen] = '\0';
        strncpy(kvs[n].val, v, VAL_MAX - 1);
        kvs[n].val[VAL_MAX - 1] = '\0';
        n++;
    }

    fclose(f);
    return n;
}

/*
 * Look up the executable for a numeric stateCode from state_table.
 * Sets out to full path "/usr/local/bin/<name>", or "" if blank (no primary).
 * Returns 0 on success, -1 if state_table unreadable or stateCode unknown.
 */
static int lookup_executable(int sc, char *out, size_t out_max)
{
    KV codes[KV_MAX];
    int cn = read_section(STATE_TABLE, "stateCode", codes, KV_MAX);
    if (cn < 0) {
        fprintf(stderr, "[sched] cannot read state_table\n");
        return -1;
    }

    char sc_str[16];
    snprintf(sc_str, sizeof(sc_str), "%d", sc);
    const char *name = NULL;
    for (int i = 0; i < cn; i++)
        if (strcmp(codes[i].val, sc_str) == 0) { name = codes[i].key; break; }

    if (!name) {
        fprintf(stderr, "[sched] stateCode %d not found in state_table\n", sc);
        return -1;
    }

    KV execs[KV_MAX];
    int en = read_section(STATE_TABLE, "Executables", execs, KV_MAX);
    if (en < 0) {
        fprintf(stderr, "[sched] cannot read [Executables] in state_table\n");
        return -1;
    }

    for (int i = 0; i < en; i++) {
        if (strcmp(execs[i].key, name) == 0) {
            if (execs[i].val[0] == '\0')
                out[0] = '\0';
            else
                snprintf(out, out_max, "%s%s", BIN_PREFIX, execs[i].val);
            return 0;
        }
    }

    fprintf(stderr, "[sched] no Executables entry for state '%s'\n", name);
    return -1;
}

static int write_kvs(const char *path, const KV *kvs, int n)
{
    /* derive temp path in same directory for atomic rename */
    char tmp[320];
    const char *slash = strrchr(path, '/');
    if (slash) {
        size_t dlen = (size_t)(slash - path + 1);
        memcpy(tmp, path, dlen);
        strncpy(tmp + dlen, ".sched_XXXXXX", sizeof(tmp) - dlen - 1);
    } else {
        strncpy(tmp, ".sched_XXXXXX", sizeof(tmp) - 1);
    }

    int fd = mkstemp(tmp);
    if (fd < 0) { perror("mkstemp"); return -1; }
    FILE *f = fdopen(fd, "w");
    if (!f) { close(fd); unlink(tmp); return -1; }
    for (int i = 0; i < n; i++)
        fprintf(f, "%s=%s\n", kvs[i].key, kvs[i].val);
    fclose(f);
    chmod(tmp, 0640);
    if (rename(tmp, path) != 0) { perror("rename"); unlink(tmp); return -1; }
    return 0;
}

/* ── SIGCHLD ─────────────────────────────────────────────────────────────── */

static volatile sig_atomic_t g_child_exited = 0;
static pid_t    g_child_pid  = -1;
static int      g_exit_code  = 0;

static void sigchld_handler(int sig) { (void)sig; g_child_exited = 1; }

static void reap_children(void)
{
    int status;
    pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        if (pid == g_child_pid) {
            g_exit_code = code;
            g_child_pid = -1;
            printf("[sched] child pid=%d exited (code=%d)\n", pid, code);
        }
    }
}

/*
 * Wait for g_child_pid to exit, non-blocking via sigsuspend.
 * Atomically unblocks SIGCHLD and suspends — no race between
 * checking the flag and sleeping.
 */
static void wait_for_child(void)
{
    sigset_t block, prev;
    sigemptyset(&block);
    sigaddset(&block, SIGCHLD);

    sigprocmask(SIG_BLOCK, &block, &prev);
    while (g_child_pid != -1 && !g_child_exited)
        sigsuspend(&prev);              /* atomically sleep + unblock */
    sigprocmask(SIG_UNBLOCK, &block, NULL);

    g_child_exited = 0;
    reap_children();
}

/* ── child spawning ──────────────────────────────────────────────────────── */

static pid_t spawn(const char **argv)
{
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return -1; }
    if (pid == 0) {
        execv(argv[0], (char *const *)argv);
        perror("execv");
        _exit(127);
    }
    printf("[sched] spawned %s  pid=%d\n", argv[0], pid);
    return pid;
}

/*
 * Build send_state argv from board_state kvs + filePath file vars.
 * Uses static buffers — not re-entrant, but fine for sequential use.
 */
static pid_t spawn_send_state(const KV *board, int bn)
{
    static char bufs[ARG_MAX][ARG_BUF];
    const char *argv[ARG_MAX + 2];
    int ai = 0, bi = 0;

    const char *sc = kv_get(board, bn, "stateCode");
    if (!sc) { fprintf(stderr, "[sched] no stateCode in board_state\n"); return -1; }

    argv[ai++] = SEND_STATE_BIN;

    snprintf(bufs[bi], ARG_BUF, "stateCode=%s", sc);
    argv[ai++] = bufs[bi++];

    /* vars from filePath file */
    const char *fp = kv_get(board, bn, "filePath");
    if (fp) {
        KV fp_kvs[KV_MAX];
        int fn = read_kvs(fp, fp_kvs, KV_MAX);
        for (int i = 0; i < fn && bi < ARG_MAX - 2; i++) {
            snprintf(bufs[bi], ARG_BUF, "%.*s=%.*s",
                     KEY_MAX - 1, fp_kvs[i].key, VAL_MAX - 1, fp_kvs[i].val);
            argv[ai++] = bufs[bi++];
        }
    }

    /* remaining board_state vars (skip stateCode and filePath) */
    for (int i = 0; i < bn && bi < ARG_MAX - 1; i++) {
        if (strcmp(board[i].key, "stateCode") == 0) continue;
        if (strcmp(board[i].key, "filePath")  == 0) continue;
        snprintf(bufs[bi], ARG_BUF, "%.*s=%.*s",
                 KEY_MAX - 1, board[i].key, VAL_MAX - 1, board[i].val);
        argv[ai++] = bufs[bi++];
    }

    argv[ai] = NULL;
    return spawn(argv);
}

/* ── board_state helpers ─────────────────────────────────────────────────── */

static void ensure_board_state(void)
{
    if (access(BOARD_STATE, F_OK) == 0) return;

    /* Only write stateCode — filePath is written by core_id after it runs */
    KV kvs[KV_MAX]; int n = 0;
    snprintf(kvs[n].key, KEY_MAX, "%s", "stateCode");
    snprintf(kvs[n].val, VAL_MAX, "%s", "2"); n++;

    if (write_kvs(BOARD_STATE, kvs, n) == 0)
        printf("[sched] created board_state (stateCode=2)\n");
    else
        fprintf(stderr, "[sched] ERROR: could not create board_state\n");
}

static void update_board_state_code(const char *new_sc)
{
    KV kvs[KV_MAX]; int n = 0;
    snprintf(kvs[n].key, KEY_MAX, "%s", "stateCode");
    snprintf(kvs[n].val, VAL_MAX, "%s", new_sc); n++;
    write_kvs(BOARD_STATE, kvs, n);
}

/* ── main loop ───────────────────────────────────────────────────────────── */

int main(void)
{
    /* set up SIGCHLD — SA_RESTART so slow syscalls resume after signal */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigchld_handler;
    sa.sa_flags   = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGCHLD, &sa, NULL);

    printf("[sched] ACMS scheduler starting\n");

    SchedState state = SCHED_READ_BOARD;

    for (;;) {

        switch (state) {

        /* ── 1. read board_state, spawn primary child ─────────────────── */
        case SCHED_READ_BOARD: {
            ensure_board_state();

            KV board[KV_MAX];
            int bn = read_kvs(BOARD_STATE, board, KV_MAX);
            if (bn < 0) {
                fprintf(stderr, "[sched] cannot read board_state, retrying in 5s\n");
                sleep(5);
                break;
            }

            const char *sc_str = kv_get(board, bn, "stateCode");
            int sc = sc_str ? atoi(sc_str) : 2;
            printf("[sched] stateCode=%d\n", sc);

            char prog[256];
            if (lookup_executable(sc, prog, sizeof(prog)) < 0) { sleep(5); break; }

            if (prog[0] != '\0') {
                const char *argv[] = { prog, NULL };
                g_child_pid = spawn(argv);
                if (g_child_pid < 0) { sleep(5); break; }
                state = SCHED_WAIT_PRIMARY;
            } else {
                /* blank entry — go straight to send_state */
                g_child_pid = spawn_send_state(board, bn);
                if (g_child_pid < 0) { sleep(5); break; }
                state = SCHED_WAIT_SEND_STATE;
            }
            break;
        }

        /* ── 2. wait for primary child, then spawn send_state ─────────── */
        case SCHED_WAIT_PRIMARY:
            wait_for_child();

            if (g_exit_code != 0)
                fprintf(stderr, "[sched] primary child exited with code %d\n", g_exit_code);

            {
                KV board[KV_MAX];
                int bn = read_kvs(BOARD_STATE, board, KV_MAX);
                if (bn < 0) { sleep(5); state = SCHED_READ_BOARD; break; }
                g_child_pid = spawn_send_state(board, bn);
                if (g_child_pid < 0) { sleep(5); state = SCHED_READ_BOARD; break; }
                state = SCHED_WAIT_SEND_STATE;
            }
            break;

        /* ── 3. wait for send_state, read server_response, loop ───────── */
        case SCHED_WAIT_SEND_STATE:
            wait_for_child();

            if (g_exit_code != 0)
                fprintf(stderr, "[sched] send_state exited with code %d\n", g_exit_code);

            {
                KV resp[KV_MAX];
                int rn = read_kvs(SERVER_RESPONSE, resp, KV_MAX);
                if (rn > 0) {
                    const char *new_sc = kv_get(resp, rn, "stateCode");
                    if (new_sc) {
                        printf("[sched] server_response → stateCode=%s\n", new_sc);
                        update_board_state_code(new_sc);
                    }

                    const char *url = kv_get(resp, rn, "url");
                    if (url && url[0] != '\0') {
                        printf("[sched] server_response → url=%s, spawning install_package\n", url);
                        const char *iargv[] = { INSTALL_PACKAGE_BIN, url, NULL };
                        g_child_pid = spawn(iargv);
                        if (g_child_pid >= 0)
                            wait_for_child();
                    }
                } else {
                    printf("[sched] no server_response yet, holding state\n");
                    sleep(10);
                }
                state = SCHED_READ_BOARD;
            }
            break;
        }
    }

    return 0;  /* unreachable */
}
