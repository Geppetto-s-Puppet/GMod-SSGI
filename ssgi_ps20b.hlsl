#include "common.hlsl"

// TexBase (s0): _rt_FullFrameFB     - シーン色（GIの光源）
// Tex1    (s1): _rt_WPDepth         - ワールド座標逆数 + 線形深度
// Tex2    (s2): _rt_NormalsTangents - 法線（オクタヘドロン符号化）
//
// Constants0.x ($c0_x): サンプル半径（テクセル数）
// Constants0.y ($c0_y): 深度バイアス（自己遮蔽防止）
// Constants1.x ($c1_x): デバッグモード

#define NUM_DIRECTIONS  8    // スクリーン空間でレイを飛ばす方向数
#define NUM_STEPS       6    // 1方向あたりのサンプル数
#define PI              3.14159265358979

// ---------- ユーティリティ ----------

float3 DecodeNormal(float2 f)
{
    f = f * 2.0 - 1.0;
    float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = saturate(-n.z);
    n.xy += n.xy >= 0.0 ? -t : t;
    return normalize(n);
}

// フレーム内で分散するノイズ（テンポラルなしでもバンディングを緩和）
float IGNoise(float2 pos)
{
    return frac(52.9829189 * frac(dot(pos, float2(0.06711056, 0.00583715))));
}

// 距離減衰（遠いサンプルは寄与を下げる）
float Falloff(float dist2)
{
    return 1.0 / (1.0 + dist2 * 0.02);
}

// ---------- メイン ----------

float4 main(PS_INPUT I) : COLOR
{
    float4 wpd   = tex2D(Tex1, I.uv);
    float3 P     = 1.0 / wpd.xyz;   // 中心ピクセルのワールド座標
    float  depth = wpd.a;

    // スカイ・無効ピクセルはGIなし
    if (depth >= 1.0 || dot(wpd.rgb, wpd.rgb) < 1e-5)
        return float4(0, 0, 0, 1);

    float3 N         = DecodeNormal(tex2D(Tex2, I.uv).rg);
    float  noise     = IGNoise(I.pos);
    float  radius    = Constants0.x;
    float  depthBias = Constants0.y;

    float3 gi_accum    = 0;
    float  total_weight = 0;

    // -------- ホライゾンベースGI --------
    // スクリーン空間でNUM_DIRECTIONS方向にレイを伸ばし、
    // 各方向の「地平線」より上にある最初の可視サンプルの輝度を積む。

    for (int d = 0; d < NUM_DIRECTIONS; d++)
    {
        // ノイズで方向をずらして縞を防ぐ
        float phi  = ((float)d + noise) * (PI / (float)NUM_DIRECTIONS);
        float2 dir = float2(cos(phi), sin(phi));  // スクリーン空間の単位方向

        float max_horizon = -1.0;  // 現在の最大仰角 (sin値)

        for (int s = 1; s <= NUM_STEPS; s++)
        {
            // ステップを対数的に分散（近くは細かく、遠くは粗く）
            float  t    = (float)s / (float)NUM_STEPS;
            float2 uv_s = I.uv + dir * (radius * t) * TexBaseSize;

            // 画面外スキップ
            if (any(uv_s < 0) || any(uv_s > 1)) break;

            float4 wpd_s = tex2D(Tex1, uv_s);

            // サンプル先もスカイなら無視
            if (wpd_s.a >= 1.0 || dot(wpd_s.rgb, wpd_s.rgb) < 1e-5) continue;

            float3 P_s = 1.0 / wpd_s.xyz;

            // 中心→サンプルのベクトル
            float3 H     = P_s - P;
            float  H_len = length(H);
            if (H_len < 1e-4) continue;

            float3 H_dir = H / H_len;

            // 法線との内積 = 仰角のsin値（-1〜1）
            float elevation = dot(N, H_dir) - depthBias;

            if (elevation > max_horizon)
            {
                // ホライゾンを押し上げた分 = 新たに見えたソリッドアングルのスライス
                float delta    = elevation - max_horizon;
                max_horizon    = elevation;

                float3 radiance = tex2D(TexBase, uv_s).rgb;
                float  atten    = Falloff(H_len * H_len);

                gi_accum     += radiance * delta * atten;
                total_weight += delta;
            }
        }
    }

    // 方向数で正規化（π/NUM_DIRECTIONS ≈ 立体角の均等分割）
    float3 gi = gi_accum * (PI / (float)NUM_DIRECTIONS);

    // ---------- デバッグ出力 ----------
    int dbg = (int)Constants1.x;
    if      (dbg == 1) return float4(gi, 1);                   // GI層のみ
    else if (dbg == 2) return float4(N * 0.5 + 0.5, 1);        // 法線
    else if (dbg == 3) return float4(dot(wpd.rgb,wpd.rgb).xxx * 100, 1); // geo範囲
    else if (dbg == 4) return float4(depth.xxx, 1);             // 深度

    return float4(gi, 1);
}