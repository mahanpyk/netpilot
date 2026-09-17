#include <ntddk.h>
#include <initguid.h>
#include <fwpsk.h>
#include <fwpmk.h>
#include <wdmsec.h>
#include <ws2def.h>
#include <inaddr.h>

#include "../common/driver_control.h"
#include "../common/redirect_context.h"
#include "../common/wfp_guids.h"

#define NETPILOT_DEVICE_NAME L"\\Device\\NetPilotWfp"
#define NETPILOT_DOS_DEVICE_NAME L"\\DosDevices\\NetPilotWfp"

static UINT32 g_callout_id = 0;
static HANDLE g_redirect_handle = NULL;
static PDEVICE_OBJECT g_device = NULL;
static volatile LONG g_proxy_process_id = 0;

// {AA60638F-F12D-471A-AB30-4170567F4D2D}
static const GUID NETPILOT_DEVICE_CLASS = {
    0xaa60638f, 0xf12d, 0x471a,
    {0xab, 0x30, 0x41, 0x70, 0x56, 0x7f, 0x4d, 0x2d}};

static void NTAPI ClassifyConnectRedirectV4(
    const FWPS_INCOMING_VALUES0* values,
    const FWPS_INCOMING_METADATA_VALUES0* metadata, void* layer_data,
    const void* classify_context, const FWPS_FILTER1* filter, UINT64 flow_context,
    FWPS_CLASSIFY_OUT0* classify_out) {
  UNREFERENCED_PARAMETER(layer_data);
  UNREFERENCED_PARAMETER(flow_context);
  if (!(classify_out->rights & FWPS_RIGHT_ACTION_WRITE)) return;

  if ((metadata->currentMetadataValues & FWPS_METADATA_FIELD_REDIRECT_RECORD_HANDLE) != 0) {
    const FWPS_CONNECTION_REDIRECT_STATE state =
        FwpsQueryConnectionRedirectState0(metadata->redirectRecords,
                                           g_redirect_handle, NULL);
    if (state == FWPS_CONNECTION_REDIRECTED_BY_SELF ||
        state == FWPS_CONNECTION_PREVIOUSLY_REDIRECTED_BY_SELF) {
      classify_out->actionType = FWP_ACTION_PERMIT;
      return;
    }
  }

  const UINT8 protocol = values->incomingValue
      [FWPS_FIELD_ALE_CONNECT_REDIRECT_V4_IP_PROTOCOL]
          .value.uint8;
  if (protocol != IPPROTO_TCP && protocol != IPPROTO_UDP) {
    classify_out->actionType = FWP_ACTION_PERMIT;
    return;
  }

  const LONG proxy_process_id =
      InterlockedCompareExchange(&g_proxy_process_id, 0, 0);
  if (proxy_process_id <= 0) {
    classify_out->actionType = FWP_ACTION_BLOCK;
    classify_out->rights &= ~FWPS_RIGHT_ACTION_WRITE;
    return;
  }

  UINT64 classify_handle = 0;
  FWPS_CONNECT_REQUEST0* request = NULL;
  NTSTATUS status = FwpsAcquireClassifyHandle0(classify_context, 0,
                                                &classify_handle);
  if (!NT_SUCCESS(status)) {
    classify_out->actionType = FWP_ACTION_BLOCK;
    return;
  }
  status = FwpsAcquireWritableLayerDataPointer0(
      classify_handle, filter->filterId, 0, (PVOID*)&request, classify_out);
  if (!NT_SUCCESS(status) || !request) {
    FwpsReleaseClassifyHandle0(classify_handle);
    classify_out->actionType = FWP_ACTION_BLOCK;
    return;
  }

  SOCKADDR_IN* remote = (SOCKADDR_IN*)&request->remoteAddressAndPort;
  NetPilotRedirectContext* context =
      static_cast<NetPilotRedirectContext*>(ExAllocatePool2(
          POOL_FLAG_NON_PAGED, sizeof(NetPilotRedirectContext), 'tPpN'));
  if (!context) {
    FwpsApplyModifiedLayerData0(classify_handle, request, 0);
    FwpsReleaseClassifyHandle0(classify_handle);
    classify_out->actionType = FWP_ACTION_BLOCK;
    classify_out->rights &= ~FWPS_RIGHT_ACTION_WRITE;
    return;
  }
  RtlZeroMemory(context, sizeof(*context));
  context->version = kNetPilotRedirectContextVersion;
  context->protocol = protocol;
  context->rule_context = filter->context;
  context->remote_ipv4 = remote->sin_addr.S_un.S_addr;
  context->remote_port = remote->sin_port;

  remote->sin_family = AF_INET;
  remote->sin_addr.S_un.S_addr = RtlUlongByteSwap(INADDR_LOOPBACK);
  remote->sin_port = RtlUshortByteSwap(
      protocol == IPPROTO_TCP ? kNetPilotTcpProxyPort : kNetPilotUdpProxyPort);
  request->localRedirectHandle = g_redirect_handle;
  request->localRedirectTargetPID = static_cast<DWORD>(proxy_process_id);
  request->localRedirectContext = context;
  request->localRedirectContextSize = sizeof(*context);

  status = FwpsApplyModifiedLayerData0(classify_handle, request, 0);
  if (!NT_SUCCESS(status)) ExFreePoolWithTag(context, 'tPpN');
  FwpsReleaseClassifyHandle0(classify_handle);
  classify_out->actionType = NT_SUCCESS(status) ? FWP_ACTION_PERMIT
                                                : FWP_ACTION_BLOCK;
  if (!NT_SUCCESS(status)) classify_out->rights &= ~FWPS_RIGHT_ACTION_WRITE;
}

