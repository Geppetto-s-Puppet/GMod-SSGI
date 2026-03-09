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
![Image](https://github.com/user-attachments/assets/5b9582e1-0932-4fe2-b9eb-5f42264dfd4a)
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
![Image](https://github.com/user-attachments/assets/1e0d15b4-e987-453b-8282-b77adeed5501)

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

あとさ、`ps20b`をやめて`ps30`を使うわ。命名規則も統一した。下記は、Akabenko氏に提供されたコード本体。
```hlsl
// ssgi21_ps30.hlsl
#include "common_ps_bayer.h"
#include "common_octahedron_encoding.h"
#include "common_diamond_encoding.h"
#include "common_ps_fxc.h"

sampler FrameBuffer           	: register( s0 );
sampler WPDepthBuffer           : register( s1 );
sampler NormalTangentBuffer     : register( s2 );
sampler BlueNoiseSampler        : register( s3 );

const float4 Constant0			: register( c0 );
const float4 Constant1			: register( c1 );
const float4 Constant2			: register( c2 );
const float4 Constant3			: register( c3 );
const float2 TexBaseSize        : register( c4 );
const float2 TileSize           : register( c7 );

const float4x4 ViewProj         : register( c11 );

struct PS_IN
{
    float2 pos                      : VPOS;
    float2 uv                : TEXCOORD0;
};

static const int samples = 16;
static const float TAU = 6.28318530718;
static const float PI = 3.1415925;
static const float PI2 = PI * 2;
#define intens          Constant0.x
#define stepSize        Constant0.w
#define stepFalloff     Constant1.w
#define depthThreshold  Constant2.w
#define scale           Constant2.x
#define minRayDistance Constant2.y

float3 generateHemisphereRay(float3x3 TBN, float2 noise) {
    float phi = PI2 * noise.x;
    float cosTheta = sqrt(1 - noise.y);
    float sinTheta = sqrt(1 - cosTheta * cosTheta);
    
    float3 localDir = float3(
        sinTheta * cos(phi),
        sinTheta * sin(phi),
        cosTheta
    );
    
    return mul(localDir, TBN);
}

float4 main(PS_IN input) : COLOR0 {
    float2 uv = input.uv;
    float4 wpdepth = tex2D(WPDepthBuffer, uv);
    float depth = wpdepth.a;

    if (depth == 0.00025) discard;

    float3 worldPos = 1/wpdepth.xyz;

    float4 normals_tangets = tex2D(NormalTangentBuffer,uv);
    float flipSign = normals_tangets.a;
    float3 worldNormal = Decode(normals_tangets.xy);
    float3 tangents = decode_tangent(worldNormal, normals_tangets.z);
    float3 binormals = normalize(cross(worldNormal,tangents)) * flipSign;
    float3x3 TBN = float3x3(tangents, binormals, worldNormal);

    
    float2 blueNoise = tex2D(BlueNoiseSampler, input.pos * TexBaseSize / TileSize * scale).ar;
    //return float4(blueNoise,0,1);
    float3 rayDir = generateHemisphereRay(TBN, blueNoise);

    float3 accumulatedColor = 0;
    float3 rayPos = worldPos;

    [loop]
    for(int i = 0; i < samples; i++) {
        rayPos += rayDir * stepSize;
        
        float4 projPos = mul(float4(rayPos, 1), ViewProj);
        float2 sampleTexCoord = projPos.xy / projPos.w * 0.5 + 0.5;
        
        if(dot(sampleTexCoord - saturate(sampleTexCoord), 1.0) != 0.0) break;
        
        float sampleDepth = tex2Dlod(WPDepthBuffer, float4(sampleTexCoord,0,0)).a;
        if (sampleDepth == 0.00025) continue;

        float rayLength = length(rayPos - worldPos);
        if(rayLength < minRayDistance) continue;

        if(abs(depth - sampleDepth) < depthThreshold) {
            float3 sampleColor = tex2Dlod(FrameBuffer, float4(sampleTexCoord,0,0)).rgb;
            float3 sampleNormal = Decode(tex2Dlod(NormalTangentBuffer, float4(sampleTexCoord,0,0)).xy);
            
            float NdotRay = max(0, dot(sampleNormal, -rayDir));
            accumulatedColor += sampleColor * NdotRay * stepFalloff;
            //break;
        }
    }
    
    return float4(accumulatedColor * intens, depth);
}
```
```hlsl
// ssgi_filter9_ps30.hlsl
// Bilateral Filter

#include "common_ps_bayer.h"
#include "common_octahedron_encoding.h"
#include "common_diamond_encoding.h"
#include "common_ps_fxc.h"
sampler colorMap    : register( s0 );
sampler posMap : register( s1 );
sampler normalMap : register( s2 );

const float4 Constant0			: register( c0 );
const float4 Constant1			: register( c1 );
const float4 Constant2			: register( c2 );
const float4 Constant3			: register( c3 );
//const float2 TexSize			: register( c4 );

#define c_phi Constant0.x
#define n_phi Constant0.y
#define p_phi Constant0.z
#define stepwidth Constant0.w
#define stepwidth2 Constant1.x

//#define step Constant3.xy

#define size 1 / ( float2(1920,1080) * 0.5 )

// Гауссово ядро 7x7 (sigma = 1.5) - сумма всех значений = 1.0
static const float kernel[49] = {
    0.000036, 0.000363, 0.001446, 0.002897, 0.001446, 0.000363, 0.000036,
    0.000363, 0.003676, 0.014662, 0.029352, 0.014662, 0.003676, 0.000363,
    0.001446, 0.014662, 0.058488, 0.117129, 0.058488, 0.014662, 0.001446,
    0.002897, 0.029352, 0.117129, 0.234572, 0.117129, 0.029352, 0.002897,
    0.001446, 0.014662, 0.058488, 0.117129, 0.058488, 0.014662, 0.001446,
    0.000363, 0.003676, 0.014662, 0.029352, 0.014662, 0.003676, 0.000363,
    0.000036, 0.000363, 0.001446, 0.002897, 0.001446, 0.000363, 0.000036
};

// Смещения для 7x7 окрестности (от -3 до +3 по X и Y)
static const float2 offset[49] = {
    float2(-3, -3), float2(-2, -3), float2(-1, -3), float2(0, -3), float2(1, -3), float2(2, -3), float2(3, -3),
    float2(-3, -2), float2(-2, -2), float2(-1, -2), float2(0, -2), float2(1, -2), float2(2, -2), float2(3, -2),
    float2(-3, -1), float2(-2, -1), float2(-1, -1), float2(0, -1), float2(1, -1), float2(2, -1), float2(3, -1),
    float2(-3,  0), float2(-2,  0), float2(-1,  0), float2(0,  0), float2(1,  0), float2(2,  0), float2(3,  0),
    float2(-3,  1), float2(-2,  1), float2(-1,  1), float2(0,  1), float2(1,  1), float2(2,  1), float2(3,  1),
    float2(-3,  2), float2(-2,  2), float2(-1,  2), float2(0,  2), float2(1,  2), float2(2,  2), float2(3,  2),
    float2(-3,  3), float2(-2,  3), float2(-1,  3), float2(0,  3), float2(1,  3), float2(2,  3), float2(3,  3)
};

struct PS_IN
{
    float2 P                : VPOS;
    float2 vTexCoord        : TEXCOORD0;
};

half4 main(PS_IN i ) : COLOR
{   
    float2 texCoord = i.vTexCoord;

    half3 sum = 0;
	float2 step = size; // resolution
	half3 cval = tex2D(colorMap, texCoord).rgb;
	half3 nval = Decode(tex2D(normalMap, texCoord).xy);

	float4 wpdepth = tex2D(posMap, texCoord);
	float depth = wpdepth.a;

	if (depth < 0.00001) discard;
	float3 pval = 1/wpdepth.xyz;

	//float dither = bayer16(i.P);
	//dither = 1;

	float cum_w = 0.0;

	[loop]
	for(int i = 0; i < 22; i++) { // 25
		float4 uv = float4( texCoord + offset[i]*step*stepwidth, 0, 0);
		half3 ctmp = tex2Dlod(colorMap, uv).rgb;
		float3 t = cval - ctmp;
		float dist2 = dot(t,t);
		float c_w = min(exp(-(dist2) * c_phi), 1);
		half3 ntmp = Decode(tex2Dlod(normalMap, uv).xy);
		t = nval - ntmp;
		dist2 = max( dot(t,t) * stepwidth2, 0);
		float n_w = min(exp(-(dist2) * n_phi), 1);
		float3 ptmp = 1/tex2Dlod(posMap, uv).xyz;
		t = pval - ptmp;
		dist2 = dot(t,t);
		float p_w = min(exp(-(dist2) * p_phi),1);
		float weight = c_w * n_w * p_w;
		sum += ctmp * weight * kernel[i];
		cum_w += weight*kernel[i];
	}
	
	return half4(sum/cum_w, depth);
}
```











also make discard by sky 
理想は解像度を1/8にすることだが、アップスケーリングの手法が未知なため後回し。
if tex2D(WPDepth, uv).a == 0.00025 discard;

