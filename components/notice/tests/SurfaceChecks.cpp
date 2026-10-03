// SPDX-License-Identifier: GPL-3.0-only
#include "NoticeSurface.h"
#include <cstdio>
#include <shellapi.h>
#include <vector>
int wmain(int argc,wchar_t** argv) {
    if(argc<2 || argc>3) return 1;
    HICON icon=LoadIconW(nullptr,IDI_INFORMATION);
    if(argc==3) { icon=nullptr; ExtractIconExW(argv[2],0,&icon,nullptr,1); if(!icon) return 8; }
    constexpr int width=360,height=140;
    std::vector<DWORD> preview(width*height,0xFFFFFFFF);
    HDC screen=GetDC(nullptr),dc=CreateCompatibleDC(screen);
    int offset=12, checks=0;
    for(int size : {56,70,84,112}) {
        BITMAPINFO info{}; info.bmiHeader={sizeof(BITMAPINFOHEADER),size,-size,1,32,BI_RGB};
        DWORD* pixels{};
        HBITMAP bmp=CreateDIBSection(screen,&info,DIB_RGB_COLORS,reinterpret_cast<void**>(&pixels),nullptr,0);
        if(!bmp) return 2;
        auto previous=SelectObject(dc,bmp);
        if(!PaintNoticeSurface(dc,pixels,size,icon)) return 3;
        for(int x=0;x<size;++x) if(pixels[x] || pixels[(size-1)*size+x]) return 4;
        for(int y=0;y<size;++y) if(pixels[y*size] || pixels[y*size+size-1]) return 5;
        for(int y=0;y<size;++y) for(int x=0;x<size;++x) {
            auto mask=NoticeMask(size,x,y);
            DWORD p=pixels[y*size+x];
            if(mask.stroke>0 && p!=NoticeFramePixel(mask)) return 6;
            unsigned a=p>>24,r=(p>>16)&255,g=(p>>8)&255,b=p&255;
            // 合成到白色背景，仅用于检查本组件自己的画面。
            preview[(y+12)*width+x+offset]=0xFF000000 | (std::min(255u,r+255-a)<<16) |
                (std::min(255u,g+255-a)<<8) | std::min(255u,b+255-a);
        }
        SelectObject(dc,previous); DeleteObject(bmp); offset+=size+6; ++checks;
    }
    DeleteDC(dc); ReleaseDC(nullptr,screen);
    BITMAPFILEHEADER file{}; file.bfType=0x4D42; file.bfOffBits=sizeof(file)+sizeof(BITMAPINFOHEADER);
    file.bfSize=file.bfOffBits+preview.size()*sizeof(DWORD);
    BITMAPINFOHEADER info{sizeof(info),width,-height,1,32,BI_RGB};
    FILE* out=_wfopen(argv[1],L"wb"); if(!out) return 7;
    fwrite(&file,sizeof(file),1,out); fwrite(&info,sizeof(info),1,out);
    fwrite(preview.data(),sizeof(DWORD),preview.size(),out); fclose(out);
    std::printf("Passed border checks at %d DPI scales; generated component preview.\n",checks);
}