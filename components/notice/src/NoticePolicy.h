// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>

// 同一轮闪烁不能延长显示；安静一段时间后才接受下一轮提醒。
struct NoticePolicy {
    bool seen = false;
    uint64_t lastSignal = 0;
    uint64_t deadline = 0;
    bool Signal(uint64_t now, uint32_t duration) {
        bool fresh = !seen || now - lastSignal >= 1800;
        seen = true;
        lastSignal = now;
        if (fresh) deadline = now + duration;
        return fresh;
    }
    bool Expired(uint64_t now) const { return now >= deadline; }
};
