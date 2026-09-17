#ifndef NETPILOT_NATIVE_COMMON_NETPILOT_PROTOCOL_H_
#define NETPILOT_NATIVE_COMMON_NETPILOT_PROTOCOL_H_

#include <cstdint>
#include <string>
#include <vector>

namespace netpilot {

constexpr uint32_t kProtocolMagic = 0x4E504C54;  // NPLT
constexpr uint16_t kProtocolVersion = 1;
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\NetPilotService.v1";
constexpr uint32_t kMaxFrameBytes = 4 * 1024 * 1024;

enum class Operation : uint16_t {
  kPing = 1,
  kStatus = 2,
  kReconcileRoutes = 3,
  kApplyAppRouting = 4,
  kRestartProxy = 5,
  kDiagnostics = 6,
  kCleanup = 7,
};

#pragma pack(push, 1)
struct FrameHeader {
  uint32_t magic = kProtocolMagic;
  uint16_t version = kProtocolVersion;
  uint16_t operation = 0;
  uint32_t payload_size = 0;
};
#pragma pack(pop)

struct RouteSpec {
  std::string destination;
  std::string gateway;
  std::string interface_luid;
  std::string tag;
};

struct AppExecutable {
  std::string path;
  std::string app_id;
};

struct AppRuleSpec {
  std::string id;
  std::string interface_luid;
  std::string policy;
  bool enabled = true;
  std::vector<AppExecutable> executables;
};

struct ServiceStatus {
  bool service_ready = false;
  bool driver_ready = false;
  bool engine_ready = false;
  bool proxy_running = false;
  bool reboot_required = false;
  bool test_mode = false;
  std::string applied_hash;
  std::string message;
  uint32_t active_flows = 0;
  uint64_t bytes_in = 0;
  uint64_t bytes_out = 0;
  struct RuleMetric {
    std::string id;
    uint32_t active_flows = 0;
    uint64_t bytes_in = 0;
    uint64_t bytes_out = 0;
    std::string last_error;
  };
  std::vector<RuleMetric> rule_metrics;
};

struct ReconcileResult {
  bool ok = false;
  uint32_t added = 0;
  uint32_t removed = 0;
  std::vector<std::string> errors;
};

class BufferWriter {
 public:
  void WriteU8(uint8_t value);
  void WriteU32(uint32_t value);
  void WriteU64(uint64_t value);
  void WriteString(const std::string& value);
  const std::vector<uint8_t>& bytes() const { return bytes_; }

 private:
  std::vector<uint8_t> bytes_;
};

class BufferReader {
 public:
  explicit BufferReader(const std::vector<uint8_t>& bytes) : bytes_(bytes) {}
  bool ReadU8(uint8_t* value);
  bool ReadU32(uint32_t* value);
  bool ReadU64(uint64_t* value);
  bool ReadString(std::string* value);
  bool done() const { return offset_ == bytes_.size(); }

 private:
  const std::vector<uint8_t>& bytes_;
  size_t offset_ = 0;
};

void EncodeRoutes(const std::vector<RouteSpec>& routes, BufferWriter* writer);
bool DecodeRoutes(BufferReader* reader, std::vector<RouteSpec>* routes);
void EncodeAppRules(bool master_enabled, const std::string& hash,
                    const std::vector<AppRuleSpec>& rules,
                    BufferWriter* writer);
bool DecodeAppRules(BufferReader* reader, bool* master_enabled,
                    std::string* hash, std::vector<AppRuleSpec>* rules);
void EncodeStatus(const ServiceStatus& status, BufferWriter* writer);
bool DecodeStatus(BufferReader* reader, ServiceStatus* status);
void EncodeReconcileResult(const ReconcileResult& result,
                           BufferWriter* writer);
bool DecodeReconcileResult(BufferReader* reader, ReconcileResult* result);

bool IsValidRoute(const RouteSpec& route, std::string* error);
bool IsValidAppRule(const AppRuleSpec& rule, std::string* error);

}  // namespace netpilot

#endif
