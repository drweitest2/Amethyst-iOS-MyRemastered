//
// TCProtocol.h
// Helper serialization for TouchController proxy protocol
//

#import <Foundation/Foundation.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Convert float to network-order 32-bit representation used by TouchController protocol.
uint32_t tc_htonf(float f);
// Convert network-order 32-bit representation to float.
float tc_ntohf(uint32_t u);
// Host-to-network 32-bit
uint32_t tc_hton32(int32_t v);

// write/read helpers that retry on EINTR and ensure full transfer.
int tc_write_fully(int fd, const void *buf, size_t count);
int tc_read_fully(int fd, void *buf, size_t count);

#ifdef __cplusplus
}
#endif