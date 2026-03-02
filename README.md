# Screen Space Global Illumination (SSGI) for Garry's Mod
A real-time post-processing addon implementing **SSGI** in Garry's Mod using:
* [Visibility Bitmask](https://arxiv.org/pdf/2301.11376) (Therrien et al., 2023) for horizon-based indirect lighting  
* [Edge-Avoiding À-Trous Wavelet Transform](https://jo.dreggn.org/home/2010_atrous.pdf) (Dammertz et al., 2010) as denoiser

### Requirements
- [Garry's Mod](https://steamcommunity.com/app/4000) — Use the `x86-64 Chromium + 64-bit binaries` version.
- [GShader Library](https://github.com/Akabenko/GShader-library) — Deferred rendering foundation with efficient G-Buffer access.
- [NikNaks](https://github.com/Nak2/NikNaks) — Utilities including BitBuffer, BSP parser, BSP objects, PVS/PAS, and more.

### Quick Setup
Subscribe/clone the dependencies, drop this addon in `garrysmod/addons/`, enable in menu, and enjoy improved lighting!

### Special Thanks to:
* **Evgeny Akabenko** (GShader Library developer) — For providing almost all the valuable information
* **LVutner** (S.T.A.L.K.E.R. Anomaly developer) — For the 0.5 upsampling code ported from DX10/DX11 to DX9
* **ficool2** (Source Shader SDK developer) — For the compiler and bin files (which are mixed into this repo)

# 以下：俺用メモ（他人に読ます気ない）
まずライブラリにどんなレンダーターゲットが含まれてるかっていうと、
| バッファ名 | チャンネル／内容／エンコード |
|---|---|
| _rt_NormalsTangents | `.RG` 法線（オクタヘドロン符号化）　`.B` 接線（ダイヤモンド符号化）、`.A` 符号（右手系か否か） |
| _rt_WPDepth | `.RGB` ワールド座標の逆数　`.A` 線形深度 |
| _rt_Bumps | `.RGB` バンプマップ　`.A` スペキュラマスク |
| _rt_FullFrameFB | ふっつーに入力として使うGMOD画面の入力（デフォのMSAAをオフっとけ、SMAAかFXAA推奨） |

このうち、SSGIを構成するために最低限必要となるものは、
| バッファ名 | vmtパラメータ | レジスタ番号 | 用途 |
|---|---|---|---|
| `_rt_FullFrameFB` | `$basetexture` | `s0` | 間接光の光源色サンプリング用 |
| `_rt_WPDepth` | `$texture1` | `s1` | ワールド座標の復元 + スカイ判定用 |
| `_rt_NormalsTangents` | `$texture2` | `s2` | ホライゾン積分の基準となる法線用 |

ついでに、いったん素直にデコードしてみて、どんな画像になってるか目視でチェックしとく。
```hlsl
#include "common.hlsl"

float3 DecodeNormal(float2 f)
{
    f = f * 2.0 - 1.0;
    float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = saturate(-n.z);
    n.xy += n.xy >= 0.0 ? -t : t;
    return normalize(n);
}

float4 main(PS_INPUT I) : COLOR
{
    float3 N = DecodeNormal(tex2D(Tex2, I.uv).rg);
    return float4(N * 0.5 + 0.5, 1.0);  // 法線を色として表示
}
```
![screenshot](img\DecodeNormal.jpg)
```hlsl
#include "common.hlsl"

float4 main(PS_INPUT I) : COLOR
{
    float4 wpd       = tex2D(Tex1, I.uv);
    float3 world_pos = 1.0 / wpd.xyz;   // ライブラリと同じ
    float  depth     = wpd.a;

    // depthをそのまま灰色で表示するだけ
    return float4(depth, depth, depth, 1.0);
}
```
![screenshot](img\DecodeDepth.jpg)

ぶっちゃけSSAOなら(影は0～1で収まるため)RGBA8888で十分だが、SSGIなら多少重くてもRGBA16161616Fのテクスチャフォーマットを使うべき。
```lua
-- 解像度を1/4（縦横0.5倍）にすることで、VRAMくんが酷い目にあわなくなる
local ssgi_rt = GetRenderTargetEx("_rt_SSGI", ScrW()*0.5,ScrH()*0.5,
    RT_SIZE_LITERAL,
    MATERIAL_RT_DEPTH_NONE,
    bit.bor(4,8,16,256,512,8388608),
    0,
    IMAGE_FORMAT_RGBA16161616F
)
```

RTに貯めず直接描いちゃうと「元画像 + ずれたサンプル」がスクリーンに乗って輪郭だけ浮いて見えてしまうので、これで対策する。
```lua
local function Draw()
    render.PushRenderTarget(ssgi_rt)
    render.Clear(0,0,0,0)
    render.SetMaterial(ssgi_mat)
    render.DrawScreenQuad()
    render.PopRenderTarget()
-- 合成用シェーダーはssgi_composite_ps20b.hlsl
    render.SetMaterial(ssgi_composite)
    render.DrawScreenQuad()
end
```












also make discard by sky 
理想は解像度を1/8にすることだが、アップスケーリングの手法が未知なため後回し。
if tex2D(WPDepth, uv).a == 0.00025 discard;

