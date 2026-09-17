#include "netpilot_protocol.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <regex>
#include <unordered_set>

namespace netpilot {

void BufferWriter::WriteU8(uint8_t value) { bytes_.push_back(value); }

void BufferWriter::WriteU32(uint32_t value) {
  const auto* begin = reinterpret_cast<const uint8_t*>(&value);
  bytes_.insert(bytes_.end(), begin, begin + sizeof(value));
}

void BufferWriter::WriteU64(uint64_t value) {
  const auto* begin = reinterpret_cast<const uint8_t*>(&value);
  bytes_.insert(bytes_.end(), begin, begin + sizeof(value));
}

void BufferWriter::WriteString(const std::string& value) {
  WriteU32(static_cast<uint32_t>(value.size()));
  bytes_.insert(bytes_.end(), value.begin(), value.end());
}

bool BufferReader::ReadU8(uint8_t* value) {
  if (offset_ + 1 > bytes_.size()) return false;
  *value = bytes_[offset_++];
  return true;
}

bool BufferReader::ReadU32(uint32_t* value) {
  if (offset_ + sizeof(*value) > bytes_.size()) return false;
  std::memcpy(value, bytes_.data() + offset_, sizeof(*value));
  offset_ += sizeof(*value);
  return true;
}

bool BufferReader::ReadU64(uint64_t* value) {
  if (offset_ + sizeof(*value) > bytes_.size()) return false;
  std::memcpy(value, bytes_.data() + offset_, sizeof(*value));
  offset_ += sizeof(*value);
  return true;
}

bool BufferReader::ReadString(std::string* value) {
  uint32_t size = 0;
  if (!ReadU32(&size) || size > kMaxFrameBytes ||
      offset_ + size > bytes_.size()) {
    return false;
  }
  value->assign(reinterpret_cast<const char*>(bytes_.data() + offset_), size);
  offset_ += size;
  return true;
}

void EncodeRoutes(const std::vector<RouteSpec>& routes, BufferWriter* writer) {
  writer->WriteU32(static_cast<uint32_t>(routes.size()));
  for (const auto& route : routes) {
    writer->WriteString(route.destination);
    writer->WriteString(route.gateway);
    writer->WriteString(route.interface_luid);
    writer->WriteString(route.tag);
  }
}

bool DecodeRoutes(BufferReader* reader, std::vector<RouteSpec>* routes) {
  uint32_t count = 0;
  if (!reader->ReadU32(&count) || count > 4096) return false;
  routes->clear();
  routes->reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    RouteSpec route;
    if (!reader->ReadString(&route.destination) ||
        !reader->ReadString(&route.gateway) ||
        !reader->ReadString(&route.interface_luid) ||
        !reader->ReadString(&route.tag)) {
      return false;
    }
    routes->push_back(std::move(route));
  }
  return reader->done();
}

void EncodeAppRules(bool master_enabled, const std::string& hash,
                    const std::vector<AppRuleSpec>& rules,
                    BufferWriter* writer) {
  writer->WriteU8(master_enabled ? 1 : 0);
  writer->WriteString(hash);
  writer->WriteU32(static_cast<uint32_t>(rules.size()));
  for (const auto& rule : rules) {
    writer->WriteString(rule.id);
    writer->WriteString(rule.interface_luid);
    writer->WriteString(rule.policy);
    writer->WriteU8(rule.enabled ? 1 : 0);
    writer->WriteU32(static_cast<uint32_t>(rule.executables.size()));
    for (const auto& executable : rule.executables) {
      writer->WriteString(executable.path);
      writer->WriteString(executable.app_id);
    }
  }
}

bool DecodeAppRules(BufferReader* reader, bool* master_enabled,
                    std::string* hash, std::vector<AppRuleSpec>* rules) {
  uint8_t enabled = 0;
  uint32_t count = 0;
  if (!reader->ReadU8(&enabled) || !reader->ReadString(hash) ||
      !reader->ReadU32(&count) || count > 1024) {
    return false;
  }
  *master_enabled = enabled != 0;
  rules->clear();
  for (uint32_t i = 0; i < count; ++i) {
    AppRuleSpec rule;
    uint8_t rule_enabled = 0;
    uint32_t executable_count = 0;
    if (!reader->ReadString(&rule.id) ||
        !reader->ReadString(&rule.interface_luid) ||
        !reader->ReadString(&rule.policy) ||
        !reader->ReadU8(&rule_enabled) ||
        !reader->ReadU32(&executable_count) || executable_count > 201) {
      return false;
    }
    rule.enabled = rule_enabled != 0;
    for (uint32_t j = 0; j < executable_count; ++j) {
      AppExecutable executable;
      if (!reader->ReadString(&executable.path) ||
          !reader->ReadString(&executable.app_id)) {
        return false;
      }
      rule.executables.push_back(std::move(executable));
    }
    rules->push_back(std::move(rule));
  }
  return reader->done();
}

