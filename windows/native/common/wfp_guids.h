#ifndef NETPILOT_NATIVE_COMMON_WFP_GUIDS_H_
#define NETPILOT_NATIVE_COMMON_WFP_GUIDS_H_

#include <guiddef.h>

// {D03FC43C-3D4F-41A7-8C6C-12B744862901}
DEFINE_GUID(NETPILOT_WFP_PROVIDER, 0xd03fc43c, 0x3d4f, 0x41a7, 0x8c, 0x6c,
            0x12, 0xb7, 0x44, 0x86, 0x29, 0x01);
// {1F44A225-F435-42DE-8774-BDCB00352C71}
DEFINE_GUID(NETPILOT_WFP_SUBLAYER, 0x1f44a225, 0xf435, 0x42de, 0x87, 0x74,
            0xbd, 0xcb, 0x00, 0x35, 0x2c, 0x71);
// {AB3A8731-0560-4791-8524-FD962E986F23}
DEFINE_GUID(NETPILOT_CONNECT_CALLOUT_V4, 0xab3a8731, 0x0560, 0x4791, 0x85,
            0x24, 0xfd, 0x96, 0x2e, 0x98, 0x6f, 0x23);

constexpr unsigned short kNetPilotTcpProxyPort = 49171;
constexpr unsigned short kNetPilotUdpProxyPort = 49172;

#endif
