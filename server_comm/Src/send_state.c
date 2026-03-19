/*
 * send_state.c
 *
 * Reads server connection details from /etc/acms/server_details, packages
 * a stateCode plus any caller-supplied positional args and key=value kwargs
 * into JSON, and POSTs to the API_STATE endpoint.
 *
 * The payload is entirely caller-defined — no fields are hardcoded.
 * Pass whatever kwargs your call site requires.
 *
 * Build:
 *   make send_state
 *
 * Usage:
 *   send_state stateCode=<uint> [key=value ...] [value ...]
 *
 * stateCode must be present as a kwarg; all other args are optional.
 *
 * Examples:
 *   send_state stateCode=3
 *   send_state stateCode=5 status=ok retries=2
 *   send_state stateCode=7 "disk full" severity=critical
 *   send_state stateCode=2 coreId=deadbeef hostname=acms-device macAddress=aa:bb:cc:dd:ee:ff
 *
 * JSON sent:
 *   {"stateCode":<uint>,"args":[...],"kwargs":{...}}
 *
 * Arg classification:
 *   Contains '=' → kwarg  (key is everything before the first '=')
 *   No '='       → positional arg
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netdb.h>

#define SERVER_DETAILS "/etc/acms/server_details"
#define URL_MAX        256
#define HOST_MAX       128
#define PATH_MAX_LEN   128
#define JSON_MAX       8192
#define RESP_MAX       1024

/* ── key/value conf reader ───────────────────────────────────────────────── */

/*
 * Reads the first occurrence of <key>= from <file> into <out> (max <out_max>
 * bytes including NUL). Lines beginning with '#' are skipped.
 * Returns 0 on success, -1 if not found.
 */
static int read_conf(const char *file, const char *key, char *out, size_t out_max)
{
    FILE *f = fopen(file, "r");
    if (!f) return -1;

    size_t klen = strlen(key);
    char line[512];
    int found = -1;

    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#') continue;
        if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
            char *v = line + klen + 1;
            v[strcspn(v, "\r\n")] = '\0';
            strncpy(out, v, out_max - 1);
            out[out_max - 1] = '\0';
            found = 0;
            break;
        }
    }

    fclose(f);
    return found;
}

/* ── URL parser ──────────────────────────────────────────────────────────── */

/*
 * Extracts host and port from "http://host[:port][/...]".
 * Defaults to port 80 if absent.
 */
static int parse_url(const char *url, char *host, size_t host_max, int *port)
{
    *port = 80;
    const char *p = url;
    if (strncmp(p, "http://", 7) == 0) p += 7;

    const char *colon = strchr(p, ':');
    const char *slash = strchr(p, '/');
    size_t host_len;

    if (colon && (!slash || colon < slash)) {
        host_len = (size_t)(colon - p);
        *port = atoi(colon + 1);
    } else if (slash) {
        host_len = (size_t)(slash - p);
    } else {
        host_len = strlen(p);
    }

    if (host_len == 0 || host_len >= host_max) {
        fprintf(stderr, "ERROR: could not parse host from URL: %s\n", url);
        return -1;
    }
    memcpy(host, p, host_len);
    host[host_len] = '\0';
    return 0;
}

/* ── JSON builder ────────────────────────────────────────────────────────── */

typedef struct { char *buf; size_t cap; size_t len; } Buf;

static int buf_cat(Buf *b, const char *s)
{
    size_t n = strlen(s);
    if (b->len + n >= b->cap) {
        fprintf(stderr, "ERROR: JSON payload too large\n");
        return -1;
    }
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
    return 0;
}

/* Appends a JSON-encoded string (with surrounding quotes) */
static int buf_json_str(Buf *b, const char *s)
{
    if (buf_cat(b, "\"") < 0) return -1;
    for (; *s; s++) {
        char esc[8];
        unsigned char c = (unsigned char)*s;
        if      (c == '"')  { if (buf_cat(b, "\\\"") < 0) return -1; }
        else if (c == '\\') { if (buf_cat(b, "\\\\") < 0) return -1; }
        else if (c == '\n') { if (buf_cat(b, "\\n")  < 0) return -1; }
        else if (c == '\r') { if (buf_cat(b, "\\r")  < 0) return -1; }
        else if (c == '\t') { if (buf_cat(b, "\\t")  < 0) return -1; }
        else if (c < 0x20)  {
            snprintf(esc, sizeof(esc), "\\u%04x", c);
            if (buf_cat(b, esc) < 0) return -1;
        } else {
            char ch[2] = { (char)c, '\0' };
            if (buf_cat(b, ch) < 0) return -1;
        }
    }
    return buf_cat(b, "\"");
}

/*
 * Builds JSON from all argv entries.
 * stateCode=<N> must be present among them; it becomes the top-level
 * "stateCode" field and is excluded from the "kwargs" object.
 * Returns the extracted stateCode via *state_code_out, or -1 on error.
 */
