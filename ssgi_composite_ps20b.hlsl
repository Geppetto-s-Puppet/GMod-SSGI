#include "common.hlsl"

// Tex1 = _rt_SSGI の中身をそのまま表示
float4 main(PS_INPUT I) : COLOR
{
    float3 gi = tex2D(Tex1, I.uv).rgb;
    return float4(gi, 1.0);
}