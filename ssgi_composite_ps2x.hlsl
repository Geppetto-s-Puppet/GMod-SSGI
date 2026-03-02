#include "common.hlsl"

// TexBase = _rt_FullFrameFB
// Tex1    = _rt_SSGI

float4 main(PS_INPUT I) : COLOR
{
    float3 base = tex2D(TexBase, I.uv).rgb;
    float3 gi   = tex2D(Tex1,    I.uv).rgb;

    float intensity = Constants0.x;
    return float4(base + gi * intensity, 1.0);
}