static NTSTATUS NTAPI Notify(FWPS_CALLOUT_NOTIFY_TYPE type,
                             const GUID* filter_key,
                             const FWPS_FILTER1* filter) {
  UNREFERENCED_PARAMETER(type);
  UNREFERENCED_PARAMETER(filter_key);
  UNREFERENCED_PARAMETER(filter);
  return STATUS_SUCCESS;
}

static void NTAPI FlowDelete(UINT16 layer_id, UINT32 callout_id,
                             UINT64 flow_context) {
  UNREFERENCED_PARAMETER(layer_id);
  UNREFERENCED_PARAMETER(callout_id);
  UNREFERENCED_PARAMETER(flow_context);
}

static NTSTATUS Dispatch(PDEVICE_OBJECT device, PIRP irp) {
  UNREFERENCED_PARAMETER(device);
  const UCHAR function = IoGetCurrentIrpStackLocation(irp)->MajorFunction;
  irp->IoStatus.Status =
      function == IRP_MJ_CREATE || function == IRP_MJ_CLOSE
          ? STATUS_SUCCESS
          : STATUS_INVALID_DEVICE_REQUEST;
  irp->IoStatus.Information = 0;
  IoCompleteRequest(irp, IO_NO_INCREMENT);
  return irp->IoStatus.Status;
}

static NTSTATUS DeviceControl(PDEVICE_OBJECT device, PIRP irp) {
  UNREFERENCED_PARAMETER(device);
  const PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
  NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
  if (stack->Parameters.DeviceIoControl.IoControlCode ==
          IOCTL_NETPILOT_SET_PROXY_PID &&
      stack->Parameters.DeviceIoControl.InputBufferLength ==
          sizeof(NetPilotProxyProcessConfig)) {
    const NetPilotProxyProcessConfig* config =
        static_cast<const NetPilotProxyProcessConfig*>(
            irp->AssociatedIrp.SystemBuffer);
    if (config && config->version == kNetPilotProxyProcessConfigVersion &&
        config->process_id != 0) {
      InterlockedExchange(&g_proxy_process_id,
                          static_cast<LONG>(config->process_id));
      status = STATUS_SUCCESS;
    } else {
      status = STATUS_INVALID_PARAMETER;
    }
  }
  irp->IoStatus.Status = status;
  irp->IoStatus.Information = 0;
  IoCompleteRequest(irp, IO_NO_INCREMENT);
  return status;
}

static void Unload(PDRIVER_OBJECT driver) {
  UNICODE_STRING link;
  UNREFERENCED_PARAMETER(driver);
  if (g_callout_id) FwpsCalloutUnregisterById0(g_callout_id);
  if (g_redirect_handle) FwpsRedirectHandleDestroy0(g_redirect_handle);
  RtlInitUnicodeString(&link, NETPILOT_DOS_DEVICE_NAME);
  IoDeleteSymbolicLink(&link);
  if (g_device) IoDeleteDevice(g_device);
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING registry_path) {
  UNICODE_STRING device_name;
  UNICODE_STRING link;
  UNREFERENCED_PARAMETER(registry_path);
  RtlInitUnicodeString(&device_name, NETPILOT_DEVICE_NAME);
  NTSTATUS status = IoCreateDeviceSecure(
      driver, 0, &device_name, FILE_DEVICE_NETWORK, FILE_DEVICE_SECURE_OPEN,
      FALSE, L"D:P(A;;GA;;;SY)(A;;GA;;;BA)", &NETPILOT_DEVICE_CLASS,
      &g_device);
  if (!NT_SUCCESS(status)) return status;
  RtlInitUnicodeString(&link, NETPILOT_DOS_DEVICE_NAME);
  status = IoCreateSymbolicLink(&link, &device_name);
  if (!NT_SUCCESS(status)) {
    IoDeleteDevice(g_device);
    return status;
  }
  for (UINT32 i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; ++i)
    driver->MajorFunction[i] = Dispatch;
  driver->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DeviceControl;
  driver->DriverUnload = Unload;

  status = FwpsRedirectHandleCreate0(&NETPILOT_WFP_PROVIDER, 0,
                                      &g_redirect_handle);
  if (!NT_SUCCESS(status)) {
    Unload(driver);
    return status;
  }
  FWPS_CALLOUT1 callout = {0};
  callout.calloutKey = NETPILOT_CONNECT_CALLOUT_V4;
  callout.classifyFn = ClassifyConnectRedirectV4;
  callout.notifyFn = Notify;
  callout.flowDeleteFn = FlowDelete;
  status = FwpsCalloutRegister1(g_device, &callout, &g_callout_id);
  if (!NT_SUCCESS(status)) Unload(driver);
  return status;
}
