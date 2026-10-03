// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "AppIdentity.h"
#include <vector>

using TaskbarIconRectQuery=LRESULT(__cdecl*)(void*,HWND,RECT*);
struct TaskbarMatch { HWND window{}; RECT slot{}; AppIdentity app; int score{}; };
struct TaskbarMatchDiagnostic { LRESULT directResult{}; int sameApp{}, validSlots{}; bool ambiguous{}; };
inline bool ValidTaskbarSlot(RECT slot) { return slot.right>slot.left && slot.bottom>slot.top; }
inline bool ResolveTaskbarWindow(void* self,TaskbarIconRectQuery query,HWND request,
                                 const AppIdentity& origin,bool enableTest,TaskbarMatch& match,TaskbarMatchDiagnostic* diagnostic=nullptr) {
    RECT direct{};
    LRESULT directResult=query(self,request,&direct);
    if(diagnostic) { *diagnostic={}; diagnostic->directResult=directResult; }
    if(directResult==0 && ValidTaskbarSlot(direct)) {
        match={request,direct,origin,100}; return true;
    }
    DWORD originPid{}; GetWindowThreadProcessId(request,&originPid);
    struct Search {
        void* self; TaskbarIconRectQuery query; HWND request; const AppIdentity& origin;
        bool enableTest; DWORD originPid; TaskbarMatchDiagnostic* diagnostic; std::vector<TaskbarMatch> matches;
    } search{self,query,request,origin,enableTest,originPid,diagnostic,{}};
    // 提醒可由辅助窗口发出。只匹配同一程序，而且必须能查询到真实任务栏按钮。
    EnumWindows([](HWND candidate,LPARAM parameter)->BOOL {
        auto& search=*reinterpret_cast<Search*>(parameter);
        if(candidate==search.request) return TRUE;
        DWORD pid{}; GetWindowThreadProcessId(candidate,&pid);
        HANDLE process=pid?OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid):nullptr;
        if(!process) return TRUE;
        wchar_t path[32768]; DWORD length=ARRAYSIZE(path);
        bool ok=QueryFullProcessImageNameW(process,0,path,&length);
        CloseHandle(process);
        if(!ok || Fold(std::wstring(path,length))!=Fold(search.origin.path)) return TRUE;
        if(search.diagnostic) ++search.diagnostic->sameApp;
        RECT slot{};
        if(search.query(search.self,candidate,&slot)!=0 || !ValidTaskbarSlot(slot)) return TRUE;
        if(search.diagnostic) ++search.diagnostic->validSlots;
        AppIdentity app;
        if(!ReadAppIdentity(candidate,search.enableTest,app)) return TRUE;
        int score=pid==search.originPid?2:0;
        if(!search.origin.appId.empty() && search.origin.appId==app.appId) score+=4;
        for(auto& found:search.matches) {
            if(found.slot.left==slot.left && found.slot.right==slot.right && found.slot.top==slot.top) {
                if(score>found.score) found={candidate,slot,std::move(app),score};
                return TRUE;
            }
        }
        search.matches.push_back({candidate,slot,std::move(app),score});
        return TRUE;
    },reinterpret_cast<LPARAM>(&search));
    if(search.matches.empty()) return false;
    int best=-1; bool ambiguous=false;
    for(size_t i=0;i<search.matches.size();++i) {
        if(best<0 || search.matches[i].score>search.matches[best].score) {best=i;ambiguous=false;}
        else if(search.matches[i].score==search.matches[best].score) ambiguous=true;
    }
    // 多账户或未合并的窗口无法区分时不猜位置。
    if(diagnostic) diagnostic->ambiguous=ambiguous;
    if(ambiguous) return false;
    match=std::move(search.matches[best]); return true;
}