#ifndef NETPILOT_NATIVE_COMMON_DRIVER_CONTROL_H_
#define NETPILOT_NATIVE_COMMON_DRIVER_CONTROL_H_

#if defined(_KERNEL_MODE)
#include <devioctl.h>
#else
#include <windows.h>
#include <winioctl.h>
#endif

// Only the LocalSystem service and administrators can open the driver device.
#define IOCTL_NETPILOT_SET_PROXY_PID                                      \
  CTL_CODE(FILE_DEVICE_NETWORK, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA)

struct NetPilotProxyProcessConfig {
  unsigned long version;
  unsigned long process_id;
};

constexpr unsigned long kNetPilotProxyProcessConfigVersion = 1;

#endif
