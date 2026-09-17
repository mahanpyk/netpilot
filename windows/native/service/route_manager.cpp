#include "route_manager.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <shlobj.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>

namespace {

std::wstring ProgramDataStatePath() {
  PWSTR raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_ProgramData, 0, nullptr, &raw)))
    return L"managed_routes.json";
  std::filesystem::path directory(raw);
  CoTaskMemFree(raw);
  directory /= L"NetPilot";
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  return (directory / L"managed_routes.json").wstring();
}

std::string Escape(const std::string& value) {
  std::string output;
  for (const char character : value) {
    if (character == '\\' || character == '"') output.push_back('\\');
    output.push_back(character);
  }
  return output;
}

bool Equal(const netpilot::RouteSpec& left, const netpilot::RouteSpec& right) {
  return left.destination == right.destination && left.gateway == right.gateway &&
         left.interface_luid == right.interface_luid && left.tag == right.tag;
}

bool PopulateRow(const netpilot::RouteSpec& route, MIB_IPFORWARD_ROW2* row,
                 std::string* error) {
  InitializeIpForwardEntry(row);
  try {
    row->InterfaceLuid.Value = std::stoull(route.interface_luid);
  } catch (...) {
    *error = "invalid adapter LUID";
    return false;
  }
  const auto slash = route.destination.find('/');
  const auto address = route.destination.substr(0, slash);
  row->DestinationPrefix.Prefix.si_family = AF_INET;
  row->DestinationPrefix.PrefixLength = static_cast<UINT8>(
      std::stoi(route.destination.substr(slash + 1)));
  if (InetPtonA(AF_INET, address.c_str(),
                &row->DestinationPrefix.Prefix.Ipv4.sin_addr) != 1) {
    *error = "invalid route destination";
    return false;
  }
  row->NextHop.si_family = AF_INET;
  if (!route.gateway.empty() &&
      InetPtonA(AF_INET, route.gateway.c_str(), &row->NextHop.Ipv4.sin_addr) !=
          1) {
    *error = "invalid route gateway";
    return false;
  }
  row->Metric = 5;
  row->Protocol = static_cast<NL_ROUTE_PROTOCOL>(MIB_IPPROTO_NETMGMT);
  row->ValidLifetime = 0xffffffff;
  row->PreferredLifetime = 0xffffffff;
  return true;
}

std::string Win32Error(const char* operation, DWORD code) {
  std::ostringstream stream;
  stream << operation << " failed (Win32 " << code << ')';
  return stream.str();
}

}  // namespace

RouteManager::RouteManager() : state_path_(ProgramDataStatePath()) { Load(); }

netpilot::ReconcileResult RouteManager::Reconcile(
    const std::vector<netpilot::RouteSpec>& desired) {
  netpilot::ReconcileResult result;
  std::vector<netpilot::RouteSpec> validated;
  for (const auto& route : desired) {
    std::string error;
    if (!netpilot::IsValidRoute(route, &error)) {
      result.errors.push_back(route.tag + ": " + error);
    } else {
      validated.push_back(route);
    }
  }
  if (!result.errors.empty()) return result;

  for (const auto& route : managed_) {
    if (std::none_of(validated.begin(), validated.end(),
                     [&](const auto& item) { return Equal(route, item); })) {
      std::string error;
      if (Remove(route, &error))
        ++result.removed;
      else
        result.errors.push_back(route.tag + ": " + error);
    }
  }
  std::vector<netpilot::RouteSpec> next;
  for (const auto& route : validated) {
    if (std::any_of(managed_.begin(), managed_.end(),
                    [&](const auto& item) { return Equal(route, item); })) {
      next.push_back(route);
      continue;
    }
    std::string error;
    if (Add(route, &error)) {
      ++result.added;
      next.push_back(route);
    } else {
      result.errors.push_back(route.tag + ": " + error);
    }
  }
  managed_ = std::move(next);
  Save();
  result.ok = result.errors.empty();
  return result;
}

bool RouteManager::Add(const netpilot::RouteSpec& route, std::string* error) {
  MIB_IPFORWARD_ROW2 row{};
  if (!PopulateRow(route, &row, error)) return false;
  const DWORD status = CreateIpForwardEntry2(&row);
  if (status == NO_ERROR || status == ERROR_OBJECT_ALREADY_EXISTS) return true;
  *error = Win32Error("CreateIpForwardEntry2", status);
  return false;
}

bool RouteManager::Remove(const netpilot::RouteSpec& route,
                          std::string* error) {
  MIB_IPFORWARD_ROW2 row{};
  if (!PopulateRow(route, &row, error)) return false;
  const DWORD status = DeleteIpForwardEntry2(&row);
  if (status == NO_ERROR || status == ERROR_NOT_FOUND ||
      status == ERROR_FILE_NOT_FOUND) {
    return true;
  }
  *error = Win32Error("DeleteIpForwardEntry2", status);
  return false;
}

void RouteManager::Cleanup() {
  for (const auto& route : managed_) {
    std::string ignored;
    Remove(route, &ignored);
  }
  managed_.clear();
  Save();
}

void RouteManager::Load() {
  std::ifstream input{std::filesystem::path(state_path_)};
  if (!input) return;
  std::ostringstream content;
  content << input.rdbuf();
  const std::regex entry(
      R"json(\{"destination":"([^"]*)","gateway":"([^"]*)","interfaceLuid":"([^"]*)","tag":"([^"]*)"\})json");
  const auto text = content.str();
  for (std::sregex_iterator iterator(text.begin(), text.end(), entry), end;
       iterator != end; ++iterator) {
    managed_.push_back(
        {(*iterator)[1], (*iterator)[2], (*iterator)[3], (*iterator)[4]});
  }
}

void RouteManager::Save() const {
  const auto temporary = state_path_ + L".tmp";
  std::ofstream output(std::filesystem::path(temporary), std::ios::trunc);
  output << "{\n  \"version\": 1,\n  \"routes\": [";
  for (size_t i = 0; i < managed_.size(); ++i) {
    const auto& route = managed_[i];
    output << (i == 0 ? "\n" : ",\n")
           << "    {\"destination\":\"" << Escape(route.destination)
           << "\",\"gateway\":\"" << Escape(route.gateway)
           << "\",\"interfaceLuid\":\"" << Escape(route.interface_luid)
           << "\",\"tag\":\"" << Escape(route.tag) << "\"}";
  }
  output << "\n  ]\n}\n";
  output.close();
  MoveFileExW(temporary.c_str(), state_path_.c_str(),
              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}
