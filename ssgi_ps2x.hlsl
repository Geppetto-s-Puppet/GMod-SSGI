#include "common.hlsl"

float4 main(PS_INPUT I) : COLOR
{
    float4 wpd       = tex2D(Tex1, I.uv);
    float3 world_pos = 1.0 / wpd.xyz;   // ライブラリと同じ
    float  depth     = wpd.a;

    // depthをそのまま灰色で表示するだけ
    return float4(depth, depth, depth, 1.0);
}