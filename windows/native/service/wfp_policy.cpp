#include "wfp_policy.h"

#include <initguid.h>
#include <fwpmu.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include <iomanip>
#include <sstream>

#include "../common/wfp_guids.h"
#include "diagnostics.h"

namespace {

std::vector<uint8_t> Hex(const std::string& value) {
  if (value.size() % 2 != 0) return {};
  std::vector<uint8_t> output(value.size() / 2);
  for (size_t i = 0; i < output.size(); ++i) {
    unsigned parsed = 0;
    std::istringstream stream(value.substr(i * 2, 2));
    stream >> std::hex >> parsed;
    if (stream.fail()) return {};
    output[i] = static_cast<uint8_t>(parsed);
  }
  return output;
}

std::string WfpError(const char* action, DWORD code) {
  std::ostringstream stream;
  stream << action << " failed (WFP " << code << ')';
  return stream.str();
}

uint64_t RuleContext(const std::string& value) {
  uint64_t hash = 1469598103934665603ULL;
  for (const unsigned char byte : value) {
    hash ^= byte;
    hash *= 1099511628211ULL;
  }
  return hash;
}

bool DeleteProviderFilters(HANDLE engine, std::string* error) {
  FWPM_FILTER_ENUM_TEMPLATE0 filter_template{};
  filter_template.providerKey = const_cast<GUID*>(&NETPILOT_WFP_PROVIDER);
  HANDLE enum_handle = nullptr;
  DWORD status = FwpmFilterCreateEnumHandle0(engine, &filter_template,
                                              &enum_handle);
  if (status != ERROR_SUCCESS) {
    *error = WfpError("FwpmFilterCreateEnumHandle", status);
    return false;
  }
  bool ok = true;
  for (;;) {
    FWPM_FILTER0** filters = nullptr;
    UINT32 count = 0;
    status = FwpmFilterEnum0(engine, enum_handle, 128, &filters, &count);
    if (status != ERROR_SUCCESS) {
      *error = WfpError("FwpmFilterEnum", status);
      ok = false;
      break;
    }
    for (UINT32 i = 0; i < count; ++i) {
      status = FwpmFilterDeleteById0(engine, filters[i]->filterId);
      if (status != ERROR_SUCCESS &&
          status != static_cast<DWORD>(FWP_E_FILTER_NOT_FOUND)) {
        *error = WfpError("FwpmFilterDeleteById", status);
        ok = false;
        break;
      }
    }
    if (filters) FwpmFreeMemory0(reinterpret_cast<void**>(&filters));
    if (!ok || count == 0) break;
  }
  FwpmFilterDestroyEnumHandle0(engine, enum_handle);
  return ok;
}

}  // namespace

WfpPolicy::WfpPolicy(Diagnostics* diagnostics) : diagnostics_(diagnostics) {}
WfpPolicy::~WfpPolicy() {
  Clear();
  if (engine_) FwpmEngineClose0(engine_);
}

bool WfpPolicy::Initialize(std::string* error) {
  FWPM_SESSION0 session{};
  session.displayData.name = const_cast<wchar_t*>(L"NetPilot Service");
  session.flags = FWPM_SESSION_FLAG_DYNAMIC;
  DWORD status = FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session,
                                 &engine_);
  if (status != ERROR_SUCCESS) {
    *error = WfpError("FwpmEngineOpen", status);
    return false;
  }
  return EnsureProvider(error);
}

bool WfpPolicy::EnsureProvider(std::string* error) {
  FWPM_PROVIDER0 provider{};
  provider.providerKey = NETPILOT_WFP_PROVIDER;
  provider.displayData.name = const_cast<wchar_t*>(L"NetPilot");
  provider.displayData.description =
      const_cast<wchar_t*>(L"NetPilot per-application routing provider");
  DWORD status = FwpmProviderAdd0(engine_, &provider, nullptr);
  if (status != ERROR_SUCCESS &&
      status != static_cast<DWORD>(FWP_E_ALREADY_EXISTS)) {
    *error = WfpError("FwpmProviderAdd", status);
    return false;
  }
  FWPM_SUBLAYER0 sublayer{};
  sublayer.subLayerKey = NETPILOT_WFP_SUBLAYER;
  sublayer.providerKey = const_cast<GUID*>(&NETPILOT_WFP_PROVIDER);
  sublayer.displayData.name = const_cast<wchar_t*>(L"NetPilot routing");
  sublayer.weight = 0x7000;
  status = FwpmSubLayerAdd0(engine_, &sublayer, nullptr);
  if (status != ERROR_SUCCESS &&
      status != static_cast<DWORD>(FWP_E_ALREADY_EXISTS)) {
    *error = WfpError("FwpmSubLayerAdd", status);
    return false;
  }
  FWPM_CALLOUT0 callout{};
  callout.calloutKey = NETPILOT_CONNECT_CALLOUT_V4;
  callout.providerKey = const_cast<GUID*>(&NETPILOT_WFP_PROVIDER);
  callout.displayData.name = const_cast<wchar_t*>(L"NetPilot connect redirect");
  callout.applicableLayer = FWPM_LAYER_ALE_CONNECT_REDIRECT_V4;
  status = FwpmCalloutAdd0(engine_, &callout, nullptr, nullptr);
  if (status != ERROR_SUCCESS &&
      status != static_cast<DWORD>(FWP_E_ALREADY_EXISTS)) {
    *error = WfpError("FwpmCalloutAdd", status);
    return false;
  }
  return true;
}

