#include "relay_engine.h"

#include <iphlpapi.h>
#include <mswsock.h>
#include <mstcpip.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <sstream>

#include "../common/redirect_context.h"
#include "../common/wfp_guids.h"
#include "diagnostics.h"

// MinGW's mstcpip.h currently omits these Windows 8+ SDK constants. Keeping
// the documented SDK definitions here also lets the portable cross-check build
// the service sources; MSVC uses the declarations from mstcpip.h.
#ifndef SIO_QUERY_WFP_CONNECTION_REDIRECT_RECORDS
#define SIO_QUERY_WFP_CONNECTION_REDIRECT_RECORDS _WSAIOW(IOC_VENDOR, 220)
#define SIO_QUERY_WFP_CONNECTION_REDIRECT_CONTEXT _WSAIOW(IOC_VENDOR, 221)
#define SIO_SET_WFP_CONNECTION_REDIRECT_RECORDS _WSAIOW(IOC_VENDOR, 222)
#endif

namespace {

uint64_t RuleContext(const std::string& value) {
  uint64_t hash = 1469598103934665603ULL;
  for (const unsigned char byte : value) {
    hash ^= byte;
    hash *= 1099511628211ULL;
  }
  return hash;
}

std::string SocketError(const char* action) {
  std::ostringstream stream;
  stream << action << " failed (Winsock " << WSAGetLastError() << ')';
  return stream.str();
}

SOCKET Listener(int type, int protocol, uint16_t port) {
  SOCKET socket_value = socket(AF_INET, type, protocol);
  if (socket_value == INVALID_SOCKET) return socket_value;
  BOOL reuse = TRUE;
  setsockopt(socket_value, SOL_SOCKET, SO_REUSEADDR,
             reinterpret_cast<const char*>(&reuse), sizeof(reuse));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(port);
  if (bind(socket_value, reinterpret_cast<sockaddr*>(&address),
           sizeof(address)) == SOCKET_ERROR ||
      (type == SOCK_STREAM && listen(socket_value, SOMAXCONN) == SOCKET_ERROR)) {
    closesocket(socket_value);
    return INVALID_SOCKET;
  }
  return socket_value;
}

bool FindSourceAddress(const NET_LUID& luid, sockaddr_in* source) {
  ULONG size = 16 * 1024;
  std::vector<uint8_t> buffer(size);
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && status == ERROR_BUFFER_OVERFLOW;
       ++attempt) {
    status = GetAdaptersAddresses(
        AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST, nullptr,
        reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data()), &size);
    if (status == ERROR_BUFFER_OVERFLOW) buffer.resize(size);
  }
  if (status != NO_ERROR) return false;
  for (auto* adapter =
           reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
       adapter; adapter = adapter->Next) {
    if (adapter->Luid.Value != luid.Value) continue;
    for (auto* address = adapter->FirstUnicastAddress; address;
         address = address->Next) {
      if (address->Address.lpSockaddr &&
          address->Address.lpSockaddr->sa_family == AF_INET) {
        *source = *reinterpret_cast<const sockaddr_in*>(
            address->Address.lpSockaddr);
        source->sin_port = 0;
        return true;
      }
    }
  }
  return false;
}

}  // namespace

RelayEngine::RelayEngine(Diagnostics* diagnostics) : diagnostics_(diagnostics) {}
RelayEngine::~RelayEngine() { Stop(); }

bool RelayEngine::Start(std::string* error) {
  if (running_) return true;
  WSADATA data{};
  if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
    *error = "WSAStartup failed";
    return false;
  }
  tcp_listener_ = Listener(SOCK_STREAM, IPPROTO_TCP, kNetPilotTcpProxyPort);
  udp_listener_ = Listener(SOCK_DGRAM, IPPROTO_UDP, kNetPilotUdpProxyPort);
  if (tcp_listener_ == INVALID_SOCKET || udp_listener_ == INVALID_SOCKET) {
    *error = SocketError("proxy listener");
    Stop();
    return false;
  }
  running_ = true;
  tcp_thread_ = std::thread(&RelayEngine::TcpAcceptLoop, this);
  udp_thread_ = std::thread(&RelayEngine::UdpReceiveLoop, this);
  diagnostics_->Log(
      "[NetPilot App Routing] TCP/UDP relay listeners started");
  return true;
}

