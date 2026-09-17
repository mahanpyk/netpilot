#include "windows_app_inspector.h"

#include <windows.h>
#include <fwpmu.h>
#include <softpub.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <shobjidl.h>

#include <algorithm>
#include <filesystem>
#include <iomanip>
#include <sstream>

namespace {

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      output.data(), size, nullptr, nullptr);
  return output;
}

std::wstring CanonicalPath(const std::wstring& input) {
  HANDLE file = CreateFileW(input.c_str(), FILE_READ_ATTRIBUTES,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  std::wstring value(32768, L'\0');
  DWORD size = GetFinalPathNameByHandleW(file, value.data(),
                                         static_cast<DWORD>(value.size()),
                                         FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  CloseHandle(file);
  if (size == 0 || size >= value.size()) return {};
  value.resize(size);
  if (value.rfind(L"\\\\?\\", 0) == 0) value.erase(0, 4);
  return value;
}

std::string AppIdHex(const std::wstring& path) {
  FWP_BYTE_BLOB* blob = nullptr;
  if (FwpmGetAppIdFromFileName0(path.c_str(), &blob) != ERROR_SUCCESS || !blob)
    return {};
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (UINT32 i = 0; i < blob->size; ++i)
    stream << std::setw(2) << static_cast<unsigned>(blob->data[i]);
  FwpmFreeMemory0(reinterpret_cast<void**>(&blob));
  return stream.str();
}

bool VerifySignature(const std::wstring& path) {
  WINTRUST_FILE_INFO file{};
  file.cbStruct = sizeof(file);
  file.pcwszFilePath = path.c_str();
  WINTRUST_DATA data{};
  data.cbStruct = sizeof(data);
  data.dwUIChoice = WTD_UI_NONE;
  data.fdwRevocationChecks = WTD_REVOKE_NONE;
  data.dwUnionChoice = WTD_CHOICE_FILE;
  data.pFile = &file;
  data.dwStateAction = WTD_STATEACTION_VERIFY;
  data.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
  GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  const LONG result = WinVerifyTrust(nullptr, &policy, &data);
  data.dwStateAction = WTD_STATEACTION_CLOSE;
  WinVerifyTrust(nullptr, &policy, &data);
  return result == ERROR_SUCCESS;
}

std::string Publisher(const std::wstring& path) {
  HCERTSTORE store = nullptr;
  HCRYPTMSG message = nullptr;
  DWORD encoding = 0, content = 0, format = 0;
  if (!CryptQueryObject(CERT_QUERY_OBJECT_FILE, path.c_str(),
                        CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                        CERT_QUERY_FORMAT_FLAG_BINARY, 0, &encoding, &content,
                        &format, &store, &message, nullptr)) {
    return {};
  }
  DWORD signer_size = 0;
  CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, nullptr, &signer_size);
  std::vector<uint8_t> signer_buffer(signer_size);
  std::string publisher;
  if (signer_size > 0 &&
      CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0,
                       signer_buffer.data(), &signer_size)) {
    auto* signer = reinterpret_cast<PCMSG_SIGNER_INFO>(signer_buffer.data());
    CERT_INFO info{};
    info.Issuer = signer->Issuer;
    info.SerialNumber = signer->SerialNumber;
    PCCERT_CONTEXT certificate =
        CertFindCertificateInStore(store, encoding, 0, CERT_FIND_SUBJECT_CERT,
                                   &info, nullptr);
    if (certificate) {
      DWORD length = CertGetNameStringW(certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE,
                                        0, nullptr, nullptr, 0);
      std::wstring name(length > 0 ? length : 0, L'\0');
      if (length > 1) {
        CertGetNameStringW(certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0,
                           nullptr, name.data(), length);
        name.pop_back();
      }
      publisher = Utf8(name);
      CertFreeCertificateContext(certificate);
    }
  }
  if (message) CryptMsgClose(message);
  if (store) CertCloseStore(store, 0);
  return publisher;
}

std::string Base64(const uint8_t* bytes, size_t size) {
  static constexpr char table[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string output;
  output.reserve(((size + 2) / 3) * 4);
  for (size_t index = 0; index < size; index += 3) {
    const uint32_t value = static_cast<uint32_t>(bytes[index]) << 16 |
                           (index + 1 < size
                                ? static_cast<uint32_t>(bytes[index + 1]) << 8
                                : 0) |
                           (index + 2 < size ? bytes[index + 2] : 0);
    output.push_back(table[(value >> 18) & 0x3f]);
    output.push_back(table[(value >> 12) & 0x3f]);
    output.push_back(index + 1 < size ? table[(value >> 6) & 0x3f] : '=');
    output.push_back(index + 2 < size ? table[value & 0x3f] : '=');
  }
  return output;
}

std::string IconPngBase64(const std::wstring& path) {
  Microsoft::WRL::ComPtr<IShellItemImageFactory> image_factory;
  if (FAILED(SHCreateItemFromParsingName(path.c_str(), nullptr,
                                         IID_PPV_ARGS(&image_factory))))
    return {};
  HBITMAP bitmap_handle = nullptr;
  SIZE size{64, 64};
  if (FAILED(image_factory->GetImage(
          size, SIIGBF_ICONONLY | SIIGBF_BIGGERSIZEOK, &bitmap_handle)) ||
      !bitmap_handle)
    return {};

  Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
  Microsoft::WRL::ComPtr<IWICBitmap> bitmap;
  Microsoft::WRL::ComPtr<IWICStream> stream;
  Microsoft::WRL::ComPtr<IWICBitmapEncoder> encoder;
  Microsoft::WRL::ComPtr<IWICBitmapFrameEncode> frame;
  Microsoft::WRL::ComPtr<IPropertyBag2> properties;
  std::vector<uint8_t> output(512 * 1024);
  HRESULT result = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&factory));
  if (SUCCEEDED(result))
    result = factory->CreateBitmapFromHBITMAP(bitmap_handle, nullptr,
                                              WICBitmapUsePremultipliedAlpha,
                                              &bitmap);
  DeleteObject(bitmap_handle);
  if (SUCCEEDED(result)) result = factory->CreateStream(&stream);
  if (SUCCEEDED(result))
    result = stream->InitializeFromMemory(output.data(),
                                          static_cast<DWORD>(output.size()));
  if (SUCCEEDED(result))
    result = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(result))
    result = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (SUCCEEDED(result)) result = encoder->CreateNewFrame(&frame, &properties);
  if (SUCCEEDED(result)) result = frame->Initialize(properties.Get());
  if (SUCCEEDED(result)) result = frame->WriteSource(bitmap.Get(), nullptr);
  if (SUCCEEDED(result)) result = frame->Commit();
  if (SUCCEEDED(result)) result = encoder->Commit();
  ULARGE_INTEGER position{};
  LARGE_INTEGER zero{};
  if (SUCCEEDED(result))
    result = stream->Seek(zero, STREAM_SEEK_CUR, &position);
  return SUCCEEDED(result) && position.QuadPart <= output.size()
             ? Base64(output.data(), static_cast<size_t>(position.QuadPart))
             : std::string();
}

}  // namespace

