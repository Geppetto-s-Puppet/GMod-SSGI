#include "common.hlsl"

// TexBase (s0): GI入力（ping-pongで差し替わる）
// Tex1    (s1): _rt_WPDepth
// Tex2    (s2): _rt_NormalsTangents
// Constants0.x ($c0_x): stepWidth（1, 2, 4, 8...）

// エッジ停止の強さ（大きいほど境界で止まりやすい）
#define SIGMA_L  4.0   // 色（GI輝度）の感度
#define SIGMA_N  0.5   // 法線の感度
#define SIGMA_D  1.0   // 深度の感度

// 3x3 À-Trousカーネル
static const float kernel[9] = {
    1.0/16, 2.0/16, 1.0/16,
    2.0/16, 4.0/16, 2.0/16,
    1.0/16, 2.0/16, 1.0/16,
};
static const int2 offsets[9] = {
    {-1,-1},{0,-1},{1,-1},
    {-1, 0},{0, 0},{1, 0},
    {-1, 1},{0, 1},{1, 1},
};

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
    float stepWidth = Constants0.x;

    // 中心ピクセルの情報
    float3 gi_center  = tex2D(TexBase, I.uv).rgb;
    float  depth_c    = tex2D(Tex1,    I.uv).a;
    float3 normal_c   = DecodeNormal(tex2D(Tex2, I.uv).rg);

    // スカイならそのまま返す
    if (depth_c >= 1.0)
        return float4(gi_center, 1.0);

    float3 color_sum  = 0;
    float  weight_sum = 0;

    for (int i = 0; i < 9; i++)
    {
        float2 uv_s = I.uv + offsets[i] * stepWidth * TexBaseSize;

        float3 gi_s     = tex2D(TexBase, uv_s).rgb;
        float  depth_s  = tex2D(Tex1,    uv_s).a;
        float3 normal_s = DecodeNormal(tex2D(Tex2, uv_s).rg);

        // --- エッジ停止関数 ---

        // 法線差分
        float w_n = pow(saturate(dot(normal_c, normal_s)), SIGMA_N * 128.0);

        // 深度差分
        float dz = (depth_c - depth_s) / (stepWidth + 1e-5);
        float w_d = exp(-abs(dz) * SIGMA_D);

        // GI輝度差分
        float lum_c = dot(gi_center, float3(0.2126, 0.7152, 0.0722));
        float lum_s = dot(gi_s,      float3(0.2126, 0.7152, 0.0722));
        float w_l = exp(-abs(lum_c - lum_s) * SIGMA_L);

        float w = kernel[i] * w_n * w_d * w_l;

        color_sum  += gi_s * w;
        weight_sum += w;
    }

    float3 result = (weight_sum > 1e-5) ? color_sum / weight_sum : gi_center;
    return float4(result, 1.0);
}