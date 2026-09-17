#ifndef NETPILOT_NATIVE_SERVICE_RELAY_ENGINE_H_
#define NETPILOT_NATIVE_SERVICE_RELAY_ENGINE_H_

#include <winsock2.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "../common/netpilot_protocol.h"
#include "../common/redirect_context.h"

class Diagnostics;

class RelayEngine {
 public:
  struct Metric {
    std::string id;
    uint32_t active_flows = 0;
    uint64_t bytes_in = 0;
    uint64_t bytes_out = 0;
    std::string last_error;
  };
  explicit RelayEngine(Diagnostics* diagnostics);
  ~RelayEngine();

  bool Start(std::string* error);
  void Configure(const std::vector<netpilot::AppRuleSpec>& rules);
  void RestartFlows();
  void Stop();
  bool running() const { return running_; }
  std::vector<Metric> Metrics() const;

 private:
  void TcpAcceptLoop();
  void UdpReceiveLoop();
  void RelayTcp(SOCKET client);
  void RelayUdpSession(sockaddr_in client, std::vector<uint8_t> first_packet,
                       NetPilotRedirectContext context,
                       std::vector<uint8_t> redirect_records);
  SOCKET ConnectOutbound(uint64_t rule_context, uint32_t protocol,
                         uint32_t remote_ipv4, uint16_t remote_port,
                         const std::vector<uint8_t>& redirect_records,
                         std::string* rule_id, std::string* error);
  bool QueryContext(SOCKET socket, uint64_t* rule_context, uint32_t* protocol,
                    uint32_t* remote_ipv4, uint16_t* remote_port,
                    std::vector<uint8_t>* redirect_records,
                    std::string* error) const;
  void Track(SOCKET socket);
  void Untrack(SOCKET socket);

  Diagnostics* diagnostics_;
  std::atomic<bool> running_{false};
  SOCKET tcp_listener_ = INVALID_SOCKET;
  SOCKET udp_listener_ = INVALID_SOCKET;
  std::thread tcp_thread_;
  std::thread udp_thread_;
  mutable std::mutex mutex_;
  struct RuleRuntime {
    std::string id;
    std::string interface_luid;
  };
  std::unordered_map<uint64_t, RuleRuntime> rules_;
  std::unordered_map<std::string, Metric> metrics_;
  std::vector<SOCKET> active_sockets_;
  std::condition_variable workers_finished_;
  size_t active_workers_ = 0;
};

#endif
