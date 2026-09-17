#ifndef NETPILOT_NATIVE_COMMON_REDIRECT_CONTEXT_H_
#define NETPILOT_NATIVE_COMMON_REDIRECT_CONTEXT_H_

#include <stdint.h>

constexpr uint32_t kNetPilotRedirectContextVersion = 1;

#pragma pack(push, 1)
struct NetPilotRedirectContext {
  uint32_t version;
  uint32_t protocol;
  uint64_t rule_context;
  uint32_t remote_ipv4;
  uint16_t remote_port;
  uint16_t reserved;
};
#pragma pack(pop)

#endif
