// ==WindhawkMod==
// @id minban-qq-notice
// @name 民办mac：应用单图标短提醒（Beta）
// @description 普通应用请求任务栏闪烁时，从原按钮位置独立抬升短提醒
// @version 0.3.0
// @author Holmes-zhang
// @include explorer.exe
// @architecture x86-64
// @compilerOptions -lshell32 -lgdi32 -lole32 -loleaut32 -luuid -ldwmapi
// ==/WindhawkMod==
// SPDX-License-Identifier: GPL-3.0-only
// CTaskBand 符号名称参考 Cirn09 的 Better Taskbar Autohide。
// ==WindhawkModSettings==
/*
- duration: 1200
  $name: 提醒总时长（毫秒）
- diagnostics: false
  $name: 记录本机排查日志
*/
// ==/WindhawkModSettings==
#include <windhawk_utils.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <atomic>
#include <mutex>
#include <string>
#include <algorithm>
#include <cmath>
#include <memory>
#include <unordered_map>
#include "NoticePolicy.h"
#include "AppIdentity.h"
#include "TaskbarTarget.h"
#include "NoticeSurface.h"


namespace {
constexpr UINT kAlert = WM_APP + 71;
constexpr UINT_PTR kTimer = 71;
constexpr wchar_t kClass[] = L"MinbanMac.QQNotice.Trial.0.1";
std::atomic<HWND> g_popup{};
std::atomic<int> g_duration{1200};
std::atomic<bool> g_diagnostics{};

std::atomic<bool> g_stopping{};
HANDLE g_thread{}, g_ready{};
HINSTANCE g_instance{};
UINT g_shellMessage{};
UINT g_fallbackMessage{};
UINT g_positionMessage{};
std::atomic<bool> g_enableTest{};
using WndProc = LRESULT(WINAPI*)(void*, HWND, UINT, WPARAM, LPARAM);
WndProc g_original{};
using GetIconRect = LRESULT(__cdecl*)(void*, HWND, RECT*);
GetIconRect g_getIconRect{};
std::mutex g_postMutex;
struct Alert { HWND target{}; HWND taskbar{}; HWND band{}; RECT slot{}; AppIdentity app; };

// 仅记录运行阶段和坐标有效性，不读取消息内容或联系人。
void Record(const char* event) {
    if(!g_diagnostics.load()) return;
    wchar_t dir[MAX_PATH];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH)) return;
    std::wstring folder = std::wstring(dir) + L"\\MinbanMac";
    CreateDirectoryW(folder.c_str(), nullptr);
    std::wstring file = folder + L"\\notice.log";
    HANDLE h = CreateFileW(file.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    std::string line = std::to_string(GetTickCount64()) + " " + event + "\r\n";
    DWORD wrote;
    WriteFile(h, line.data(), static_cast<DWORD>(line.size()), &wrote, nullptr);
    CloseHandle(h);
}

bool Hidden(HWND taskbar, MONITORINFO& monitor) {
    RECT rc;
    monitor.cbSize = sizeof(monitor);
    return IsWindow(taskbar) && GetWindowRect(taskbar, &rc) &&
           GetMonitorInfoW(MonitorFromWindow(taskbar, MONITOR_DEFAULTTONEAREST), &monitor) &&
           rc.top >= monitor.rcMonitor.bottom - 3;
}

struct PopupState {
    Alert alert;
    HICON icon{};
    uint64_t start{}, deadline{};
    bool showing{};
    bool frameChecked{};
    unsigned renderedFrames{};
    int size{}, x{}, y{};
    uint64_t lastPositionCheck{};
    NoticePolicy policy;
    bool dispatcher{};
};
std::unordered_map<std::wstring, std::unique_ptr<PopupState>> g_components;
std::unordered_map<std::wstring, HWND> g_componentWindows;
bool AnyShowing() {
    for(auto& [key,component]:g_components) if(component->showing) return true;
    return false;
}


// 画一个独立的小胶囊；不裁剪、不移动原生任务栏。
bool Render(HWND window, PopupState& state, BYTE opacity, int lift) {
    int size = state.size;
    HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = size;
    info.bmiHeader.biHeight = -size;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    DWORD* bits = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
                                     reinterpret_cast<void**>(&bits), nullptr, 0);
    if (!screen || !dc || !bitmap || !bits) {
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
        if (screen) ReleaseDC(nullptr, screen);
        return false;
    }
    HGDIOBJ old = SelectObject(dc, bitmap);
    bool painted = PaintNoticeSurface(dc,bits,size,state.icon);    POINT point{state.x, state.y + lift}, source{};
    SIZE extent{size, size};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, opacity, AC_SRC_ALPHA};
    BOOL result = painted && UpdateLayeredWindow(window, screen, &point, &extent, dc,
                                     &source, 0, &blend, ULW_ALPHA);
    SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr, screen);
    return result;
}

