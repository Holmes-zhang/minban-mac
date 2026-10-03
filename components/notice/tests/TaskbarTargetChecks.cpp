// SPDX-License-Identifier: GPL-3.0-only
#include "TaskbarTarget.h"
#include <unordered_map>
#include <cstdio>

// 只创建不显示的测试窗口，用模拟布局查询验证匹配规则。
std::unordered_map<HWND,RECT> slots;
LRESULT Query(void*,HWND window,RECT* result) {
    if(!slots.contains(window)) return 1;
    *result=slots[window]; return 0;
}
int main() {
    CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    HWND first=CreateWindowExW(0,L"STATIC",L"",WS_POPUP,0,0,1,1,nullptr,nullptr,nullptr,nullptr);
    HWND second=CreateWindowExW(0,L"STATIC",L"",WS_POPUP,0,0,1,1,nullptr,nullptr,nullptr,nullptr);
    HWND auxiliary=CreateWindowExW(0,L"STATIC",L"",WS_CHILD,0,0,1,1,first,nullptr,nullptr,nullptr);
    if(!first || !second || !auxiliary) return 1;
    AppIdentity origin; if(!ReadAppIdentity(auxiliary,false,origin)) return 2;
    int checks=0;
    auto check=[&](bool condition,const char* description) {
        if(!condition) {std::fprintf(stderr,"FAILED: %s\n",description);return false;}
        ++checks;return true;
    };
    TaskbarMatch match; TaskbarMatchDiagnostic diagnostic;
    slots[first]={100,1598,166,1670};
    if(!check(ResolveTaskbarWindow(nullptr,Query,first,origin,false,match) && match.window==first,"direct window")) return 3;
    if(!check(ResolveTaskbarWindow(nullptr,Query,auxiliary,origin,false,match,&diagnostic) && match.window==first,"auxiliary maps to real button")) return 3;
    if(!check(diagnostic.directResult==1 && diagnostic.validSlots==1,"diagnostic tracks failed direct lookup")) return 3;
    slots[second]={200,1598,266,1670};
    if(!check(!ResolveTaskbarWindow(nullptr,Query,auxiliary,origin,false,match,&diagnostic) && diagnostic.ambiguous,"different buttons cannot be guessed")) return 3;
    slots[second]=slots[first];
    if(!check(ResolveTaskbarWindow(nullptr,Query,auxiliary,origin,false,match),"grouped windows share one button")) return 3;
    slots.clear();
    if(!check(!ResolveTaskbarWindow(nullptr,Query,auxiliary,origin,false,match),"background without button ignored")) return 3;
    DestroyWindow(second);DestroyWindow(first);CoUninitialize();
    std::printf("Passed %d taskbar target checks\n",checks);
}