void RelayEngine::Configure(const std::vector<netpilot::AppRuleSpec>& rules) {
  std::scoped_lock lock(mutex_);
  rules_.clear();
  for (const auto& rule : rules) {
    if (!rule.enabled) continue;
    rules_[RuleContext(rule.id)] = {rule.id, rule.interface_luid};
    metrics_.try_emplace(rule.id, Metric{rule.id, 0, 0, 0, {}});
  }
}

void RelayEngine::RestartFlows() {
  std::scoped_lock lock(mutex_);
  for (const SOCKET socket_value : active_sockets_)
    shutdown(socket_value, SD_BOTH);
  diagnostics_->Log(
      "[NetPilot App Routing] existing selected flows were closed for restart");
}

void RelayEngine::Stop() {
  if (!running_.exchange(false)) return;
  if (tcp_listener_ != INVALID_SOCKET) closesocket(tcp_listener_);
  if (udp_listener_ != INVALID_SOCKET) closesocket(udp_listener_);
  tcp_listener_ = udp_listener_ = INVALID_SOCKET;
  RestartFlows();
  if (tcp_thread_.joinable()) tcp_thread_.join();
  if (udp_thread_.joinable()) udp_thread_.join();
  {
    std::unique_lock lock(mutex_);
    workers_finished_.wait(lock, [this] { return active_workers_ == 0; });
  }
  WSACleanup();
}

void RelayEngine::TcpAcceptLoop() {
  while (running_) {
    SOCKET client = accept(tcp_listener_, nullptr, nullptr);
    if (client == INVALID_SOCKET) continue;
    {
      std::scoped_lock lock(mutex_);
      ++active_workers_;
    }
    std::thread([this, client] {
      RelayTcp(client);
      {
        std::scoped_lock lock(mutex_);
        --active_workers_;
      }
      workers_finished_.notify_all();
    }).detach();
  }
}

void RelayEngine::UdpReceiveLoop() {
  LPFN_WSARECVMSG receive_message = nullptr;
  GUID receive_message_id = WSAID_WSARECVMSG;
  DWORD extension_bytes = 0;
  if (WSAIoctl(udp_listener_, SIO_GET_EXTENSION_FUNCTION_POINTER,
               &receive_message_id, sizeof(receive_message_id),
               &receive_message, sizeof(receive_message), &extension_bytes,
               nullptr, nullptr) == SOCKET_ERROR ||
      !receive_message) {
    diagnostics_->Log(
        "[NetPilot App Routing] UDP relay could not load WSARecvMsg");
    return;
  }
  while (running_) {
    std::vector<uint8_t> packet(65535);
    std::vector<char> control(4096);
    sockaddr_in client{};
    WSABUF payload{static_cast<ULONG>(packet.size()),
                   reinterpret_cast<char*>(packet.data())};
    WSAMSG message{};
    message.name = reinterpret_cast<sockaddr*>(&client);
    message.namelen = sizeof(client);
    message.lpBuffers = &payload;
    message.dwBufferCount = 1;
    message.Control.buf = control.data();
    message.Control.len = static_cast<ULONG>(control.size());
    DWORD received = 0;
    if (receive_message(udp_listener_, &message, &received, nullptr, nullptr) ==
            SOCKET_ERROR ||
        received == 0)
      continue;

    NetPilotRedirectContext context{};
    std::vector<uint8_t> redirect_records;
    for (WSACMSGHDR* header = WSA_CMSG_FIRSTHDR(&message); header;
         header = WSA_CMSG_NXTHDR(&message, header)) {
      if (header->cmsg_level != IPPROTO_IP) continue;
      const size_t data_size =
          header->cmsg_len >= WSA_CMSG_LEN(0)
              ? header->cmsg_len - WSA_CMSG_LEN(0)
              : 0;
      if (header->cmsg_type == IP_WFP_REDIRECT_CONTEXT &&
          data_size >= sizeof(context)) {
        std::memcpy(&context, WSA_CMSG_DATA(header), sizeof(context));
      } else if (header->cmsg_type == IP_WFP_REDIRECT_RECORDS && data_size) {
        const auto* begin = reinterpret_cast<const uint8_t*>(
            WSA_CMSG_DATA(header));
        redirect_records.assign(begin, begin + data_size);
      }
    }
    if (context.version != kNetPilotRedirectContextVersion ||
        context.protocol != IPPROTO_UDP || redirect_records.empty()) {
      diagnostics_->Log(
          "[NetPilot App Routing] rejected UDP packet without WFP redirect metadata");
      continue;
    }
    packet.resize(received);
    {
      std::scoped_lock lock(mutex_);
      ++active_workers_;
    }
    std::thread([this, client, packet = std::move(packet), context,
                 records = std::move(redirect_records)]() mutable {
      RelayUdpSession(client, std::move(packet), context, std::move(records));
      {
        std::scoped_lock lock(mutex_);
        --active_workers_;
      }
      workers_finished_.notify_all();
    }).detach();
  }
}

