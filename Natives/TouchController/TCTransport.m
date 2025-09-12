//
// TCTransport.m
// Lightweight Unix domain socket server for communicating with TouchController proxy
//
// This implementation uses a filesystem Unix domain socket (in NSTemporaryDirectory)
// and sets TOUCH_CONTROLLER_PROXY_SOCKET environment variable to the socket path so
// the TouchController side can connect to it.
//
// Notes:
//  - This is a simple, single-client server. It accepts one client at a time
//    (which is expected for launcher-mod IPC).
//  - It supports sending Add/Remove/Clear/MoveView messages and receives Vibrate/KeyboardShow/Initialize messages.
//  - For more advanced protocol handling (LargeMessage, InputStatus, etc.) extend recv loop parsing.
//

#import "TCTransport.h"
#import "TCProtocol.h"
#import <pthread.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdlib.h>
#import <UIKit/UIKit.h>

static int server_fd = -1;
static int client_fd = -1;
static pthread_t accept_thread;
static pthread_t recv_thread;
static volatile int running = 0;
static NSString *g_socketName = nil;
static NSString *g_socketPath = nil;

static void *accept_loop(void *arg);
static void *recv_loop(void *arg);

static void close_client_fd_safe(void) {
    if (client_fd >= 0) {
        close(client_fd);
        client_fd = -1;
    }
}

static void close_server_fd_safe(void) {
    if (server_fd >= 0) {
        close(server_fd);
        server_fd = -1;
    }
}

void TC_StartServer(NSString * _Nullable socketName) {
    if (running) return;
    running = 1;
    g_socketName = socketName ?: @"AmethystLauncher";

    // Create a path for a unix socket in TMP dir
    NSString *tmp = NSTemporaryDirectory();
    if (tmp == nil) tmp = @"/tmp/";
    g_socketPath = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"tc_%@.sock", g_socketName]];

    // Ensure previous socket file removed
    unlink([g_socketPath fileSystemRepresentation]);

    // Export environment variable for TouchController mod / game to read
    // Many TouchController implementations expect TOUCH_CONTROLLER_PROXY_SOCKET to be the socket name.
    // Provide the full path here so platform-specific client can connect.
    setenv("TOUCH_CONTROLLER_PROXY_SOCKET", [g_socketPath fileSystemRepresentation], 1);

    // Start accept thread
    pthread_create(&accept_thread, NULL, accept_loop, (__bridge_retained void *)[g_socketPath copy]);
}

void TC_StopServer(void) {
    running = 0;
    close_client_fd_safe();
    close_server_fd_safe();
    // best effort cancel threads
    pthread_cancel(accept_thread);
    pthread_cancel(recv_thread);
}

#pragma mark - send helper

static int send_buffer_to_client(const uint8_t *buf, size_t len) {
    if (client_fd < 0) return -1;
    if (tc_write_fully(client_fd, buf, len) < 0) {
        NSLog(@"TC: write failed: %s", strerror(errno));
        close_client_fd_safe();
        return -1;
    }
    return 0;
}

static void send_message_with_payload(uint32_t type, const uint8_t *payload, size_t payload_len) {
    // message format: 4 bytes type (network order) + payload
    size_t total = 4 + payload_len;
    uint8_t *buffer = malloc(total);
    if (!buffer) return;
    uint32_t nettype = htonl(type);
    memcpy(buffer, &nettype, 4);
    if (payload_len > 0 && payload != NULL) {
        memcpy(buffer + 4, payload, payload_len);
    }
    if (send_buffer_to_client(buffer, total) < 0) {
        // failed; client likely closed
    }
    free(buffer);
}

void TC_SendAddPointer(int32_t index, float x, float y) {
    // Type 1: AddPointer -> payload: int index (4) + float x (4) + float y (4)
    uint8_t payload[12];
    uint32_t i_net = tc_hton32(index);
    uint32_t x_net = tc_htonf(x);
    uint32_t y_net = tc_htonf(y);
    memcpy(payload, &i_net, 4);
    memcpy(payload + 4, &x_net, 4);
    memcpy(payload + 8, &y_net, 4);
    send_message_with_payload(1, payload, sizeof(payload));
}

void TC_SendRemovePointer(int32_t index) {
    uint32_t i_net = tc_hton32(index);
    send_message_with_payload(2, (uint8_t *)&i_net, 4);
}

