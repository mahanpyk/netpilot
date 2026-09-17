#ifndef NETPILOT_NATIVE_SERVICE_DIAGNOSTICS_H_
#define NETPILOT_NATIVE_SERVICE_DIAGNOSTICS_H_

#include <deque>
#include <mutex>
#include <string>
#include <vector>

class Diagnostics {
 public:
  void Log(const std::string& line);
  std::vector<std::string> Snapshot() const;

 private:
  mutable std::mutex mutex_;
  std::deque<std::string> lines_;
};

#endif