bool WfpPolicy::InterfaceAvailable(const std::string& value) const {
  NET_LUID luid{};
  try {
    luid.Value = std::stoull(value);
  } catch (...) {
    return false;
  }
  MIB_IF_ROW2 row{};
  row.InterfaceLuid = luid;
  return GetIfEntry2(&row) == NO_ERROR && row.OperStatus == IfOperStatusUp;
}

bool WfpPolicy::Apply(bool master_enabled, const std::string& hash,
                      const std::vector<netpilot::AppRuleSpec>& rules,
                      std::string* error) {
  if (!engine_ && !Initialize(error)) return false;
  DWORD status = FwpmTransactionBegin0(engine_, 0);
  if (status != ERROR_SUCCESS) {
    *error = WfpError("FwpmTransactionBegin", status);
    return false;
  }
  if (!DeleteProviderFilters(engine_, error)) {
    FwpmTransactionAbort0(engine_);
    return false;
  }
  if (master_enabled) {
    for (const auto& rule : rules) {
      if (!rule.enabled) continue;
      const bool available = InterfaceAvailable(rule.interface_luid);
      if (!available && rule.policy == "fallback") {
        diagnostics_->Log("[NetPilot App Routing] fallback rule=" + rule.id +
                          " adapter=" + rule.interface_luid);
        continue;
      }
      for (const auto& executable : rule.executables) {
        if (!AddExecutableFilter(rule, executable, !available, error)) {
          FwpmTransactionAbort0(engine_);
          return false;
        }
      }
    }
  }
  status = FwpmTransactionCommit0(engine_);
  if (status != ERROR_SUCCESS) {
    FwpmTransactionAbort0(engine_);
    *error = WfpError("FwpmTransactionCommit", status);
    return false;
  }
  applied_hash_ = hash;
  return true;
}

bool WfpPolicy::AddExecutableFilter(
    const netpilot::AppRuleSpec& rule,
    const netpilot::AppExecutable& executable, bool block,
    std::string* error) {
  auto app_id = Hex(executable.app_id);
  if (app_id.empty()) {
    *error = rule.id + ": invalid WFP App ID";
    return false;
  }
  FWP_BYTE_BLOB blob{static_cast<UINT32>(app_id.size()), app_id.data()};
  FWPM_FILTER_CONDITION0 condition{};
  condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
  condition.conditionValue.byteBlob = &blob;

  FWPM_FILTER0 filter{};
  filter.providerKey = const_cast<GUID*>(&NETPILOT_WFP_PROVIDER);
  filter.subLayerKey = NETPILOT_WFP_SUBLAYER;
  filter.layerKey = FWPM_LAYER_ALE_CONNECT_REDIRECT_V4;
  filter.displayData.name = const_cast<wchar_t*>(L"NetPilot application rule");
  filter.weight.type = FWP_UINT8;
  filter.weight.uint8 = 15;
  filter.numFilterConditions = 1;
  filter.filterCondition = &condition;
  filter.rawContext = RuleContext(rule.id);
  if (block) {
    filter.action.type = FWP_ACTION_BLOCK;
  } else {
    filter.action.type = FWP_ACTION_CALLOUT_TERMINATING;
    filter.action.calloutKey = NETPILOT_CONNECT_CALLOUT_V4;
  }
  DWORD status = FwpmFilterAdd0(engine_, &filter, nullptr, nullptr);
  if (status != ERROR_SUCCESS) {
    *error = WfpError("FwpmFilterAdd", status);
    return false;
  }
  return true;
}

void WfpPolicy::Clear() {
  if (engine_) {
    std::string ignored;
    DeleteProviderFilters(engine_, &ignored);
  }
  applied_hash_.clear();
}