LRESULT CALLBACK PopupProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    auto* state = reinterpret_cast<PopupState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        state = static_cast<PopupState*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
    }
    if (!state) return DefWindowProcW(window, message, wp, lp);
    if (message == kAlert && state->dispatcher) {
        std::unique_ptr<Alert> incoming(reinterpret_cast<Alert*>(lp));
        if (!incoming) return 0;
        std::wstring key = incoming->app.appId.empty() ? Fold(incoming->app.path) : incoming->app.appId;
        key += L":" + std::to_wstring(reinterpret_cast<uintptr_t>(incoming->taskbar));
        if (!g_components.contains(key)) {
            if (g_components.size() >= 32) {
                for (auto it = g_components.begin(); it != g_components.end(); ++it) {
                    if (!it->second->showing) {
                        SendMessageW(g_componentWindows[it->first], WM_CLOSE, 0, 0);
                        g_componentWindows.erase(it->first); g_components.erase(it); break;
                    }
                }
                if (g_components.size() >= 32) {
                    PostMessageW(incoming->band, g_fallbackMessage, 0, reinterpret_cast<LPARAM>(incoming->target));
                    return 0;
                }
            }
            auto childState = std::make_unique<PopupState>();

            HWND child = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
                kClass, L"应用提醒", WS_POPUP, 0, 0, 48, 48, nullptr, nullptr, g_instance, childState.get());
            if (!child) {
                PostMessageW(incoming->band, g_fallbackMessage, 0, reinterpret_cast<LPARAM>(incoming->target));
                return 0;
            }
            g_componentWindows[key] = child; g_components[key] = std::move(childState);
        }
        SendMessageW(g_componentWindows[key], kAlert, 0, reinterpret_cast<LPARAM>(incoming.release()));
        return 0;
    }
    auto hide = [&] {
        ShowWindow(window, SW_HIDE); KillTimer(window, kTimer);
        if(state->showing) {
            std::string stats="hidden frames="+std::to_string(state->renderedFrames)+
                " elapsed="+std::to_string(GetTickCount64()-state->start);
            Record(stats.c_str());
        }
        state->showing = false;

    };
    if (message == kAlert) {
        std::unique_ptr<Alert> incoming(reinterpret_cast<Alert*>(lp));
        if (!incoming) return 0;
        Alert alert = std::move(*incoming);
        auto fallback = [&] {
            if (IsWindow(alert.band) && IsWindow(alert.target))
                PostMessageW(alert.band, g_fallbackMessage, 0, reinterpret_cast<LPARAM>(alert.target));
        };
        uint64_t now = GetTickCount64();
        bool fresh = state->policy.Signal(now, g_duration.load());
        if (!fresh) { Record("repeat-flash-suppressed"); return 0; }
        MONITORINFO monitor{}; POINT mouse{};
        if(!Hidden(alert.taskbar,monitor)) { Record("taskbar-visible-no-independent-reminder"); return 0; }
        if(!GetCursorPos(&mouse)) { Record("cursor-query-failed"); return 0; }
        if(mouse.y>=monitor.rcMonitor.bottom-8) { Record("cursor-at-bottom-no-independent-reminder"); return 0; }
        RECT slot{};
        slot = alert.slot;
        if (slot.right <= slot.left || slot.left < monitor.rcMonitor.left || slot.right > monitor.rcMonitor.right) {
            Record("button-position-unavailable-native-fallback"); fallback(); return 0;
        }        alert.slot = slot;
        Record("button-position-confirmed");
        if (state->icon) { DestroyIcon(state->icon); state->icon = nullptr; }
        // 直接读取程序资源，不调用第三方 Shell 扩展。
        HICON large{};
        if (alert.app.test) large = CopyIcon(LoadIconW(nullptr, IDI_INFORMATION));
        else {
            DWORD_PTR result{};
            if (SendMessageTimeoutW(alert.target, WM_GETICON, ICON_BIG, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 40, &result) && result)
                large = CopyIcon(reinterpret_cast<HICON>(result));
            if (!large) ExtractIconExW(alert.app.path.c_str(), 0, &large, nullptr, 1);
        }
        if (!large) {
            DWORD_PTR result{};
            if (SendMessageTimeoutW(alert.target, WM_GETICON, ICON_SMALL2, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 40, &result) && result)
                large = CopyIcon(reinterpret_cast<HICON>(result));
            if (!large) {
                HICON classIcon = reinterpret_cast<HICON>(GetClassLongPtrW(alert.target, GCLP_HICON));
                if (classIcon) large = CopyIcon(classIcon);
            }
        }
        if (!large) { Record("icon-unavailable-native-fallback"); fallback(); return 0; }
        state->icon = large;
        state->alert = std::move(alert);
        UINT dpi = GetDpiForWindow(state->alert.taskbar);
        state->size = MulDiv(56, dpi ? dpi : 96, 96);
        int center = state->alert.slot.left + (state->alert.slot.right - state->alert.slot.left) / 2;
        state->x = std::clamp<LONG>(center - state->size / 2, monitor.rcMonitor.left,
                            monitor.rcMonitor.right - state->size);
        state->y = monitor.rcMonitor.bottom - state->size - MulDiv(4, dpi ? dpi : 96, 96);
        state->start = now; state->deadline = state->policy.deadline;
        state->lastPositionCheck = now;
        state->showing = true;
        state->frameChecked = false;
        state->renderedFrames=0;
        std::string geometry = "surface x=" + std::to_string(state->x) + " y=" + std::to_string(state->y) +
            " size=" + std::to_string(state->size) + " slot=" + std::to_string(slot.left) + "," + std::to_string(slot.top) + "," +
            std::to_string(slot.right) + "," + std::to_string(slot.bottom) + " monitor=" + std::to_string(monitor.rcMonitor.left) + "," +
            std::to_string(monitor.rcMonitor.top) + "," + std::to_string(monitor.rcMonitor.right) + "," + std::to_string(monitor.rcMonitor.bottom);
        Record(geometry.c_str());
        if (!Render(window, *state, 0, state->size + 6)) { hide(); Record("render-failed"); fallback(); return 0; }
        SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        if (!SetTimer(window,kTimer,16,nullptr)) { hide(); fallback(); return 0; }
        Record("shown-bounded"); return 0;
    }
    if (message == WM_TIMER && wp == kTimer) {
        uint64_t now = GetTickCount64(); MONITORINFO monitor{}; POINT mouse{};
        if (now >= state->deadline || !IsWindow(state->alert.target) ||
            !Hidden(state->alert.taskbar, monitor) ||
            (GetCursorPos(&mouse) && mouse.y >= monitor.rcMonitor.bottom - 8)) {
            hide(); return 0;
        }
        ++state->renderedFrames;
        uint64_t age = now - state->start, left = state->deadline - now;
        if (now - state->lastPositionCheck >= 80) {
            RECT slot{};
            DWORD_PTR result{};
            if (!SendMessageTimeoutW(state->alert.band, g_positionMessage, 0, reinterpret_cast<LPARAM>(state->alert.target),
                    SMTO_ABORTIFHUNG | SMTO_BLOCK, 40, &result) || !result) {
                hide(); Record("button-moved-or-unavailable-stop"); return 0;
            }
            slot.left = static_cast<LONG>(static_cast<uint32_t>(result));
            slot.right = static_cast<LONG>(static_cast<uint32_t>(result >> 32));            if (slot.right <= slot.left || slot.left < monitor.rcMonitor.left || slot.right > monitor.rcMonitor.right) {
                hide(); Record("button-moved-or-unavailable-stop"); return 0;
            }            if (state->x != slot.left + (slot.right - slot.left) / 2 - state->size / 2) Record("button-position-updated");
            state->x = slot.left + (slot.right - slot.left) / 2 - state->size / 2;
            state->lastPositionCheck = now;
        }
        BYTE alpha = static_cast<BYTE>(std::min({uint64_t(255), age * 255 / 80, left * 255 / 60}));
        double lift = age < 120 ? std::pow(1.0 - age / 120.0, 3) : 0;
        if (left < 80) lift = std::pow(1.0 - left / 80.0, 2);
        if (!Render(window, *state, alpha, static_cast<int>((state->size + 6) * lift))) {
            Record("animation-render-failed"); hide();
        } else if (!state->frameChecked && age >= 160) {
            state->frameChecked = true; RECT visible{};
            GetWindowRect(window, &visible);
            DWORD cloaked{};
            HRESULT cloakResult = DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
            std::string frame = "frame visible=" + std::to_string(IsWindowVisible(window)) + " alpha=" + std::to_string(alpha) +
                " rect=" + std::to_string(visible.left) + "," + std::to_string(visible.top) + "," +
                std::to_string(visible.right) + "," + std::to_string(visible.bottom);
            frame += " cloakResult=" + std::to_string(cloakResult) + " cloaked=" + std::to_string(cloaked) + " style=" + std::to_string(GetWindowLongPtrW(window,GWL_EXSTYLE));
            Record(frame.c_str());
        }
        return 0;
    }
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (message == WM_LBUTTONUP) {
        HWND target = state->alert.target; hide();
        if (IsWindow(target)) { ShowWindowAsync(target, SW_RESTORE); SetForegroundWindow(target); }
        return 0;
    }
    if (message == WM_CLOSE) {
        if (state->dispatcher) {
            for (auto& [key, child] : g_componentWindows) SendMessageW(child, WM_CLOSE, 0, 0);
        }
        hide(); DestroyWindow(window); return 0;
    }
    if (message == WM_DESTROY) {
        if (state->icon) { DestroyIcon(state->icon); state->icon = nullptr; }
        if (state->dispatcher) PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wp, lp);
}

