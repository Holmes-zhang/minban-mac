// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <windows.h>
#include <shobjidl.h>
#include <propkey.h>
#include <string>
#include <algorithm>

struct AppIdentity {
    std::wstring path, appId, stem;
    bool test{};
};
inline std::wstring Fold(std::wstring text) {
    std::transform(text.begin(), text.end(), text.begin(), towlower);
    return text;
}
inline bool ReadAppIdentity(HWND window, bool enableTest, AppIdentity& app) {
    // 是否位于任务栏由原生图标布局查询确认，不用窗口显隐代替。
    if (!IsWindow(window)) return false;
    DWORD pid{}; GetWindowThreadProcessId(window, &pid);
    HANDLE process = pid ? OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) : nullptr;
    if (!process) return false;
    wchar_t buffer[32768]; DWORD size = ARRAYSIZE(buffer);
    bool ok = QueryFullProcessImageNameW(process, 0, buffer, &size);
    CloseHandle(process);
    if (!ok) return false;
    app.path.assign(buffer, size);
    auto separator = app.path.find_last_of(L'\\');
    auto filename = Fold(app.path.substr(separator == std::wstring::npos ? 0 : separator + 1));
    app.stem = filename.substr(0, filename.find_last_of(L'.'));
    app.test = filename.starts_with(L"minban-notice-test");
    if (app.test && !enableTest) return false;
    IPropertyStore* store{};
    if (SUCCEEDED(SHGetPropertyStoreForWindow(window, __uuidof(IPropertyStore), reinterpret_cast<void**>(&store))) && store) {
        PROPVARIANT value{};
        if (SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID, &value)) && value.vt == VT_LPWSTR && value.pwszVal)
            app.appId = Fold(value.pwszVal);
        PropVariantClear(&value); store->Release();
    }
    return true;
}
