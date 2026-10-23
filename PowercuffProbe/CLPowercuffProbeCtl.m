#import "CLPowercuffCore.h"
#include <notify.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int main(int argc, char **argv) {
    int token = -1;
    if (argc == 3 && strcmp(argv[1], "request") == 0) {
        char *end = NULL;
        errno = 0;
        unsigned long mode = strtoul(argv[2], &end, 10);
        if (errno != 0 || end == argv[2] || *end != '\0' || mode > 4) return 2;
        uint32_t result = notify_register_check(CLPC_REQUEST_NOTIFICATION, &token);
        if (result == 0) result = notify_set_state(token, mode);
        if (result == 0) result = notify_post(CLPC_REQUEST_NOTIFICATION);
        if (token >= 0) notify_cancel(token);
        printf("{\"request_sent\":%s,\"observer_only\":true,\"mode\":%lu}\n",
            result == 0 ? "true" : "false", mode);
        return result == 0 ? 0 : 1;
    }
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "status") != 0)) return 2;
    uint64_t state = 0;
    uint32_t result = notify_register_check(CLPC_STATUS_NOTIFICATION, &token);
    if (result == 0) result = notify_get_state(token, &state);
    if (token >= 0) notify_cancel(token);
    if (result != 0) return 1;
    printf("{\"hook_installed\":%s,\"product_captured\":%s,\"observer_only\":%s,"
        "\"signature_rejected\":%s,\"result\":%u,\"last_mode\":%u,"
        "\"requests\":%llu,\"returned_calls\":%llu,\"captures\":%llu,"
        "\"note\":\"last published status; not a liveness or power-effect guarantee\"}\n",
        (state & 1) ? "true" : "false", (state & 2) ? "true" : "false",
        (state & 4) ? "true" : "false", (state & 8) ? "true" : "false",
        (unsigned)((state >> 4) & 15), (unsigned)((state >> 8) & 255),
        (unsigned long long)((state >> 16) & 0xffff),
        (unsigned long long)((state >> 32) & 0xffff),
        (unsigned long long)((state >> 48) & 0xffff));
    return 0;
}
