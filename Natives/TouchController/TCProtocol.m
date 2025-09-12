//
// TCProtocol.m
//

#import "TCProtocol.h"
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

uint32_t tc_htonf(float f) {
    uint32_t u;
    memcpy(&u, &f, sizeof(u));
    u = htonl(u);
    return u;
}

float tc_ntohf(uint32_t u) {
    uint32_t v = ntohl(u);
    float f;
    memcpy(&f, &v, sizeof(f));
    return f;
}

uint32_t tc_hton32(int32_t v) {
    return htonl((uint32_t)v);
}

int tc_write_fully(int fd, const void *buf, size_t count) {
    const uint8_t *p = buf;
    size_t left = count;
    while (left > 0) {
        ssize_t w = write(fd, p, left);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        left -= (size_t)w;
        p += w;
    }
    return 0;
}

int tc_read_fully(int fd, void *buf, size_t count) {
    uint8_t *p = buf;
    size_t left = count;
    while (left > 0) {
        ssize_t r = read(fd, p, left);
        if (r == 0) return 0; // closed by peer
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        left -= (size_t)r;
        p += r;
    }
    return 1;
}