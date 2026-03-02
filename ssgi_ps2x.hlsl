#include "common.hlsl"

float4 main(PS_INPUT I) : COLOR
{
    float4 wpd   = tex2D(Tex1, I.uv);
    float3 ppos  = 1.0 / wpd.xyz;
    float  depth = wpd.a;


    float geo = (dot(wpd.rgb, wpd.rgb) > 0.00001) ? 1.0 : 0.0;
    if (geo == 0.0) return float4(0.0, 0.0, 0.0, 1.0);

    // 右隣ピクセルのワールド座標との距離だけ確認
    float4 swpd = tex2D(Tex1, I.uv + float2(Tex1Size.x, 0.0)); // 1テクセル右
    float3 spos = 1.0 / swpd.xyz;
    float  dist = length(spos - ppos);

    return float4(dist * 0.001, dist * 0.001, dist * 0.001, 1.0);
}