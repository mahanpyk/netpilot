#include "diagnostics.h"

#include <windows.h>

#include <iostream>

void Diagnostics::Log(const std::string& line) {
  const std::string formatted = line.rfind("[NetPilot", 0) == 0
                                    ? line
                                    : "[NetPilot] " + line;
  {
    std::scoped_lock lock(mutex_);
    lines_.push_back(formatted);
    while (lines_.size() > 500) lines_.pop_front();
  }
  std::cout << formatted << std::endl;
  HANDLE source = RegisterEventSourceW(nullptr, L"NetPilot Service");
  if (source) {
    std::wstring wide(formatted.begin(), formatted.end());
    const wchar_t* values[] = {wide.c_str()};
    ReportEventW(source, EVENTLOG_INFORMATION_TYPE, 0, 1, nullptr, 1, 0,
                 values, nullptr);
    DeregisterEventSource(source);
  }
}

std::vector<std::string> Diagnostics::Snapshot() const {
  std::scoped_lock lock(mutex_);
  return {lines_.begin(), lines_.end()};
}