bool RelayEngine::QueryContext(SOCKET socket_value, uint64_t* rule_context,
                               uint32_t* protocol, uint32_t* remote_ipv4,
                               uint16_t* remote_port,
                               std::vector<uint8_t>* redirect_records,
                               std::string* error) const {
  NetPilotRedirectContext context{};
  DWORD bytes = 0;
  if (WSAIoctl(socket_value, SIO_QUERY_WFP_CONNECTION_REDIRECT_CONTEXT,
               nullptr, 0, &context, sizeof(context), &bytes, nullptr,
               nullptr) == SOCKET_ERROR ||
      bytes != sizeof(context) ||
      context.version != kNetPilotRedirectContextVersion) {
    *error = SocketError("query redirect context");
    return false;
  }
  *rule_context = context.rule_context;
  *protocol = context.protocol;
  *remote_ipv4 = context.remote_ipv4;
  *remote_port = context.remote_port;

  redirect_records->assign(1024, 0);
  bytes = 0;
  if (WSAIoctl(socket_value, SIO_QUERY_WFP_CONNECTION_REDIRECT_RECORDS,
               nullptr, 0, redirect_records->data(),
               static_cast<DWORD>(redirect_records->size()), &bytes, nullptr,
               nullptr) == SOCKET_ERROR) {
    if (bytes <= redirect_records->size()) {
      *error = SocketError("query redirect records");
      return false;
    }
    redirect_records->assign(bytes, 0);
    if (WSAIoctl(socket_value, SIO_QUERY_WFP_CONNECTION_REDIRECT_RECORDS,
                 nullptr, 0, redirect_records->data(),
                 static_cast<DWORD>(redirect_records->size()), &bytes, nullptr,
                 nullptr) == SOCKET_ERROR) {
      *error = SocketError("query redirect records");
      return false;
    }
  }
  redirect_records->resize(bytes);
  return true;
}

SOCKET RelayEngine::ConnectOutbound(uint64_t rule_context, uint32_t protocol,
                                    uint32_t remote_ipv4,
                                    uint16_t remote_port,
                                    const std::vector<uint8_t>& redirect_records,
                                    std::string* rule_id,
                                    std::string* error) {
  std::string luid_value;
  {
    std::scoped_lock lock(mutex_);
    const auto found = rules_.find(rule_context);
    if (found == rules_.end()) {
      *error = "redirect context does not map to an active rule";
      return INVALID_SOCKET;
    }
    luid_value = found->second.interface_luid;
    *rule_id = found->second.id;
  }
  NET_LUID luid{};
  try {
    luid.Value = std::stoull(luid_value);
  } catch (...) {
    *error = "invalid adapter LUID";
    return INVALID_SOCKET;
  }
  NET_IFINDEX index = 0;
  if (ConvertInterfaceLuidToIndex(&luid, &index) != NO_ERROR) {
    *error = "selected adapter is unavailable";
    return INVALID_SOCKET;
  }
  const int type = protocol == IPPROTO_TCP ? SOCK_STREAM : SOCK_DGRAM;
  SOCKET outbound = socket(AF_INET, type, protocol);
  if (outbound == INVALID_SOCKET) {
    *error = SocketError("outbound socket");
    return outbound;
  }
  sockaddr_in local{};
  const bool found_source = FindSourceAddress(luid, &local);
  if (!found_source ||
      bind(outbound, reinterpret_cast<sockaddr*>(&local), sizeof(local)) ==
          SOCKET_ERROR) {
    *error = found_source ? SocketError("bind selected adapter")
                          : "selected adapter has no IPv4 address";
    closesocket(outbound);
    return INVALID_SOCKET;
  }
  const DWORD network_index = htonl(index);
  if (setsockopt(outbound, IPPROTO_IP, IP_UNICAST_IF,
                 reinterpret_cast<const char*>(&network_index),
                 sizeof(network_index)) == SOCKET_ERROR) {
    *error = SocketError("IP_UNICAST_IF");
    closesocket(outbound);
    return INVALID_SOCKET;
  }
  if (protocol == IPPROTO_TCP && !redirect_records.empty()) {
    DWORD bytes = 0;
    if (WSAIoctl(outbound, SIO_SET_WFP_CONNECTION_REDIRECT_RECORDS,
                 const_cast<uint8_t*>(redirect_records.data()),
                 static_cast<DWORD>(redirect_records.size()), nullptr, 0,
                 &bytes, nullptr, nullptr) == SOCKET_ERROR) {
      *error = SocketError("set redirect records");
      closesocket(outbound);
      return INVALID_SOCKET;
    }
  }
  sockaddr_in destination{};
  destination.sin_family = AF_INET;
  destination.sin_addr.s_addr = remote_ipv4;
  destination.sin_port = remote_port;
  if (connect(outbound, reinterpret_cast<sockaddr*>(&destination),
              sizeof(destination)) == SOCKET_ERROR) {
    *error = SocketError("outbound connect");
    closesocket(outbound);
    return INVALID_SOCKET;
  }
  return outbound;
}

