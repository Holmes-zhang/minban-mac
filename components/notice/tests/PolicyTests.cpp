// SPDX-License-Identifier: GPL-3.0-only
#include "NoticePolicy.h"
#include <cstdio>

int main() {
    int checks = 0;
    auto check = [&](bool ok, const char* message) { if (!ok) { std::fprintf(stderr, "%s\n", message); return false; } ++checks; return true; };
    NoticePolicy policy;
    if (!check(policy.Signal(0,800), "first signal missing")) return 1;
    if (!check(!policy.Signal(500,800), "repeat extended reminder")) return 1;
    if (!check(policy.deadline == 800, "repeat changed deadline")) return 1;
    if (!check(!policy.Expired(799) && policy.Expired(800), "deadline boundary")) return 1;
    if (!check(!policy.Signal(1000,800), "flash burst accepted")) return 1;
    if (!check(policy.Signal(3000,800) && policy.deadline == 3800, "next independent message lost")) return 1;
    if (!check(!policy.Signal(3300,800) && policy.deadline == 3800, "next message repeat extends")) return 1;
    NoticePolicy later;
    const uint64_t base = uint64_t(1) << 40;
    if (!check(later.Signal(base,800) && later.Expired(base+800), "long-running clock overflow")) return 1;
    std::printf("Passed %d reminder policy checks\n", checks);
}