std::optional<std::wstring> WindowsAppInspector::PickExe(
    std::string* error) {
  Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
  HRESULT result = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(result)) {
    *error = "Could not open the Windows application picker";
    return std::nullopt;
  }
  const COMDLG_FILTERSPEC filters[] = {{L"Windows applications", L"*.exe"}};
  dialog->SetFileTypes(1, filters);
  dialog->SetTitle(L"Choose a Win32 application");
  result = dialog->Show(nullptr);
  if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return std::nullopt;
  if (FAILED(result)) {
    *error = "Windows application picker failed";
    return std::nullopt;
  }
  Microsoft::WRL::ComPtr<IShellItem> item;
  if (FAILED(dialog->GetResult(&item))) return std::nullopt;
  PWSTR raw = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw)) || !raw)
    return std::nullopt;
  std::wstring path(raw);
  CoTaskMemFree(raw);
  return path;
}

std::optional<InspectedExecutable> WindowsAppInspector::Inspect(
    const std::wstring& path, std::string* error) {
  const auto canonical = CanonicalPath(path);
  if (canonical.empty() ||
      _wcsicmp(std::filesystem::path(canonical).extension().c_str(), L".exe") !=
          0) {
    *error = "Selected file is not a readable Win32 EXE";
    return std::nullopt;
  }
  InspectedExecutable executable;
  executable.path = Utf8(canonical);
  executable.app_id = AppIdHex(canonical);
  executable.display_name = Utf8(std::filesystem::path(canonical).filename());
  executable.is_signed = VerifySignature(canonical);
  if (executable.is_signed) executable.publisher = Publisher(canonical);
  if (executable.app_id.empty()) {
    *error = "WFP could not derive an App ID for the selected EXE";
    return std::nullopt;
  }
  return executable;
}

std::optional<InspectedApplication> WindowsAppInspector::SelectAndInspect(
    std::string* error) const {
  const auto picked = PickExe(error);
  if (!picked) return std::nullopt;
  const auto picked_name = std::filesystem::path(*picked).filename().wstring();
  if (_wcsicmp(picked_name.c_str(), L"NetPilotService.exe") == 0 ||
      _wcsicmp(picked_name.c_str(), L"netpilot_desktop.exe") == 0 ||
      _wcsicmp(picked_name.c_str(), L"NetPilotMaintenance.exe") == 0) {
    *error = "NetPilot components cannot be routed through their own proxy";
    return std::nullopt;
  }
  auto main = Inspect(*picked, error);
  if (!main) return std::nullopt;
  main->selected = true;
  InspectedApplication application{*main, {},
                                   IconPngBase64(CanonicalPath(*picked))};
  const auto root = std::filesystem::path(*picked).parent_path();
  std::error_code ec;
  size_t candidates = 0;
  for (std::filesystem::recursive_directory_iterator iterator(
           root, std::filesystem::directory_options::skip_permission_denied,
           ec),
       end;
       iterator != end && candidates < 200; iterator.increment(ec)) {
    if (ec) {
      ec.clear();
      continue;
    }
    if (iterator->is_directory(ec) &&
        (iterator->symlink_status(ec).type() ==
             std::filesystem::file_type::symlink ||
         (GetFileAttributesW(iterator->path().c_str()) &
          FILE_ATTRIBUTE_REPARSE_POINT))) {
      iterator.disable_recursion_pending();
      continue;
    }
    if (!iterator->is_regular_file(ec) ||
        _wcsicmp(iterator->path().extension().c_str(), L".exe") != 0 ||
        _wcsicmp(iterator->path().c_str(), picked->c_str()) == 0) {
      continue;
    }
    ++candidates;
    std::string inspect_error;
    auto helper = Inspect(iterator->path().wstring(), &inspect_error);
    if (!helper) continue;
    helper->selected = main->is_signed && helper->is_signed &&
                       !main->publisher.empty() &&
                       helper->publisher == main->publisher;
    application.helpers.push_back(std::move(*helper));
  }
  return application;
}