void RelayEngine::RelayTcp(SOCKET client) {
  Track(client);
  uint64_t rule = 0;
  uint32_t protocol = 0, address = 0;
  uint16_t port = 0;
  std::string error;
  std::string rule_id;
  std::vector<uint8_t> redirect_records;
  SOCKET outbound = INVALID_SOCKET;
  if (QueryContext(client, &rule, &protocol, &address, &port,
                   &redirect_records, &error))
    outbound = ConnectOutbound(rule, protocol, address, port, redirect_records,
                               &rule_id, &error);
  if (outbound == INVALID_SOCKET) {
    diagnostics_->Log("[NetPilot App Routing] TCP block/error: " + error);
    if (!rule_id.empty()) {
      std::scoped_lock lock(mutex_);
      metrics_[rule_id].last_error = error;
    }
    closesocket(client);
    Untrack(client);
    return;
  }
  Track(outbound);
  {
    std::scoped_lock lock(mutex_);
    ++metrics_[rule_id].active_flows;
  }
  auto pump = [this, &rule_id](SOCKET source, SOCKET destination,
                               bool inbound) {
    std::array<char, 32 * 1024> buffer{};
    for (;;) {
      const int count =
          recv(source, buffer.data(), static_cast<int>(buffer.size()), 0);
      if (count <= 0) break;
      {
        std::scoped_lock lock(mutex_);
        if (inbound)
          metrics_[rule_id].bytes_in += count;
        else
          metrics_[rule_id].bytes_out += count;
      }
      int sent = 0;
      while (sent < count) {
        const int value = send(destination, buffer.data() + sent, count - sent, 0);
        if (value <= 0) return;
        sent += value;
      }
    }
    shutdown(destination, SD_SEND);
  };
  std::thread upstream(pump, client, outbound, false);
  pump(outbound, client, true);
  upstream.join();
  closesocket(outbound);
  closesocket(client);
  Untrack(outbound);
  Untrack(client);
  {
    std::scoped_lock lock(mutex_);
    if (metrics_[rule_id].active_flows) --metrics_[rule_id].active_flows;
  }
}