DWORD WINAPI PopupThread(void*) {
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW klass{};
    klass.hInstance = g_instance; klass.lpszClassName = kClass;
    klass.lpfnWndProc = PopupProc; klass.hCursor = LoadCursorW(nullptr, IDC_HAND);
    if (!RegisterClassW(&klass)) { SetEvent(g_ready); return 0; }
    PopupState state;
    state.dispatcher = true;
    HWND popup = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
        kClass, L"应用提醒", WS_POPUP, 0, 0, 48, 48, nullptr, nullptr, g_instance, &state);
    g_popup = popup; SetEvent(g_ready);
    if (popup) {
        MSG message{};
        while(GetMessageW(&message,nullptr,0,0)>0) {
            TranslateMessage(&message); DispatchMessageW(&message);
        }
    }
    g_popup = nullptr;
    g_componentWindows.clear(); g_components.clear();
    if (state.icon) DestroyIcon(state.icon);

    UnregisterClassW(kClass, g_instance);
    return 0;
}

LRESULT WINAPI TaskbandHook(void* self, HWND band, UINT message, WPARAM wp, LPARAM lp) {
    if (message == g_positionMessage && lp) {
        HWND target = reinterpret_cast<HWND>(lp); RECT slot{};
        if (g_getIconRect && IsWindow(target)) {
            LRESULT result = g_getIconRect(self, target, &slot);
            if (result == 0 && slot.right > slot.left && slot.bottom > slot.top)
                return static_cast<LRESULT>(static_cast<uint32_t>(slot.left) |
                    (static_cast<uint64_t>(static_cast<uint32_t>(slot.right)) << 32));
        }
        return 0;
    }
    if (message == g_fallbackMessage && IsWindow(reinterpret_cast<HWND>(lp))) {
        Record("native-fallback");
        return g_original(self, band, g_shellMessage, HSHELL_FLASH, lp);
    }

    if (message == g_shellMessage && wp == HSHELL_FLASH) {
        Record("shell-flash-observed");
        if (g_stopping) Record("ignored-during-shutdown");
    }
    if (!g_stopping && message == g_shellMessage && wp == HSHELL_FLASH && g_popup.load()) {
        Alert alert;
        alert.target = reinterpret_cast<HWND>(lp);
        if(ReadAppIdentity(alert.target,g_enableTest,alert.app)) {
            // 本地集成测试使用自己的子窗口，不显示测试浮层或触碰第三方应用。
            bool auxiliaryTest=false;
            if(alert.app.test) {
                if(HWND auxiliary=GetDlgItem(alert.target,71)) { alert.target=auxiliary; auxiliaryTest=true; }
            }
            int length=WideCharToMultiByte(CP_UTF8,0,alert.app.stem.c_str(),-1,nullptr,0,nullptr,nullptr);
            std::string appName(length,'\0');
            WideCharToMultiByte(CP_UTF8,0,alert.app.stem.c_str(),-1,appName.data(),length,nullptr,nullptr);
            Record(("application="+appName).c_str());
            TaskbarMatch matched; TaskbarMatchDiagnostic diagnostic;
            if(!ResolveTaskbarWindow(self,g_getIconRect,alert.target,alert.app,g_enableTest,matched,&diagnostic)) {
                std::string reason="taskbar-match-failed direct="+std::to_string(diagnostic.directResult)+
                    " sameApp="+std::to_string(diagnostic.sameApp)+" validSlots="+std::to_string(diagnostic.validSlots)+
                    " ambiguous="+std::to_string(diagnostic.ambiguous);
                Record(reason.c_str());
                Record("no-taskbar-button-native-fallback");
                return g_original(self,band,message,wp,lp);
            }
            if(matched.window!=alert.target) Record("auxiliary-window-matched-taskbar");
            if(auxiliaryTest) {
                Record(matched.window!=alert.target?"test-auxiliary-match-confirmed":"test-direct-child-match");
                return 0;
            }
            alert.target=matched.window; alert.slot=matched.slot; alert.app=std::move(matched.app);
            alert.band=band;
            Record("app-flash-received");            alert.taskbar = GetAncestor(band, GA_ROOT);
            if (IsWindow(alert.taskbar)) {
                auto* pending = new(std::nothrow) Alert(std::move(alert));
                if (pending) {
                    std::lock_guard lock(g_postMutex);
                    if (!g_stopping && PostMessageW(g_popup.load(), kAlert, 0, reinterpret_cast<LPARAM>(pending))) return 0;
                    delete pending;
                }
            } else {
                // 屏幕定位失败时保留原提醒。
                Record("monitor-unavailable-native-fallback");
            }
        } else { Record("flash-window-app-identity-unavailable"); }
    }
    return g_original(self, band, message, wp, lp);
}
}

