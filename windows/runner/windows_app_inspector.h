#ifndef RUNNER_WINDOWS_APP_INSPECTOR_H_
#define RUNNER_WINDOWS_APP_INSPECTOR_H_

#include <optional>
#include <string>
#include <vector>

struct InspectedExecutable {
  std::string path;
  std::string app_id;
  std::string display_name;
  std::string publisher;
  bool is_signed = false;
  bool selected = false;
};

struct InspectedApplication {
  InspectedExecutable main;
  std::vector<InspectedExecutable> helpers;
  std::string icon_png_base64;
};

class WindowsAppInspector {
 public:
  std::optional<InspectedApplication> SelectAndInspect(std::string* error) const;

 private:
  static std::optional<std::wstring> PickExe(std::string* error);
  static std::optional<InspectedExecutable> Inspect(const std::wstring& path,
                                                     std::string* error);
};

#endif
