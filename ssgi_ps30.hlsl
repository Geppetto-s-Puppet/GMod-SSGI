#include "common.hlsl"

// TexBase (s0): _rt_FullFrameFB
// Tex1    (s1): _rt_WPDepth
// Tex2    (s2): _rt_NormalsTangents
//
// Constants0.x ($c0_x): サンプル半径
// Constants0.y ($c0_y): 深度バイアス
// Constants1.x ($c1_x): デバッグモード

#define NUM_DIRECTIONS  4
#define NUM_STEPS       3
#define PI              3.14159265358979

float3 DecodeNormal(float2 f)
{
    f = f * 2.0 - 1.0;
    float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = saturate(-n.z);
    n.xy += n.xy >= 0.0 ? -t : t;
    return normalize(n);
}

float IGNoise(float2 uv)
{
    return frac(52.9829189 * frac(dot(uv, float2(173.7316, 227.4519))));
}

float4 main(PS_INPUT I) : COLOR
{
    float4 wpd   = tex2D(Tex1, I.uv);
    float  depth = wpd.a;

    if (depth >= 1.0 || dot(wpd.rgb, wpd.rgb) < 1e-5)
        return float4(0, 0, 0, 1);

    float3 P         = 1.0 / wpd.xyz;
    float3 N         = DecodeNormal(tex2D(Tex2, I.uv).rg);
    float  noise     = IGNoise(I.uv);
    float  radius    = Constants0.x;
    float  depthBias = Constants0.y;

    float3 gi_accum = 0;

    [unroll(4)]
    for (int d = 0; d < NUM_DIRECTIONS; d++)
    {
        float  phi  = ((float)d + noise) * (PI / (float)NUM_DIRECTIONS);
        float2 dir  = float2(cos(phi), sin(phi));

        float max_horizon = -1.0;

        [unroll(3)]
        for (int s = 1; s <= NUM_STEPS; s++)
        {
            float  t    = (float)s / (float)NUM_STEPS;
            float2 uv_s = I.uv + dir * (radius * t) * TexBaseSize;

            if (any(uv_s < 0) || any(uv_s > 1)) break;

            float4 wpd_s = tex2D(Tex1, uv_s);
            if (wpd_s.a >= 1.0 || dot(wpd_s.rgb, wpd_s.rgb) < 1e-5) continue;

            float3 H     = 1.0 / wpd_s.xyz - P;
            float  H_len = sqrt(dot(H, H)) + 1e-4;
            float3 H_dir = H / H_len;

            float elevation = dot(N, H_dir) - depthBias;

            if (elevation > max_horizon)
            {
                float  delta    = elevation - max_horizon;
                max_horizon     = elevation;

                float3 radiance = tex2D(TexBase, uv_s).rgb;
                float  atten    = 1.0 / (1.0 + H_len * 0.02);

                gi_accum += radiance * delta * atten;
            }
        }
    }

    float3 gi = gi_accum * (PI / (float)NUM_DIRECTIONS);

    int dbg = (int)Constants1.x;
    if      (dbg == 1) return float4(gi, 1);
    else if (dbg == 2) return float4(N * 0.5 + 0.5, 1);
    else if (dbg == 4) return float4(depth.xxx, 1);

    return float4(gi, 1);
}