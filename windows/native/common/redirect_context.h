#ifndef NETPILOT_NATIVE_COMMON_REDIRECT_CONTEXT_H_
#define NETPILOT_NATIVE_COMMON_REDIRECT_CONTEXT_H_

// This header is shared by the WFP kernel driver and the user-mode service.
// Avoid the user-mode CRT's stdint.h in kernel builds.
using NetPilotUInt16 = unsigned short;
using NetPilotUInt32 = unsigned int;
using NetPilotUInt64 = unsigned long long;

static_assert(sizeof(NetPilotUInt16) == 2 && sizeof(NetPilotUInt32) == 4 &&
                  sizeof(NetPilotUInt64) == 8,
              "NetPilot redirect context requires fixed-width integers");

constexpr NetPilotUInt32 kNetPilotRedirectContextVersion = 1;

#pragma pack(push, 1)
struct NetPilotRedirectContext {
  NetPilotUInt32 version;
  NetPilotUInt32 protocol;
  NetPilotUInt64 rule_context;
  NetPilotUInt32 remote_ipv4;
  NetPilotUInt16 remote_port;
  NetPilotUInt16 reserved;
};
#pragma pack(pop)

static_assert(sizeof(NetPilotRedirectContext) == 24,
              "NetPilot redirect context ABI changed");

#endif
