#include "desktop_channels.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmsystem.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace {

class DesktopChannelsState {
 public:
  explicit DesktopChannelsState(HWND hwnd) : hwnd_(hwnd) {}
  ~DesktopChannelsState() {
    ::PlaySoundW(nullptr, nullptr, 0);
    if (keep_awake_) {
      ::SetThreadExecutionState(ES_CONTINUOUS);
      keep_awake_ = false;
    }
  }

  bool is_fullscreen() const { return is_fullscreen_; }

  bool SetFullscreen(bool target) {
    if (!hwnd_ || !::IsWindow(hwnd_)) return false;
    if (target == is_fullscreen_) return is_fullscreen_;
    if (target && in_pip_) {
      ExitPip();
    }

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

  bool in_pip() const { return in_pip_; }

  void SetPipEventSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
    pip_event_sink_ = std::move(sink);
    if (pip_event_sink_ && in_pip_) {
      pip_event_sink_->Success(flutter::EncodableValue(true));
    }
  }

  void ClearPipEventSink() { pip_event_sink_.reset(); }

  bool EnterPip(int aspect_width, int aspect_height) {
    if (!hwnd_ || !::IsWindow(hwnd_)) return false;
    if (in_pip_) return true;
    if (is_fullscreen_) {
      SetFullscreen(false);
    }
    ::GetWindowPlacement(hwnd_, &prev_pip_placement_);
    prev_pip_style_ = static_cast<DWORD>(::GetWindowLongW(hwnd_, GWL_STYLE));

    int safe_w = (aspect_width > 0 && aspect_height > 0) ? aspect_width : 16;
    int safe_h = (aspect_width > 0 && aspect_height > 0) ? aspect_height : 9;
    int target_w = 480;
    int target_h = static_cast<int>(std::lround(480.0 * safe_h / safe_w));

    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    int x = 40;
    int y = 40;
    if (::GetMonitorInfoW(::MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST), &mi)) {
      int margin = 24;
      x = std::max<int>(mi.rcWork.left, mi.rcWork.right - target_w - margin);
      y = std::max<int>(mi.rcWork.top, mi.rcWork.bottom - target_h - margin);
    }

    ::SetWindowLongW(hwnd_, GWL_STYLE, WS_POPUP | WS_THICKFRAME | WS_VISIBLE);
    ::SetWindowPos(
        hwnd_, HWND_TOPMOST, x, y, target_w, target_h,
        SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    in_pip_ = true;
    if (pip_event_sink_) {
      pip_event_sink_->Success(flutter::EncodableValue(true));
    }
    return true;
  }

  bool ExitPip() {
    if (!hwnd_ || !::IsWindow(hwnd_) || !in_pip_) return false;
    ::SetWindowLongW(hwnd_, GWL_STYLE, prev_pip_style_);
    ::SetWindowPlacement(hwnd_, &prev_pip_placement_);
    ::SetWindowPos(
        hwnd_, HWND_NOTOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    in_pip_ = false;
    if (pip_event_sink_) {
      pip_event_sink_->Success(flutter::EncodableValue(false));
    }
    return true;
  }

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
  bool in_pip_ = false;
  WINDOWPLACEMENT prev_placement_ = {sizeof(WINDOWPLACEMENT)};
  WINDOWPLACEMENT prev_pip_placement_ = {sizeof(WINDOWPLACEMENT)};
  DWORD prev_pip_style_ = WS_OVERLAPPEDWINDOW;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> pip_event_sink_;
  std::vector<uint8_t> wav_buffer_;
};

std::unique_ptr<DesktopChannelsState> g_state;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_window_channel;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_wakelock_channel;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_arib_sound_channel;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    g_pip_channel;
std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
    g_pip_event_channel;

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

  g_pip_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.markun.tmhb/pip",
          &flutter::StandardMethodCodec::GetInstance());
  g_pip_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (!g_state) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        const std::string& method = call.method_name();
        if (method == "isSupported") {
          result->Success(flutter::EncodableValue(true));
        } else if (method == "enterPip") {
          int aspect_w = 16;
          int aspect_h = 9;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto wit = map->find(flutter::EncodableValue("aspectWidth"));
            if (wit != map->end()) {
              if (const auto* v = std::get_if<int32_t>(&wit->second)) {
                aspect_w = *v;
              }
            }
            auto hit = map->find(flutter::EncodableValue("aspectHeight"));
            if (hit != map->end()) {
              if (const auto* v = std::get_if<int32_t>(&hit->second)) {
                aspect_h = *v;
              }
            }
          }
          result->Success(flutter::EncodableValue(g_state->EnterPip(aspect_w, aspect_h)));
        } else if (method == "exitPip") {
          result->Success(flutter::EncodableValue(g_state->ExitPip()));
        } else if (method == "setAutoPipEnabled") {
          result->Success(flutter::EncodableValue(true));
        } else if (method == "isInPipMode") {
          result->Success(flutter::EncodableValue(g_state->in_pip()));
        } else {
          result->NotImplemented();
        }
      });

  g_pip_event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.markun.tmhb/pip_events",
          &flutter::StandardMethodCodec::GetInstance());
  auto pip_handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [](const flutter::EncodableValue* arguments,
         std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        if (g_state) {
          g_state->SetPipEventSink(std::move(events));
        }
        return nullptr;
      },
      [](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        if (g_state) {
          g_state->ClearPipEventSink();
        }
        return nullptr;
      });
  g_pip_event_channel->SetStreamHandler(std::move(pip_handler));
}

void DesktopChannelsDestroy() {
  ::PlaySoundW(nullptr, nullptr, 0);
  g_pip_event_channel.reset();
  g_pip_channel.reset();
  g_arib_sound_channel.reset();
  g_wakelock_channel.reset();
  g_window_channel.reset();
  g_state.reset();
}
