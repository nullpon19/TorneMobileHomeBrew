#ifndef RUNNER_DESKTOP_CHANNELS_H_
#define RUNNER_DESKTOP_CHANNELS_H_

#include <flutter/plugin_registrar.h>
#include <windows.h>

void DesktopChannelsRegister(flutter::PluginRegistrar* registrar,
                             HWND window_handle);
void DesktopChannelsDestroy();

#endif  // RUNNER_DESKTOP_CHANNELS_H_
