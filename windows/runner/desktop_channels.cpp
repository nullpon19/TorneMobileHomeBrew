#include "desktop_channels.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmsystem.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace {

class DesktopChannelsState {
 public:
  explicit DesktopChannelsState(HWND hwnd) : hwnd_(hwnd) {}

  bool is_fullscreen() const { return is_fullscreen_; }

  bool SetFullscreen(bool target) {
    if (!hwnd_ || !::IsWindow(hwnd_)) return false;
    if (target == is_fullscreen_) return is_fullscreen_;

    DWORD style = static_cast<DWORD>(::GetWindowLongW(hwnd_, GWL_STYLE));
    if (target) {
      MONITORINFO mi = {};
      mi.cbSize = sizeof(mi);
      if (::GetWindowPlacement(hwnd_, &prev_placement_) &&
          ::GetMonitorInfoW(
              ::MonitorFromWindow(hwnd_, MONITOR_DEFAULTTOPRIMARY), &mi)) {
        ::SetWindowLongW(hwnd_, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
        ::SetWindowPos(
            hwnd_, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
            mi.rcMonitor.right - mi.rcMonitor.left,
            mi.rcMonitor.bottom - mi.rcMonitor.top,
            SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        is_fullscreen_ = true;
      }
    } else {
      ::SetWindowLongW(hwnd_, GWL_STYLE, style | WS_OVERLAPPEDWINDOW);
      ::SetWindowPlacement(hwnd_, &prev_placement_);
      ::SetWindowPos(
          hwnd_, nullptr, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
              SWP_FRAMECHANGED);
      is_fullscreen_ = false;
    }
    return is_fullscreen_;
  }

  bool SetKeepAwake(bool keep_awake) {
    if (keep_awake) {
      ::SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED);
      keep_awake_ = true;
    } else {
      ::SetThreadExecutionState(ES_CONTINUOUS);
      keep_awake_ = false;
    }
    return keep_awake_;
  }

  bool keep_awake() const { return keep_awake_; }

  bool PlayWav(const std::vector<uint8_t>& wav) {
    if (wav.empty()) return false;
    ::PlaySoundW(nullptr, nullptr, 0);
    wav_buffer_ = wav;
    BOOL ok = ::PlaySoundW(
        reinterpret_cast<LPCWSTR>(wav_buffer_.data()), nullptr,
        SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
    return ok != FALSE;
  }

 private:
  HWND hwnd_;
  bool is_fullscreen_ = false;
  bool keep_awake_ = false;
  WINDOWPLACEMENT prev_placement_ = {sizeof(WINDOWPLACEMENT)};
  std::vector<uint8_t> wav_buffer_;
};

std::unique_ptr<DesktopChannelsState> g_state;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_window_channel;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_wakelock_channel;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_arib_sound_channel;

}  // namespace

void DesktopChannelsRegister(flutter::PluginRegistrar* registrar,
                             HWND window_handle) {
  g_state = std::make_unique<DesktopChannelsState>(window_handle);

  g_window_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.markun.tmhb/window_control",
          &flutter::StandardMethodCodec::GetInstance());
  g_window_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (!g_state) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        const std::string& method = call.method_name();
        if (method == "isFullscreen") {
          result->Success(flutter::EncodableValue(g_state->is_fullscreen()));
        } else if (method == "toggleFullscreen") {
          result->Success(
              flutter::EncodableValue(g_state->SetFullscreen(!g_state->is_fullscreen())));
        } else if (method == "setFullscreen") {
          bool target = false;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = map->find(flutter::EncodableValue("fullscreen"));
            if (it != map->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) {
                target = *b;
              }
            }
          }
          result->Success(
              flutter::EncodableValue(g_state->SetFullscreen(target)));
        } else {
          result->NotImplemented();
        }
      });

  g_wakelock_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.markun.tmhb/wakelock",
          &flutter::StandardMethodCodec::GetInstance());
  g_wakelock_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (!g_state) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        const std::string& method = call.method_name();
        if (method == "setKeepAwake") {
          bool keep_awake = false;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = map->find(flutter::EncodableValue("keepAwake"));
            if (it != map->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) {
                keep_awake = *b;
              }
            }
          }
          result->Success(
              flutter::EncodableValue(g_state->SetKeepAwake(keep_awake)));
        } else if (method == "getKeepAwake") {
          result->Success(flutter::EncodableValue(g_state->keep_awake()));
        } else {
          result->NotImplemented();
        }
      });

  g_arib_sound_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.markun.tmhb/arib_sound",
          &flutter::StandardMethodCodec::GetInstance());
  g_arib_sound_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (!g_state) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        if (call.method_name() == "playWav") {
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = map->find(flutter::EncodableValue("wav"));
            if (it != map->end()) {
              if (const auto* bytes =
                      std::get_if<std::vector<uint8_t>>(&it->second)) {
                result->Success(flutter::EncodableValue(g_state->PlayWav(*bytes)));
                return;
              }
            }
          }
          result->Success(flutter::EncodableValue(false));
        } else {
          result->NotImplemented();
        }
      });
}
