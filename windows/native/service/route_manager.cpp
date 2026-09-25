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
#include <set>
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
  const auto prefix_length = row->DestinationPrefix.PrefixLength;
  const uint32_t mask = prefix_length == 0
                            ? 0
                            : 0xffffffffu << (32 - prefix_length);
  row->DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr = htonl(
      ntohl(row->DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr) & mask);
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

std::string IPv4String(const IN_ADDR& address) {
  char output[INET_ADDRSTRLEN]{};
  return InetNtopA(AF_INET, const_cast<IN_ADDR*>(&address), output,
                   INET_ADDRSTRLEN) ? output : std::string();
}

bool SameDestination(const MIB_IPFORWARD_ROW2& left,
                     const MIB_IPFORWARD_ROW2& right) {
  return left.DestinationPrefix.Prefix.si_family == AF_INET &&
         right.DestinationPrefix.Prefix.si_family == AF_INET &&
         left.DestinationPrefix.PrefixLength ==
             right.DestinationPrefix.PrefixLength &&
         left.DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr ==
             right.DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr;
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

  std::set<std::string> removed_destinations;
  std::set<std::string> added_destinations;
  std::vector<netpilot::RouteSpec> next;

  for (const auto& route : managed_) {
    if (std::none_of(validated.begin(), validated.end(),
                     [&](const auto& item) { return Equal(route, item); })) {
      std::string error;
      if (Remove(route, &error)) {
        ++result.removed;
        removed_destinations.insert(route.destination);
      } else {
        result.errors.push_back(route.tag + ": " + error);
        next.push_back(route);  // Keep failed deletions in the inventory.
      }
    }
  }
  for (const auto& route : validated) {
    const bool recorded = std::any_of(managed_.begin(), managed_.end(),
                                     [&](const auto& item) {
                                       return Equal(route, item);
                                     });
    std::string error;
    if (recorded || Add(route, &error)) {
      if (!recorded) {
        ++result.added;
        added_destinations.insert(route.destination);
      }
      next.push_back(route);
    } else {
      result.errors.push_back(route.tag + ": " + error);
      continue;
    }

    auto check = Inspect(route);
    if (!check.exact_present && recorded) {
      // ProgramData survives reboot but the route table does not.
      if (Add(route, &error)) {
        ++result.added;
        added_destinations.insert(route.destination);
        check = Inspect(route);
      } else {
        result.errors.push_back("repair " + route.destination + ": " + error);
      }
    }
    if (!check.verified) result.errors.push_back(check.message);
    result.route_checks.push_back(std::move(check));
  }
  managed_ = std::move(next);
  Save();
  std::set<std::string> changed = removed_destinations;
  for (const auto& check : result.route_checks)
    if (check.verified && added_destinations.count(check.destination))
      changed.insert(check.destination);
  for (const auto& destination : changed)
    result.connection_reset_destinations.push_back(destination);
  result.ok = result.errors.empty();
  return result;
}

netpilot::ReconcileResult::RouteCheck RouteManager::Inspect(
    const netpilot::RouteSpec& route) const {
  netpilot::ReconcileResult::RouteCheck check;
  check.destination = route.destination;
  check.expected_interface = route.interface_luid;
  check.expected_gateway = route.gateway;
  MIB_IPFORWARD_ROW2 expected{};
  std::string error;
  if (!PopulateRow(route, &expected, &error)) {
    check.message = "route check " + route.destination + ": " + error;
    return check;
  }

  PMIB_IPFORWARD_TABLE2 table = nullptr;
  const DWORD table_status = GetIpForwardTable2(AF_INET, &table);
  bool exact_present = false;
  if (table_status == NO_ERROR) {
    for (ULONG index = 0; index < table->NumEntries; ++index) {
      const auto& row = table->Table[index];
      if (!SameDestination(row, expected)) continue;
      if (row.InterfaceLuid.Value == expected.InterfaceLuid.Value &&
          row.NextHop.Ipv4.sin_addr.S_un.S_addr ==
              expected.NextHop.Ipv4.sin_addr.S_un.S_addr) {
        exact_present = true;
        break;
      }
    }
    FreeMibTable(table);
  }
  check.exact_present = exact_present;

  SOCKADDR_INET target{};
  target.si_family = AF_INET;
  const auto prefix = ntohl(expected.DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr);
  const auto length = expected.DestinationPrefix.PrefixLength;
  const uint32_t mask = length == 0 ? 0 : 0xffffffffu << (32 - length);
  target.Ipv4.sin_addr.S_un.S_addr =
      htonl(length == 0 ? 0x08080808u : ((prefix & mask) | (length < 32 ? 1u : 0u)));
  MIB_IPFORWARD_ROW2 best{};
  SOCKADDR_INET source{};
  const DWORD best_status =
      GetBestRoute2(nullptr, 0, nullptr, &target, 0, &best, &source);
  if (best_status == NO_ERROR) {
    check.actual_interface = std::to_string(best.InterfaceLuid.Value);
    if (best.NextHop.si_family == AF_INET &&
        best.NextHop.Ipv4.sin_addr.S_un.S_addr != 0)
      check.actual_gateway = IPv4String(best.NextHop.Ipv4.sin_addr);
  }
  check.verified = exact_present && best_status == NO_ERROR &&
                   best.InterfaceLuid.Value == expected.InterfaceLuid.Value &&
                   (route.gateway.empty() || check.actual_gateway == route.gateway);
  if (!check.verified) {
    check.message = "route " + route.destination + " expected adapter " +
                    route.interface_luid +
                    (route.gateway.empty() ? "" : " via " + route.gateway) +
                    ", actual " +
                    (check.actual_interface.empty() ? "unavailable" : check.actual_interface) +
                    (check.actual_gateway.empty() ? "" : " via " + check.actual_gateway) +
                    (exact_present ? "" : "; exact route missing");
    if (table_status != NO_ERROR)
      check.message += "; " + Win32Error("GetIpForwardTable2", table_status);
    if (best_status != NO_ERROR)
      check.message += "; " + Win32Error("GetBestRoute2", best_status);
  }
  return check;
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
