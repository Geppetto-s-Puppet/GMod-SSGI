#include "common.hlsl"

// TexBase (s0): _rt_FullFrameFB  (元画像)
// Tex1    (s1): _rt_SSGI_*       (デノイズ済みGI)
// Constants0.x ($c0_x): GI強度

float4 main(PS_INPUT I) : COLOR
{
    float3 scene = tex2D(TexBase, I.uv).rgb;
    float3 gi    = tex2D(Tex1,    I.uv).rgb;

    return float4(scene + gi * Constants0.x, 1.0);
}