void TC_SendClearPointer(void) {
    send_message_with_payload(3, NULL, 0);
}

void TC_SendMoveView(BOOL screenBased, float deltaPitch, float deltaYaw) {
    uint8_t payload[1 + 4 + 4];
    payload[0] = screenBased ? 1 : 0;
    uint32_t p_net = tc_htonf(deltaPitch);
    uint32_t y_net = tc_htonf(deltaYaw);
    memcpy(payload + 1, &p_net, 4);
    memcpy(payload + 5, &y_net, 4);
    send_message_with_payload(12, payload, sizeof(payload));
}

#pragma mark - recv loop

static void trigger_haptic_for_kind(int kind) {
    // Only implement BLOCK_BROKEN(0) as example
    dispatch_async(dispatch_get_main_queue(), ^{
        if (kind == 0) { // BLOCK_BROKEN
            UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [g prepare];
            [g impactOccurred];
        } else {
            UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [g prepare];
            [g impactOccurred];
        }
    });
}

static void *recv_loop(void *arg) {
    (void)arg;
    while (running && client_fd >= 0) {
        // Read type first (4 bytes)
        uint32_t nettype;
        int r = tc_read_fully(client_fd, &nettype, 4);
        if (r <= 0) {
            break;
        }
        uint32_t type = ntohl(nettype);

        // Very small message handling for common types
        if (type == 4) { // Vibrate (4 bytes)
            uint32_t netkind;
            if (tc_read_fully(client_fd, &netkind, 4) <= 0) break;
            int kind = (int)ntohl(netkind);
            trigger_haptic_for_kind(kind);
        } else if (type == 8) { // KeyboardShow (1 byte)
            uint8_t b;
            if (tc_read_fully(client_fd, &b, 1) <= 0) break;
            if (b) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TCKeyboardShowNotification" object:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TCKeyboardHideNotification" object:nil];
                });
            }
        } else if (type == 10) { // Initialize (no payload)
            NSLog(@"TC: Initialize received");
        } else {
            // Unknown/unhandled message - try to ignore gracefully.
            NSLog(@"TC: Received unknown message type %u (ignoring)", type);
            // Not reading payload length because proxy-common protocol defines lengths per type.
            // For robustness, we could implement full parsing. For now simply continue.
        }
    }
    return NULL;
}

#pragma mark - accept loop

static void *accept_loop(void *arg) {
    @autoreleasepool {
        NSString *path = (__bridge_transfer NSString *)arg;

        server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (server_fd < 0) {
            NSLog(@"TC: socket() failed: %s", strerror(errno));
            running = 0;
            return NULL;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        const char *cpath = [path fileSystemRepresentation];
        strncpy(addr.sun_path, cpath, sizeof(addr.sun_path) - 1);

        // Unlink if previous file exists
        unlink(cpath);

        socklen_t alen = (socklen_t)offsetof(struct sockaddr_un, sun_path) + (socklen_t)strlen(addr.sun_path);

        if (bind(server_fd, (struct sockaddr *)&addr, (socklen_t)sizeof(addr)) < 0) {
            NSLog(@"TC: bind() failed: %s", strerror(errno));
            close_server_fd_safe();
            running = 0;
            return NULL;
        }

        if (listen(server_fd, 1) < 0) {
            NSLog(@"TC: listen() failed: %s", strerror(errno));
            close_server_fd_safe();
            running = 0;
            return NULL;
        }

        NSLog(@"TC: listening on %@", path);

        while (running) {
            struct sockaddr_un peer;
            socklen_t plen = sizeof(peer);
            int fd = accept(server_fd, (struct sockaddr *)&peer, &plen);
            if (fd < 0) {
                if (errno == EINTR) continue;
                NSLog(@"TC: accept() failed: %s", strerror(errno));
                break;
            }

            close_client_fd_safe();
            client_fd = fd;
            NSLog(@"TC: client connected");

            // spawn recv loop
            pthread_create(&recv_thread, NULL, recv_loop, NULL);

            // wait until recv loop exits (or client closes)
            pthread_join(recv_thread, NULL);

            close_client_fd_safe();

            if (!running) break;
        }

        close_server_fd_safe();
        // cleanup socket file
        if (g_socketPath) {
            unlink([g_socketPath fileSystemRepresentation]);
        }
        running = 0;
    }
    return NULL;
}