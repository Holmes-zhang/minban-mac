// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <windows.h>
#include <algorithm>
#include <cmath>

struct SurfaceMask { double coverage, stroke; };
inline SurfaceMask NoticeMask(int size, int x, int y) {
    double scale = size / 56.0;
    double margin = 2 * scale, radius = 20 * scale;
    double dx = std::max({margin + radius - x, x - (size - 1 - margin - radius), 0.0});
    double dy = std::max({margin + radius - y, y - (size - 1 - margin - radius), 0.0});
    double distance = std::sqrt(dx * dx + dy * dy) - radius;
    return {std::clamp(.5 - distance,0.0,1.0), std::clamp(distance + 1.25 * scale + .5,0.0,1.0)};
}
inline DWORD NoticeFramePixel(SurfaceMask mask) {
    unsigned a = static_cast<unsigned>(255 * mask.coverage);
    unsigned r = static_cast<unsigned>((216 + 35 * mask.stroke) * mask.coverage);
    unsigned g = static_cast<unsigned>((238 + 15 * mask.stroke) * mask.coverage);
    unsigned b = static_cast<unsigned>((234 + 19 * mask.stroke) * mask.coverage);
    return (a << 24) | (r << 16) | (g << 8) | b;
}
inline bool PaintNoticeSurface(HDC dc, DWORD* bits, int size, HICON icon) {
    // 画布四周保留透明边缘，避免把圆角的抗锯齿边界裁在窗口外。
    for(int y=0;y<size;++y) for(int x=0;x<size;++x)
        bits[y*size+x] = NoticeFramePixel(NoticeMask(size,x,y));
    int iconSize = MulDiv(32,size,56), inset=(size-iconSize)/2;
    if(!DrawIconEx(dc,inset,inset,icon,iconSize,iconSize,0,nullptr,DI_NORMAL)) return false;
    // CPU 访问 DIB 前等 GDI 完成；随后补回 alpha，最后再描边。
    if(!GdiFlush()) return false;
    for(int y=0;y<size;++y) for(int x=0;x<size;++x) {
        auto mask=NoticeMask(size,x,y);
        auto& pixel=bits[y*size+x];
        if(mask.coverage < 1 || mask.stroke > 0) pixel=NoticeFramePixel(mask);
        else pixel=(pixel & 0x00FFFFFF) | 0xFF000000;
    }
    return true;
}