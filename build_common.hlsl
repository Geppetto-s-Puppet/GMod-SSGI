// SRV登録
sampler TexBase : register( s0 ); // _rt_FullFrameFB
sampler Tex1    : register( s1 ); // _rt_WPDepth
sampler Tex2    : register( s2 ); // _rt_NormalsTangents
struct PS_INPUT
{
    float2 uv		    : TEXCOORD0; // texture coordinates
    float2 zeros        : TEXCOORD1; // always (0, 0)
    float2 texcoord2    : TEXCOORD2; // unused
    float4 color		: TEXCOORD3; // vertex color (if mesh has one)
    float2 pos			: VPOS;
};

// エイリアス登録
float4 UserConst1 : register( c1 );
float4 UserConst2 : register( c2 );
float4 UserConst3 : register( c3 );
#define PIXSIZE (1.f / UserConst1.xy)
#define TIME   UserConst2.x // GetInt()
#define FRAME  UserConst2.y // CurTime()
#define INT    UserConst2.z // FrameTime()
#define SPD    UserConst3.w   // GetLength()
#define VEL    UserConst3.xyz // GetVelocity()

// 推奨デコーダ
float3 decode_normal(float2 f) {
    f = f * 2.0 - 1.0;
    float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = saturate(-n.z);
    n.xy += n.xy >= 0.0 ? -t : t;
    return normalize(n);
}
float2 decode_diamond(float p) {
    float2 v;
    float p_sign = sign(p - 0.5f);
    v.x = -p_sign * 4.f * p + 1.f + p_sign * 2.f;
    v.y = p_sign * (1.f - abs(v.x));
    return normalize(v);
}
float3 decode_tangent(float3 normal, float diamond_tangent) {
    float3 t1;
    if (abs(normal.y) > abs(normal.z)) {
        t1 = float3(normal.y, -normal.x, 0.f);
    } else {
        t1 = float3(normal.z, 0.f, -normal.x);
    }
    t1 = normalize(t1);
    float3 t2 = cross(t1, normal);
    float2 packed_tangent = decode_diamond(diamond_tangent);
    return packed_tangent.x * t1 + packed_tangent.y * t2;
}

// 俺用マクロ
#define UNPACK_GBUFFER;                                    \
    float4 color    = tex2D(TexBase, i.uv); float4 packed; \
    packed          = tex2D(Tex1, i.uv);                   \
    float3 worldPos = 1.f / packed.rgb;                    \
    float  depth    = packed.a;                            \
    packed          = tex2D(Tex2, i.uv);                   \
    float  sign     = packed.a;                            \
    float3 normal   = decode_normal(packed.rg);            \
    float3 tangent  = decode_tangent(normal, packed.b);
#define SKIP_SKY; if (depth == 0.00025) return color;
#define DRAW; return saturate(result); // No-Banding
#define DRAW_DEPTH return float4(depth, depth, depth, 1.0);
#define DRAW_NORMAL return float4(normal * 0.5 + 0.5, 1.0);