void RelayEngine::RelayUdpSession(sockaddr_in client,
                                  std::vector<uint8_t> first_packet,
                                  NetPilotRedirectContext context,
                                  std::vector<uint8_t> redirect_records) {
  SOCKET local = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (local == INVALID_SOCKET) return;
  BOOL reuse = TRUE;
  setsockopt(local, SOL_SOCKET, SO_REUSEADDR,
             reinterpret_cast<const char*>(&reuse), sizeof(reuse));
  sockaddr_in listen_address{};
  listen_address.sin_family = AF_INET;
  listen_address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  listen_address.sin_port = htons(kNetPilotUdpProxyPort);
  if (bind(local, reinterpret_cast<sockaddr*>(&listen_address),
           sizeof(listen_address)) == SOCKET_ERROR ||
      connect(local, reinterpret_cast<sockaddr*>(&client), sizeof(client)) ==
          SOCKET_ERROR) {
    closesocket(local);
    return;
  }
  std::string error;
  std::string rule_id;
  SOCKET outbound =
      ConnectOutbound(context.rule_context, IPPROTO_UDP, context.remote_ipv4,
                      context.remote_port, redirect_records, &rule_id, &error);
  if (outbound == INVALID_SOCKET) {
    diagnostics_->Log("[NetPilot App Routing] UDP block/error: " + error);
    if (!rule_id.empty()) {
      std::scoped_lock lock(mutex_);
      metrics_[rule_id].last_error = error;
    }
    closesocket(local);
    return;
  }
  Track(local);
  Track(outbound);
  {
    std::scoped_lock lock(mutex_);
    ++metrics_[rule_id].active_flows;
    metrics_[rule_id].bytes_out += first_packet.size();
  }
  std::vector<char> outbound_control(
      WSA_CMSG_SPACE(static_cast<ULONG>(redirect_records.size())));
  WSABUF first_payload{static_cast<ULONG>(first_packet.size()),
                       reinterpret_cast<char*>(first_packet.data())};
  WSAMSG first_message{};
  first_message.lpBuffers = &first_payload;
  first_message.dwBufferCount = 1;
  first_message.Control.buf = outbound_control.data();
  first_message.Control.len = static_cast<ULONG>(outbound_control.size());
  WSACMSGHDR* redirect_header = WSA_CMSG_FIRSTHDR(&first_message);
  redirect_header->cmsg_level = IPPROTO_IP;
  redirect_header->cmsg_type = IP_WFP_REDIRECT_RECORDS;
  redirect_header->cmsg_len =
      WSA_CMSG_LEN(static_cast<ULONG>(redirect_records.size()));
  std::memcpy(WSA_CMSG_DATA(redirect_header), redirect_records.data(),
              redirect_records.size());
  DWORD sent = 0;
  if (WSASendMsg(outbound, &first_message, 0, &sent, nullptr, nullptr) ==
      SOCKET_ERROR) {
    error = SocketError("forward initial UDP redirect record");
    diagnostics_->Log("[NetPilot App Routing] UDP block/error: " + error);
    closesocket(outbound);
    closesocket(local);
    Untrack(outbound);
    Untrack(local);
    std::scoped_lock lock(mutex_);
    metrics_[rule_id].last_error = error;
    if (metrics_[rule_id].active_flows) --metrics_[rule_id].active_flows;
    return;
  }
  DWORD timeout = 30000;
  setsockopt(local, SOL_SOCKET, SO_RCVTIMEO,
             reinterpret_cast<const char*>(&timeout), sizeof(timeout));
  setsockopt(outbound, SOL_SOCKET, SO_RCVTIMEO,
             reinterpret_cast<const char*>(&timeout), sizeof(timeout));
  std::array<char, 65535> buffer{};
  while (running_) {
    fd_set reads;
    FD_ZERO(&reads);
    FD_SET(local, &reads);
    FD_SET(outbound, &reads);
    timeval wait{30, 0};
    if (select(0, &reads, nullptr, nullptr, &wait) <= 0) break;
    if (FD_ISSET(local, &reads)) {
      const int count =
          recv(local, buffer.data(), static_cast<int>(buffer.size()), 0);
      if (count <= 0 || send(outbound, buffer.data(), count, 0) <= 0) break;
      std::scoped_lock lock(mutex_);
      metrics_[rule_id].bytes_out += count;
    }
    if (FD_ISSET(outbound, &reads)) {
      const int count =
          recv(outbound, buffer.data(), static_cast<int>(buffer.size()), 0);
      if (count <= 0 || send(local, buffer.data(), count, 0) <= 0) break;
      std::scoped_lock lock(mutex_);
      metrics_[rule_id].bytes_in += count;
    }
  }
  closesocket(outbound);
  closesocket(local);
  Untrack(outbound);
  Untrack(local);
  {
    std::scoped_lock lock(mutex_);
    if (metrics_[rule_id].active_flows) --metrics_[rule_id].active_flows;
  }
}

std::vector<RelayEngine::Metric> RelayEngine::Metrics() const {
  std::scoped_lock lock(mutex_);
  std::vector<Metric> result;
  for (const auto& entry : metrics_) result.push_back(entry.second);
  return result;
}

void RelayEngine::Track(SOCKET socket_value) {
  std::scoped_lock lock(mutex_);
  active_sockets_.push_back(socket_value);
}

void RelayEngine::Untrack(SOCKET socket_value) {
  std::scoped_lock lock(mutex_);
  active_sockets_.erase(
      std::remove(active_sockets_.begin(), active_sockets_.end(), socket_value),
      active_sockets_.end());
}