static int build_json(Buf *b, int argc, char **argv,
                      unsigned int *state_code_out)
{
    const char *args[64];
    const char *kwkeys[64];
    const char *kwvals[64];
    int nargs = 0, nkw = 0;
    int sc_idx = -1;

    for (int i = 0; i < argc; i++) {
        char *eq = strchr(argv[i], '=');
        if (eq) {
            if (nkw >= 64) { fprintf(stderr, "ERROR: too many kwargs\n"); return -1; }
            *eq = '\0';                  /* split in-place */
            kwkeys[nkw] = argv[i];
            kwvals[nkw] = eq + 1;
            if (strcmp(kwkeys[nkw], "stateCode") == 0)
                sc_idx = nkw;
            nkw++;
        } else {
            if (nargs >= 64) { fprintf(stderr, "ERROR: too many args\n"); return -1; }
            args[nargs++] = argv[i];
        }
    }

    if (sc_idx < 0) {
        fprintf(stderr, "ERROR: stateCode=<uint> is required\n");
        return -1;
    }

    char *end;
    unsigned long sc = strtoul(kwvals[sc_idx], &end, 10);
    if (*end != '\0') {
        fprintf(stderr, "ERROR: stateCode must be an unsigned integer, got: %s\n",
                kwvals[sc_idx]);
        return -1;
    }
    *state_code_out = (unsigned int)sc;

    /* {"stateCode":<N>, */
    char sc_str[32];
    snprintf(sc_str, sizeof(sc_str), "%u", *state_code_out);
    if (buf_cat(b, "{\"stateCode\":") < 0) return -1;
    if (buf_cat(b, sc_str)           < 0) return -1;
    if (buf_cat(b, ",")              < 0) return -1;

    /* "args":[...], */
    if (buf_cat(b, "\"args\":[") < 0) return -1;
    for (int i = 0; i < nargs; i++) {
        if (i > 0 && buf_cat(b, ",") < 0) return -1;
        if (buf_json_str(b, args[i]) < 0) return -1;
    }
    if (buf_cat(b, "],") < 0) return -1;

    /* "kwargs":{...} — stateCode excluded */
    if (buf_cat(b, "\"kwargs\":{") < 0) return -1;
    int first = 1;
    for (int i = 0; i < nkw; i++) {
        if (i == sc_idx) continue;
        if (!first && buf_cat(b, ",") < 0) return -1;
        if (buf_json_str(b, kwkeys[i]) < 0) return -1;
        if (buf_cat(b, ":")            < 0) return -1;
        if (buf_json_str(b, kwvals[i]) < 0) return -1;
        first = 0;
    }
    return buf_cat(b, "}}");
}

/* ── HTTP POST ───────────────────────────────────────────────────────────── */

static int post_json(const char *host, int port, const char *path,
                     const char *payload, size_t payload_len)
{
    /* resolve host */
    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%d", port);

    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    int rc = getaddrinfo(host, port_str, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "ERROR: getaddrinfo(%s): %s\n", host, gai_strerror(rc));
        return -1;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { perror("socket"); freeaddrinfo(res); return -1; }

    struct timeval tv = { .tv_sec = 10 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        fprintf(stderr, "ERROR: connect to %s:%d — %s\n", host, port, strerror(errno));
        freeaddrinfo(res); close(fd); return -1;
    }
    freeaddrinfo(res);

    /* build and send request */
    char request[JSON_MAX + 512];
    int req_len = snprintf(request, sizeof(request),
        "POST %s HTTP/1.0\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        path, host, port, payload_len, payload);

    if (send(fd, request, (size_t)req_len, 0) < 0) {
        perror("send"); close(fd); return -1;
    }

    /* read and print response */
    char resp[RESP_MAX];
    ssize_t n = recv(fd, resp, sizeof(resp) - 1, 0);
    close(fd);

    if (n < 0) { perror("recv"); return -1; }
    resp[n] = '\0';

    char *status_end = strstr(resp, "\r\n");
    if (status_end) *status_end = '\0';
    printf("Server  : %s\n", resp);

    char *body = strstr(status_end ? status_end + 2 : resp, "\r\n\r\n");
    if (body && *(body + 4)) printf("Response: %s\n", body + 4);

    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr,
            "Usage: %s stateCode=<uint> [key=value ...] [value ...]\n"
            "  e.g. %s stateCode=3\n"
            "  e.g. %s stateCode=5 status=ok retries=2\n"
            "  e.g. %s stateCode=7 \"disk full\" severity=critical\n",
            argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }

    /* build and validate JSON first (catches missing/invalid stateCode early) */
    char json_buf[JSON_MAX];
    Buf b = { .buf = json_buf, .cap = sizeof(json_buf), .len = 0 };
    json_buf[0] = '\0';

    unsigned int sc = 0;
    if (build_json(&b, argc - 1, argv + 1, &sc) < 0)
        return 1;

    printf("StateCode: %u\n", sc);
    printf("Payload  : %s\n", json_buf);

    /* read server config */
    char server_url[URL_MAX];
    char api_state[PATH_MAX_LEN];

    if (read_conf(SERVER_DETAILS, "SERVER_URL", server_url, sizeof(server_url)) < 0) {
        fprintf(stderr, "ERROR: SERVER_URL not found in %s\n", SERVER_DETAILS);
        return 1;
    }
    if (read_conf(SERVER_DETAILS, "API_STATE", api_state, sizeof(api_state)) < 0) {
        fprintf(stderr, "ERROR: API_STATE not found in %s\n", SERVER_DETAILS);
        return 1;
    }

    char host[HOST_MAX];
    int  port;
    if (parse_url(server_url, host, sizeof(host), &port) < 0)
        return 1;

    printf("Server   : %s:%d%s\n", host, port, api_state);

    return post_json(host, port, api_state, json_buf, b.len) == 0 ? 0 : 1;
}
