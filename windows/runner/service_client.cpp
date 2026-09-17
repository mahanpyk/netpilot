#include "service_client.h"

#include <windows.h>

#include <sstream>

namespace {

bool WriteAll(HANDLE pipe, const void* bytes, DWORD size) {
  const auto* cursor = static_cast<const uint8_t*>(bytes);
  while (size > 0) {
    DWORD written = 0;
    if (!WriteFile(pipe, cursor, size, &written, nullptr) || written == 0)
      return false;
    cursor += written;
    size -= written;
  }
  return true;
}

bool ReadAll(HANDLE pipe, void* bytes, DWORD size) {
  auto* cursor = static_cast<uint8_t*>(bytes);
  while (size > 0) {
    DWORD read = 0;
    if (!ReadFile(pipe, cursor, size, &read, nullptr) || read == 0) return false;
    cursor += read;
    size -= read;
  }
  return true;
}

std::string WindowsError(const char* prefix) {
  std::ostringstream stream;
  stream << prefix << " (Win32 " << GetLastError() << ')';
  return stream.str();
}

}  // namespace

bool ServiceClient::Call(netpilot::Operation operation,
                         const std::vector<uint8_t>& request,
                         std::vector<uint8_t>* response,
                         std::string* error) const {
  if (!WaitNamedPipeW(netpilot::kPipeName, 2500)) {
    *error = WindowsError("NetPilot Windows Service is unavailable");
    return false;
  }
  HANDLE pipe = CreateFileW(netpilot::kPipeName, GENERIC_READ | GENERIC_WRITE,
                            0, nullptr, OPEN_EXISTING, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    *error = WindowsError("Could not connect to NetPilot Windows Service");
    return false;
  }
  netpilot::FrameHeader header;
  header.operation = static_cast<uint16_t>(operation);
  header.payload_size = static_cast<uint32_t>(request.size());
  bool ok = WriteAll(pipe, &header, sizeof(header)) &&
            (request.empty() ||
             WriteAll(pipe, request.data(), header.payload_size));
  netpilot::FrameHeader reply;
  ok = ok && ReadAll(pipe, &reply, sizeof(reply));
  if (ok && (reply.magic != netpilot::kProtocolMagic ||
             reply.version != netpilot::kProtocolVersion ||
             reply.operation != header.operation ||
             reply.payload_size > netpilot::kMaxFrameBytes)) {
    ok = false;
    *error = "NetPilot Windows Service returned an invalid frame";
  }
  if (ok) {
    response->resize(reply.payload_size);
    ok = reply.payload_size == 0 ||
         ReadAll(pipe, response->data(), reply.payload_size);
  }
  if (!ok && error->empty()) *error = WindowsError("Service I/O failed");
  CloseHandle(pipe);
  return ok;
}

bool ServiceClient::GetStatus(netpilot::ServiceStatus* status,
                              std::string* error) const {
  std::vector<uint8_t> response;
  if (!Call(netpilot::Operation::kStatus, {}, &response, error)) return false;
  netpilot::BufferReader reader(response);
  if (!netpilot::DecodeStatus(&reader, status)) {
    *error = "NetPilot Windows Service returned invalid status data";
    return false;
  }
  return true;
}

bool ServiceClient::ReconcileRoutes(
    const std::vector<netpilot::RouteSpec>& routes,
    netpilot::ReconcileResult* result, std::string* error) const {
  netpilot::BufferWriter writer;
  netpilot::EncodeRoutes(routes, &writer);
  std::vector<uint8_t> response;
  if (!Call(netpilot::Operation::kReconcileRoutes, writer.bytes(), &response,
            error)) {
    return false;
  }
  netpilot::BufferReader reader(response);
  if (!netpilot::DecodeReconcileResult(&reader, result)) {
    *error = "NetPilot Windows Service returned invalid reconcile data";
    return false;
  }
  return true;
}

bool ServiceClient::ApplyAppRouting(
    bool master_enabled, const std::string& hash,
    const std::vector<netpilot::AppRuleSpec>& rules,
    netpilot::ServiceStatus* status, std::string* error) const {
  netpilot::BufferWriter writer;
  netpilot::EncodeAppRules(master_enabled, hash, rules, &writer);
  std::vector<uint8_t> response;
  if (!Call(netpilot::Operation::kApplyAppRouting, writer.bytes(), &response,
            error)) {
    return false;
  }
  netpilot::BufferReader reader(response);
  if (!netpilot::DecodeStatus(&reader, status)) {
    *error = "NetPilot Windows Service returned invalid apply data";
    return false;
  }
  return true;
}

bool ServiceClient::GetDiagnostics(std::vector<std::string>* lines,
                                   std::string* error) const {
  std::vector<uint8_t> response;
  if (!Call(netpilot::Operation::kDiagnostics, {}, &response, error))
    return false;
  netpilot::BufferReader reader(response);
  uint32_t count = 0;
  if (!reader.ReadU32(&count) || count > 1000) return false;
  for (uint32_t i = 0; i < count; ++i) {
    std::string line;
    if (!reader.ReadString(&line)) return false;
    lines->push_back(std::move(line));
  }
  return reader.done();
}