BOOL Wh_ModInit() {
    g_stopping = false;
    g_duration = std::clamp(Wh_GetIntSetting(L"duration"), 160, 3000);
    g_diagnostics = Wh_GetIntSetting(L"diagnostics") != 0;
    g_shellMessage = RegisterWindowMessageW(L"SHELLHOOK");
    g_fallbackMessage = RegisterWindowMessageW(L"MinbanMac.QQNotice.NativeFallback.0.1");
    g_positionMessage = RegisterWindowMessageW(L"MinbanMac.Notice.Position.0.2");
    g_enableTest = Wh_GetIntSetting(L"enableTest") != 0;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                      reinterpret_cast<LPCWSTR>(&Wh_ModInit), &g_instance);
    g_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_ready) return FALSE;
    g_thread = CreateThread(nullptr, 0, PopupThread, nullptr, 0, nullptr);
    if (!g_thread || WaitForSingleObject(g_ready, INFINITE) != WAIT_OBJECT_0 || !g_popup.load()) {
        if (g_thread) { WaitForSingleObject(g_thread, INFINITE); CloseHandle(g_thread); g_thread = nullptr; }
        CloseHandle(g_ready); g_ready = nullptr;
        Record("worker-init-failed"); return FALSE;
    }
    HMODULE taskbar = GetModuleHandleW(L"taskbar.dll");
    WindhawkUtils::SYMBOL_HOOK hooks[] = {
      {{L"protected: __int64 __cdecl CTaskBand::_HandleGetTaskbarIconRect(struct HWND__ *,struct tagRECT *)"},
       reinterpret_cast<void**>(&g_getIconRect), nullptr}, {
        {L"protected: virtual __int64 __cdecl CTaskBand::v_WndProc(struct HWND__ *,unsigned int,unsigned __int64,__int64)"},
        reinterpret_cast<void**>(&g_original), reinterpret_cast<void*>(TaskbandHook)
    }};
    if (!taskbar || !WindhawkUtils::HookSymbols(taskbar, hooks, ARRAYSIZE(hooks))) {
        PostMessageW(g_popup.load(), WM_CLOSE, 0, 0);
        WaitForSingleObject(g_thread, INFINITE);
        CloseHandle(g_thread); g_thread = nullptr;
        CloseHandle(g_ready); g_ready = nullptr;
        Record("symbol-hook-failed"); return FALSE;
    }
    Record("ready-0.3.0"); return TRUE;
}

void Wh_ModUninit() {
    { std::lock_guard lock(g_postMutex);
      g_stopping = true;
      if (HWND popup = g_popup.load()) PostMessageW(popup, WM_CLOSE, 0, 0);
    }
    if (g_thread) { WaitForSingleObject(g_thread, INFINITE); CloseHandle(g_thread); g_thread = nullptr; }
    if (g_ready) { CloseHandle(g_ready); g_ready = nullptr; }
    Record("stopped");
}

void Wh_ModSettingsChanged() {
    g_enableTest = Wh_GetIntSetting(L"enableTest") != 0;
    g_duration = std::clamp(Wh_GetIntSetting(L"duration"), 160, 3000);
    g_diagnostics = Wh_GetIntSetting(L"diagnostics") != 0;
}
