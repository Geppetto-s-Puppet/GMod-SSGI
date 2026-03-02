# Screen Space Global Illumination (SSGI) for Garry's Mod
A real-time post-processing addon implementing **SSGI** in Garry's Mod using:
- [Visibility Bitmask](https://arxiv.org/pdf/2301.11376) (Therrien et al., 2023) for horizon-based indirect lighting  
- [Edge-Avoiding À-Trous Wavelet Transform](https://jo.dreggn.org/home/2010_atrous.pdf) (Dammertz et al., 2010) as denoiser

### Requirements
- [Garry's Mod](https://steamcommunity.com/app/4000) — Use the `x86-64 Chromium + 64-bit binaries` version.
- [GShader Library](https://github.com/Akabenko/GShader-library) — Deferred rendering foundation with efficient G-Buffer access.
- [NikNaks](https://github.com/Nak2/NikNaks) — Utilities including BitBuffer, BSP parser, BSP objects, PVS/PAS, and more.

### Quick Setup
Subscribe/clone the dependencies, drop this addon in `garrysmod/addons/`, enable in menu, and enjoy improved lighting!















Source Engine Shader SDK: https://github.com/ficool2/sdk_screenspace_shaders

### Papers
- https://knarkowicz.wordpress.com/2014/04/16/octahedron-normal-vector-encoding/














１．を用いて、下記のバッファを取得し、圧縮方法を調査する。
- **_rt_NormalsTangents** — `.RG` Normals, `.B` Tangents, `.A` Sign
- **_rt_WPDepth** — a
- **_rt_Bumps** — a
- **_rt_FullFrameFB** — a

２．





u should downsample SSGI
native render of SSGI will kill FPS
u can render it in 0.5 size rendertarget
u can make RGBA16161616F rendertarget
RGB will be color, Alpha will be depth from WPDepth
its better to use RGBA8888. and pack depth .as GBA. but this is good for SSAO. and grey scale result
so SSGI have colors

thats why we cant use RGBA8888 with packing depth
thats why u can use RGBA16F as me
i use it for SSAO, SSSS, Volumetric light
u can make upsampling from 0.25
but code will be huge. and i dont know how to make it

like 0.25 upsampling need more taps
and more logic

u can try 0.5 as start. thats why it works. and u has a code
just a bayer. maybe it useful for SSGI. but i think here should be other dithering. idk
u use bayer for Volumetirc light, ssao, ssss 
then i use filtering

so
render SSAO using dithering,
vertical pass filter,
horizontal pass filter,
upsampling pass
also make discard by sky
if tex2D(WPDepth, uv).a == 0.00025 discard;


ps this is implementation of LVutner's code from DX10/DX11 to DX9. LVutner is a S.T.A.L.K.E.R Anomaly developer