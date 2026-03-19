/*
 * state_wait.c
 *
 * Sleeps for a stateCode-defined duration then exits, handing control
 * back to the scheduler. Used as the primary executable for idle states
 * (Running, Waiting) so the scheduler paces its send_state calls.
 *
 * Sleep is done with nanosleep() in a signal-safe loop so the process
 * consumes zero CPU while waiting.
 *
 * Build:
 *   make state_wait
 *
 * Usage:
 *   state_wait stateCode=<uint>
 *
 * Durations (seconds):
 *   stateCode 0 (Running) → WAIT_RUNNING
 *   stateCode 1 (Waiting) → WAIT_WAITING
 *   all others            → 0  (exit immediately)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#ifndef WAIT_RUNNING
#define WAIT_RUNNING   30   /* seconds for stateCode=0 (Running) */
#endif
#ifndef WAIT_WAITING
#define WAIT_WAITING   15   /* seconds for stateCode=1 (Waiting) */
#endif

static unsigned int duration_for(unsigned int sc)
{
    switch (sc) {
        case 0: return WAIT_RUNNING;
        case 1: return WAIT_WAITING;
        default: return 0;
    }
}

/*
 * Sleep for <secs> seconds using nanosleep(), retrying on EINTR so
 * signals don't cut the wait short.
 */
static void sleep_secs(unsigned int secs)
{
    struct timespec rem = { .tv_sec = (time_t)secs, .tv_nsec = 0 };
    while (rem.tv_sec > 0 || rem.tv_nsec > 0) {
        struct timespec req = rem;
        if (nanosleep(&req, &rem) == 0)
            break;
        if (errno != EINTR)
            break;
    }
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s stateCode=<uint>\n", argv[0]);
        return 1;
    }

    /* find stateCode=<N> among args */
    unsigned int sc = 0;
    int found = 0;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "stateCode=", 10) == 0) {
            char *end;
            unsigned long v = strtoul(argv[i] + 10, &end, 10);
            if (*end != '\0') {
                fprintf(stderr, "ERROR: stateCode must be an unsigned integer\n");
                return 1;
            }
            sc    = (unsigned int)v;
            found = 1;
            break;
        }
    }

    if (!found) {
        fprintf(stderr, "ERROR: stateCode=<uint> is required\n");
        return 1;
    }

    unsigned int secs = duration_for(sc);
    printf("state_wait: stateCode=%u  waiting %us\n", sc, secs);

    if (secs > 0)
        sleep_secs(secs);

    return 0;
}
