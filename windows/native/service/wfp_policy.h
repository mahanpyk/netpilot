#ifndef NETPILOT_NATIVE_SERVICE_WFP_POLICY_H_
#define NETPILOT_NATIVE_SERVICE_WFP_POLICY_H_

#include <winsock2.h>
#include <windows.h>
#include <fwpmu.h>

#include <string>
#include <vector>

#include "../common/netpilot_protocol.h"

class Diagnostics;

class WfpPolicy {
 public:
  explicit WfpPolicy(Diagnostics* diagnostics);
  ~WfpPolicy();

  bool Initialize(std::string* error);
  bool Apply(bool master_enabled, const std::string& hash,
             const std::vector<netpilot::AppRuleSpec>& rules,
             std::string* error);
  void Clear();
  bool ready() const { return engine_ != nullptr; }
  const std::string& applied_hash() const { return applied_hash_; }

 private:
  bool EnsureProvider(std::string* error);
  bool AddExecutableFilter(const netpilot::AppRuleSpec& rule,
                           const netpilot::AppExecutable& executable,
                           bool block, std::string* error);
  bool InterfaceAvailable(const std::string& luid) const;

  HANDLE engine_ = nullptr;
  Diagnostics* diagnostics_;
  std::string applied_hash_;
};

#endif
