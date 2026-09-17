#include "windows_network.h"

#include <iphlpapi.h>
#include <windns.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <memory>
#include <sstream>

namespace {

std::string Utf8(const wchar_t* value) {
  if (!value || !*value) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                       nullptr, nullptr);
  std::string output(size > 0 ? size : 0, '\0');
  if (size > 1) {
    WideCharToMultiByte(CP_UTF8, 0, value, -1, output.data(), size, nullptr,
                        nullptr);
    output.pop_back();
  }
  return output;
}

std::wstring Wide(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  std::wstring output(size, L'\0');
  if (size > 0)
    MultiByteToWideChar(CP_UTF8, 0, value.data(),
                        static_cast<int>(value.size()), output.data(), size);
  return output;
}

std::string SockaddrString(const SOCKADDR* address) {
  if (!address || address->sa_family != AF_INET) return {};
  char output[INET_ADDRSTRLEN] = {};
  const auto* in = reinterpret_cast<const SOCKADDR_IN*>(address);
  return InetNtopA(AF_INET, const_cast<IN_ADDR*>(&in->sin_addr), output,
                   sizeof(output))
             ? output
             : std::string();
}

std::string ErrorText(const char* label, ULONG code) {
  std::ostringstream stream;
  stream << label << " failed (Win32 " << code << ')';
  return stream.str();
}

}  // namespace

WindowsNetworkInventory::WindowsNetworkInventory() = default;
WindowsNetworkInventory::~WindowsNetworkInventory() { Stop(); }

std::vector<WindowsAdapterInfo> WindowsNetworkInventory::List(
    std::string* error) const {
  ULONG size = 16 * 1024;
  std::vector<uint8_t> buffer(size);
  ULONG result = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && result == ERROR_BUFFER_OVERFLOW;
       ++attempt) {
    result = GetAdaptersAddresses(
        AF_INET, GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_INCLUDE_PREFIX, nullptr,
        reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data()), &size);
    if (result == ERROR_BUFFER_OVERFLOW) buffer.resize(size);
  }
  if (result != NO_ERROR) {
    *error = ErrorText("GetAdaptersAddresses", result);
    return {};
  }

  NET_LUID default_luid{};
  SOCKADDR_INET destination{};
  destination.si_family = AF_INET;
  InetPtonW(AF_INET, L"8.8.8.8", &destination.Ipv4.sin_addr);
  MIB_IPFORWARD_ROW2 best_route{};
  SOCKADDR_INET source{};
  if (GetBestRoute2(nullptr, 0, nullptr, &destination, 0, &best_route,
                    &source) == NO_ERROR) {
    default_luid = best_route.InterfaceLuid;
  }

  std::vector<WindowsAdapterInfo> adapters;
  auto* current = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
  for (; current; current = current->Next) {
    if (current->IfType != IF_TYPE_IEEE80211 &&
        current->IfType != IF_TYPE_ETHERNET_CSMACD) {
      continue;
    }
    WindowsAdapterInfo adapter;
    adapter.native_id = std::to_string(current->Luid.Value);
    adapter.id = adapter.native_id;
    adapter.name = Utf8(current->FriendlyName);
    adapter.interface_name = adapter.name;
    adapter.kind = current->IfType == IF_TYPE_IEEE80211 ? "wifi" : "ethernet";
    adapter.interface_index = current->IfIndex;
    adapter.is_active = current->OperStatus == IfOperStatusUp;
    adapter.is_default_route = current->Luid.Value == default_luid.Value;
    for (auto* address = current->FirstUnicastAddress; address;
         address = address->Next) {
      const auto value = SockaddrString(address->Address.lpSockaddr);
      if (!value.empty()) adapter.ipv4_addresses.push_back(value);
    }
    for (auto* gateway = current->FirstGatewayAddress; gateway;
         gateway = gateway->Next) {
      adapter.gateway = SockaddrString(gateway->Address.lpSockaddr);
      if (!adapter.gateway.empty()) break;
    }
    for (auto* dns = current->FirstDnsServerAddress; dns; dns = dns->Next) {
      const auto value = SockaddrString(dns->Address.lpSockaddr);
      if (!value.empty()) adapter.dns_servers.push_back(value);
    }
    adapters.push_back(std::move(adapter));
  }
  std::sort(adapters.begin(), adapters.end(),
            [](const auto& a, const auto& b) {
              if (a.is_active != b.is_active) return a.is_active > b.is_active;
              if (a.is_default_route != b.is_default_route)
                return a.is_default_route > b.is_default_route;
              return a.name < b.name;
            });
  return adapters;
}

std::vector<std::string> WindowsNetworkInventory::Resolve(
    const std::string& host, const std::string& adapter_luid,
    std::string* error) const {
  NET_LUID luid{};
  try {
    luid.Value = std::stoull(adapter_luid);
  } catch (...) {
    *error = "Invalid adapter LUID";
    return {};
  }
  NET_IFINDEX index = 0;
  ULONG status = ConvertInterfaceLuidToIndex(&luid, &index);
  if (status != NO_ERROR) {
    *error = ErrorText("ConvertInterfaceLuidToIndex", status);
    return {};
  }

  const auto wide_host = Wide(host);
  DNS_QUERY_REQUEST request{};
  request.Version = DNS_QUERY_REQUEST_VERSION1;
  request.QueryName = wide_host.c_str();
  request.QueryType = DNS_TYPE_A;
  request.QueryOptions = DNS_QUERY_BYPASS_CACHE;
  request.InterfaceIndex = index;
  DNS_QUERY_RESULT result{};
  result.Version = DNS_QUERY_RESULTS_VERSION1;
  status = DnsQueryEx(&request, &result, nullptr);
  if (status != ERROR_SUCCESS) {
    *error = ErrorText("DnsQueryEx", status);
    return {};
  }
  std::vector<std::string> addresses;
  for (auto* record = result.pQueryRecords; record; record = record->pNext) {
    if (record->wType != DNS_TYPE_A) continue;
    IN_ADDR address{};
    address.S_un.S_addr = record->Data.A.IpAddress;
    char text[INET_ADDRSTRLEN] = {};
    if (InetNtopA(AF_INET, &address, text, sizeof(text)))
      addresses.emplace_back(text);
  }
  if (result.pQueryRecords)
    DnsRecordListFree(result.pQueryRecords, DnsFreeRecordList);
  std::sort(addresses.begin(), addresses.end());
  addresses.erase(std::unique(addresses.begin(), addresses.end()),
                  addresses.end());
  return addresses;
}

void WindowsNetworkInventory::Start(ChangeCallback callback) {
  Stop();
  callback_ = std::move(callback);
  NotifyIpInterfaceChange(AF_INET, OnInterfaceChanged, this, FALSE,
                          &notification_);
}

void WindowsNetworkInventory::Stop() {
  if (notification_) {
    CancelMibChangeNotify2(notification_);
    notification_ = nullptr;
  }
  callback_ = nullptr;
}

void WINAPI WindowsNetworkInventory::OnInterfaceChanged(
    PVOID context, PMIB_IPINTERFACE_ROW, MIB_NOTIFICATION_TYPE) {
  auto* inventory = static_cast<WindowsNetworkInventory*>(context);
  if (inventory && inventory->callback_) inventory->callback_();
}
