#include "build_common.hlsl"

// ── A ───────────────────────────────────────────────────────
#define SS_SLICES        4
#define SS_STEPS         6
#define SS_RADIUS_PX     80.0f
#define SS_AO_STRENGTH   2.0f
#define SS_GI_STRENGTH   0.5f
#define SS_PI            3.14159265f
// ハロー対策: 相対深度差がこれを超えたサンプルを棄却
#define SS_DEPTH_THRESH  0.15f

float4 SL(sampler s, float2 uv) { return tex2Dlod(s, float4(uv, 0, 0)); }
float3 GetWP(float2 uv)         { return 1.f / SL(Tex1, uv).rgb; }
float3 GetN (float2 uv)         { return decode_normal(SL(Tex2, uv).rg); }
float  GetD (float2 uv)         { return SL(Tex1, uv).a; }

float2 GetNoise(float2 uv) {
    float2 px = uv * UserConst1.xy;
    float  t  = TIME;
    return float2(
        frac(sin(dot(px + t * 0.71f, float2(127.1f, 311.7f))) * 43758.5f),
        frac(sin(dot(px + t * 1.31f, float2(269.5f, 183.3f))) * 43758.5f)
    );
}

void ComputeSlice(
    float3 P, float3 N, float dC,
    float2 uv0, float2 stepUV, float randOff,
    inout float aoAcc, inout float3 giAcc)
{
    float  hz = 0.0f;
    float2 uv = uv0 + stepUV * randOff;

    for (int s = 0; s < SS_STEPS; s++) {
        uv += stepUV;
        float2 uvC = saturate(uv);

        float dS = GetD(uvC);

        // ─── ハロー修正 ─────────────────────────────────────────
        // スカイピクセル(depth≈0.00025) または 深度不連続サンプルを棄却
        // break を使わず float フラグで乗算（ps3.0 X3526 回避）
        float depthOK = (dS > 0.001f &&
            abs(dC - dS) / (dC + 1e-5f) < SS_DEPTH_THRESH) ? 1.0f : 0.0f;
        // ────────────────────────────────────────────────────────

        float3 Sf   = GetWP(uvC);
        float3 dV   = Sf - P;
        float  len  = length(dV) + 1e-6f;
        float3 Vn   = dV / len;
        float  sinH = dot(N, Vn);

        float isValid = saturate(sign(sinH - hz - 1e-4f)) * depthOK;

        float3 sc  = SL(TexBase, uvC).rgb;
        float3 sN  = GetN(uvC);
        float  bff = saturate(dot(sN, -Vn));

        giAcc += sc * bff * saturate(sinH) * (sinH - hz) * isValid;
        hz    += (sinH - hz) * isValid;
    }
    aoAcc += saturate(hz);
}

float4 main( PS_INPUT i ) : COLOR
{ UNPACK_GBUFFER;

// ── B ───────────────────────────────────────────────────────
    SKIP_SKY;

    float2 noise = GetNoise(i.uv);
    float  aoAcc = 0.0f;
    float3 giAcc = (0.0f).xxx;
    float2 step1 = PIXSIZE * (SS_RADIUS_PX / float(SS_STEPS));

    for (int sl = 0; sl < SS_SLICES; sl++) {
        float  phi    = (float(sl) + noise.x) / float(SS_SLICES) * SS_PI * 2.0f;
        float2 stepUV = float2(cos(phi), sin(phi)) * step1;
        ComputeSlice(worldPos, normal, depth, i.uv, stepUV, noise.y, aoAcc, giAcc);
    }

    float  ao = 1.0f - saturate(aoAcc / float(SS_SLICES) * SS_AO_STRENGTH);
    float3 gi = giAcc * SS_GI_STRENGTH / float(SS_SLICES);

    float4 result = color;
    result.rgb    = result.rgb * ao + gi;
DRAW; }