void EncodeStatus(const ServiceStatus& status, BufferWriter* writer) {
  writer->WriteU8(status.service_ready);
  writer->WriteU8(status.driver_ready);
  writer->WriteU8(status.engine_ready);
  writer->WriteU8(status.proxy_running);
  writer->WriteU8(status.reboot_required);
  writer->WriteU8(status.test_mode);
  writer->WriteString(status.applied_hash);
  writer->WriteString(status.message);
  writer->WriteU32(status.active_flows);
  writer->WriteU64(status.bytes_in);
  writer->WriteU64(status.bytes_out);
  writer->WriteU32(static_cast<uint32_t>(status.rule_metrics.size()));
  for (const auto& metric : status.rule_metrics) {
    writer->WriteString(metric.id);
    writer->WriteU32(metric.active_flows);
    writer->WriteU64(metric.bytes_in);
    writer->WriteU64(metric.bytes_out);
    writer->WriteString(metric.last_error);
  }
}

bool DecodeStatus(BufferReader* reader, ServiceStatus* status) {
  uint8_t service = 0, driver = 0, engine = 0, proxy = 0, reboot = 0,
          test_mode = 0;
  if (!reader->ReadU8(&service) || !reader->ReadU8(&driver) ||
      !reader->ReadU8(&engine) || !reader->ReadU8(&proxy) ||
      !reader->ReadU8(&reboot) || !reader->ReadU8(&test_mode) ||
      !reader->ReadString(&status->applied_hash) ||
      !reader->ReadString(&status->message) ||
      !reader->ReadU32(&status->active_flows) ||
      !reader->ReadU64(&status->bytes_in) ||
      !reader->ReadU64(&status->bytes_out)) {
    return false;
  }
  status->service_ready = service != 0;
  status->driver_ready = driver != 0;
  status->engine_ready = engine != 0;
  status->proxy_running = proxy != 0;
  status->reboot_required = reboot != 0;
  status->test_mode = test_mode != 0;
  uint32_t metric_count = 0;
  if (!reader->ReadU32(&metric_count) || metric_count > 1024) return false;
  for (uint32_t i = 0; i < metric_count; ++i) {
    ServiceStatus::RuleMetric metric;
    if (!reader->ReadString(&metric.id) ||
        !reader->ReadU32(&metric.active_flows) ||
        !reader->ReadU64(&metric.bytes_in) ||
        !reader->ReadU64(&metric.bytes_out) ||
        !reader->ReadString(&metric.last_error)) return false;
    status->rule_metrics.push_back(std::move(metric));
  }
  return reader->done();
}

void EncodeReconcileResult(const ReconcileResult& result,
                           BufferWriter* writer) {
  writer->WriteU8(result.ok);
  writer->WriteU32(result.added);
  writer->WriteU32(result.removed);
  writer->WriteU32(static_cast<uint32_t>(result.errors.size()));
  for (const auto& error : result.errors) writer->WriteString(error);
}

bool DecodeReconcileResult(BufferReader* reader, ReconcileResult* result) {
  uint8_t ok = 0;
  uint32_t count = 0;
  if (!reader->ReadU8(&ok) || !reader->ReadU32(&result->added) ||
      !reader->ReadU32(&result->removed) || !reader->ReadU32(&count) ||
      count > 4096) {
    return false;
  }
  result->ok = ok != 0;
  for (uint32_t i = 0; i < count; ++i) {
    std::string error;
    if (!reader->ReadString(&error)) return false;
    result->errors.push_back(std::move(error));
  }
  return reader->done();
}

bool IsValidRoute(const RouteSpec& route, std::string* error) {
  static const std::regex cidr(
      R"(^((25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])\/(3[0-2]|[12]?[0-9])$)");
  static const std::regex ipv4(
      R"(^((25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])$)");
  static const std::regex luid(R"(^[0-9]{1,20}$)");
  if (!std::regex_match(route.destination, cidr)) *error = "invalid CIDR";
  else if (!route.gateway.empty() && !std::regex_match(route.gateway, ipv4))
    *error = "invalid gateway";
  else if (!std::regex_match(route.interface_luid, luid))
    *error = "invalid adapter LUID";
  else if (route.tag.rfind("netpilot:", 0) != 0 || route.tag.size() > 200)
    *error = "invalid route tag";
  else
    return true;
  return false;
}

bool IsValidAppRule(const AppRuleSpec& rule, std::string* error) {
  static const std::regex id(R"(^[A-Za-z0-9:_-]{1,160}$)");
  static const std::regex luid(R"(^[0-9]{1,20}$)");
  if (!std::regex_match(rule.id, id)) *error = "invalid rule id";
  else if (!std::regex_match(rule.interface_luid, luid))
    *error = "invalid adapter LUID";
  else if (rule.policy != "block" && rule.policy != "fallback")
    *error = "invalid failure policy";
  else if (rule.executables.empty() || rule.executables.size() > 201)
    *error = "invalid executable count";
  else {
    for (const auto& executable : rule.executables) {
      std::filesystem::path path = std::filesystem::u8path(executable.path);
      std::string extension = path.extension().string();
      std::transform(extension.begin(), extension.end(), extension.begin(),
                     [](unsigned char value) { return std::tolower(value); });
      if (!path.is_absolute() || extension != ".exe" ||
          executable.app_id.empty() || executable.app_id.size() > 32768) {
        *error = "invalid executable identity";
        return false;
      }
    }
    return true;
  }
  return false;
}

}  // namespace netpilot
