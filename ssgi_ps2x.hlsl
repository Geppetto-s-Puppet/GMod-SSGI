// ssgi_ps20b.hlsl
// _rt_WPDepth:              .RGB = 1/WorldPos,  .A = Depth (deferred G-buffer)
// _rt_NormalsTangents:      .RG  = Normals,     .B  = Tangents, .A = flipSign
// _rt_ResolvedFullFrameDepth: .R = actual depth (post-viewmodel)
// c0: .x = intensity   .y = radius (UV空間)
// c1: .x = debug_mode  (0=通常  1=GIのみ  2=法線  3=geo範囲  4=depth差分)

sampler s0 : register(s0); // _rt_FullFrameFB
sampler s1 : register(s1); // _rt_WPDepth
sampler s2 : register(s2); // _rt_NormalsTangents
sampler s3 : register(s3); // _rt_ResolvedFullFrameDepth

float4 c0 : register(c0);
float4 c1 : register(c1);


// Octahedron Normal Decoding (公式)
float3 Decode(float2 f)
{
    f = f * 2.0 - 1.0;
    float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = saturate(-n.z);
    n.xy += n.xy >= 0.0 ? -t : t;
    return normalize(n);
}

float3 GISample(float2 suv, float3 ppos, float3 N)
{
    float4 swpd   = tex2D(s1, suv);
    float3 scolor = tex2D(s0, suv).rgb;

    float  valid = (dot(swpd.rgb, swpd.rgb) > 0.00001) ? 1.0 : 0.0;

    // [FIX] + 0.0001 オフセット廃止: スカイはdummyで除算、validで無効化
    float3 safe = lerp(float3(1.0, 1.0, 1.0), swpd.rgb, valid);
    float3 spos = 1.0 / safe;

    float3 diff  = spos - ppos;
    float  dist  = length(diff) + 0.001;
    float  NdotL = max(0.0, dot(N, diff / dist));
    float  atten = 1.0 / (1.0 + dist * dist * 0.001);

    return scolor * NdotL * atten * valid;
}

float4 main(float2 tex : TEXCOORD0) : COLOR
{
    float4 wpd  = tex2D(s1, tex);
    float3 base = tex2D(s0, tex).rgb;
    float4 nrm  = tex2D(s2, tex);

    // ---- ビューモデル検出 ----------------------------------------
    // _rt_WPDepth.a   = デファードGバッファの深度（腕の後ろの壁）
    // _rt_ResolvedFullFrameDepth.r = ビューモデル描画後の実深度
    // ビューモデルピクセルは実深度 << Gバッファ深度 になる
    float gbufDepth  = wpd.a;
    float realDepth  = tex2D(s3, tex).r;
    // 差が threshold 以上なら「Gバッファと実描画が乖離している = ビューモデル」
    // ※ threshold は深度エンコード形式に依存して要調整 (初期値 0.02)
    float depthDiff  = gbufDepth - realDepth;
    float isViewmodel = step(0.02, depthDiff);
    // ---------------------------------------------------------------

    // geo: スカイ判定 AND ビューモデルでない
    float geo = (dot(wpd.rgb, wpd.rgb) > 0.00001) ? 1.0 : 0.0;
    geo *= (1.0 - isViewmodel);

    float3 N = Decode(nrm.xy);

    // [FIX] ppos も safe除算
    float3 safe_wpd = lerp(float3(1.0, 1.0, 1.0), wpd.rgb, geo);
    float3 ppos     = 1.0 / safe_wpd;

    float r = c0.y;

    float3 gi = float3(0.0, 0.0, 0.0);
    gi += GISample(tex + float2( r * 0.5,  0.0    ), ppos, N);
    gi += GISample(tex + float2( r,        0.0    ), ppos, N);
    gi += GISample(tex + float2( 0.0,      r * 0.5), ppos, N);
    gi += GISample(tex + float2( 0.0,      r      ), ppos, N);
    gi += GISample(tex + float2(-r * 0.5,  0.0    ), ppos, N);
    gi += GISample(tex + float2(-r,        0.0    ), ppos, N);
    gi += GISample(tex + float2( 0.0,     -r * 0.5), ppos, N);
    gi += GISample(tex + float2( 0.0,     -r      ), ppos, N);
    gi /= 8.0;

    float3 out0 = lerp(base, base + gi * c0.x, geo); // 通常
    float3 out1 = gi * c0.x * 5.0 * geo;              // GI層
    float3 out2 = (N * 0.5 + 0.5) * geo;              // 法線
    float3 out3 = float3(geo, geo, geo);               // geo範囲
    // デバッグ4: depthDiff の可視化（閾値チューニング用）
    float3 out4 = float3(saturate(depthDiff * 10.0), 0.0, isViewmodel);

    float dm = c1.x;
    float m0 =        (1.0 - step(0.5, dm));
    float m1 = step(0.5, dm) * (1.0 - step(1.5, dm));
    float m2 = step(1.5, dm) * (1.0 - step(2.5, dm));
    float m3 = step(2.5, dm) * (1.0 - step(3.5, dm));
    float m4 = step(3.5, dm);

    float3 result = out0*m0 + out1*m1 + out2*m2 + out3*m3 + out4*m4;
    return float4(result, 1.0);
}