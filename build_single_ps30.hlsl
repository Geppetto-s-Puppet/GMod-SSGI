#include "build_common.hlsl"

////////////////////////////////////////////////////////////////////////////////
// 「A」 -- 定数・ヘルパー関数・設定
////////////////////////////////////////////////////////////////////////////////

// tunables (チューニングはここだけを調整してください)
#define PI             3.14159265
#define TWO_PI         (PI * 2.0)

// ステップ関連
#define SAMPLES_PER_SLICE   8     // 各スライスあたりのステップ数 (>=1)
#define SLICE_COUNT         8     // 方向スライス数
#define RADIUS_PIXELS       20.0  // サンプリング半径（ピクセル）
#define THICKNESS           0.08  // 厚み（GI の広がり）
#define AO_INTENSITY        1.0   // AO の強さ
#define GI_INTENSITY        2.0//0.7   // GI の強さ（色の寄与）
#define STEP_RANDOMNESS     0.5   // ステップ数のランダム補正幅

// 内部閾値
#define MIN_SAMPLE_UV_DIST  0.001

// 乱数（簡易）：uv と TIME を用いる
float Hash12(float2 p)
{
    // cheap hash
    float h = dot(p, float2(127.1, 311.7));
    return frac(sin(h) * 43758.5453 + TIME * 0.0001);
}

// ラジアル方向サンプルの強度減衰（距離依存）
float DistanceFalloff(float d, float radius)
{
    float t = saturate(d / radius);
    // smooth falloff
    return 1.0 - t * t;
}

// Luminance (色の重み)
float Luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

////////////////////////////////////////////////////////////////////////////////
// ピクセルシェーダ main
////////////////////////////////////////////////////////////////////////////////
float4 main( PS_INPUT i ) : COLOR
{ UNPACK_GBUFFER;
    SKIP_SKY; // 空ならそのまま返す

////////////////////////////////////////////////////////////////////////////////
// 「B」 -- SSGI + SSAO を計算して result に入れる
////////////////////////////////////////////////////////////////////////////////

    float2 uv = i.uv;

    // 基本サンプル情報
    float3 positionC = worldPos;   // build_common の UNPACK で得る worldPos (1/packed.rgb の扱い)
    float3 normalC   = normal;     // decode_normal を通したもの
    float3 baseColor = color.rgb;

    // スクリーン単位の UV スケール (build_common の PIXSIZE を利用)
    // PIXSIZE マクロは (1.0 / UserConst1.xy) として定義されているため
    float2 invScreen = PIXSIZE; // 画面あたりの UV サイズ

    // ピクセル単位半径を UV に変換
    float radiusUV = RADIUS_PIXELS * invScreen.x; // 横方向の基準を使用
    radiusUV = max(radiusUV, 1e-6);

    // サンプリング間隔 (UV)
    float stepUV = radiusUV / float(SAMPLES_PER_SLICE);

    // ノイズ / スペシャルオフセット
    float2 noise = float2(Hash12(uv + 0.13), Hash12(uv + 0.71));

    // 結果蓄積
    float occAccumulator = 0.0;   // occlusion [0..1]
    float3 giAccumulator = 0.0;   // indirect color

    // 方向スライスごとにループ
    // ps_3_0 のためループは固定最大回数で実行
    for (int s = 0; s < SLICE_COUNT; ++s)
    {
        // 角度を決める（スライス中心 + ノイズ）
        float sliceF = (float(s) + noise.x) / float(SLICE_COUNT);
        float phi = sliceF * TWO_PI;
        float2 dir = float2(cos(phi), sin(phi));

        // 各ステップでのサンプル
        for (int step = 1; step <= SAMPLES_PER_SLICE; ++step)
        {
            // step のランダム化を少し入れる
            float stepRand = 1.0 + (noise.y - 0.5) * STEP_RANDOMNESS;
            float distUV = step * stepUV * stepRand;
            float2 sampleUV = uv + dir * distUV;

            // 画面外は打ち切り
            if (any(sampleUV < 0.0) || any(sampleUV > 1.0)) break;

            // サンプルを読む
            float4 packedS = tex2D(Tex1, sampleUV);
            // build_common 側の unpack と合わせる（提供されたコードに従う）
            float3 sampleWorld = 1.0 / packedS.rgb; // 注意: build_common 側と合わせた 1/packed.rgb の取り扱い
            float sampleDepth = packedS.a;

            float4 baseSampCol = tex2D(TexBase, sampleUV);
            float3 sampleColor = baseSampCol.rgb;

            float4 nPacked = tex2D(Tex2, sampleUV);
            float3 sampleNormal = decode_normal(nPacked.rg);

            // ベクトル / 距離
            float3 v = sampleWorld - positionC;
            float dist = length(v);

            // 距離が 0 に近い/異常値は無視
            if (dist <= 1e-5) continue;

            float3 viewDir = normalize(v);

            // 法線方向に対する角度（表示側の occluder 判定）
            // 値域は [-1,1]。こちらを occlusion の強さに利用
            float NdotV = saturate(dot(normalC, viewDir));

            // サンプル法線の向き（ライティング寄与に利用）
            float Ns = saturate(dot(sampleNormal, -viewDir));

            // 距離フォールオフ（近いものほど強く）
            float fall = DistanceFalloff(dist, RADIUS_PIXELS);

            // occluder の強さ：法線角度 + 距離 + サンプルの明るさ(大まかな反射寄与)
            // ここで「見えない度合い」を蓄積して AO にする
            float lum = Luma(sampleColor);
            float occluder = NdotV * Ns * fall * (0.5 + lum); // 明るさを少し重み付け
            occluder = saturate(occluder);

            // GI：サンプルの色を法線寄与と falloff で取り込み
            float3 giContribution = sampleColor * Ns * fall;

            // 厚み (厚み分だけサンプルを補正して間接光を増やす)
            giContribution *= THICKNESS;

            // 累積（正規化は最後に）
            occAccumulator += occluder;
            giAccumulator += giContribution;
        } // step
    } // slice

    // normalization
    float totalSamples = float(SLICE_COUNT * SAMPLES_PER_SLICE);
    // occlusion value (0..1)  — 大きければ暗くする
    float ao = saturate(occAccumulator / max(1e-6, totalSamples) * AO_INTENSITY);

    // GI を平均化して強度スケールをかける
    float3 gi = (giAccumulator / max(1e-6, totalSamples)) * GI_INTENSITY;

    // 最終合成
    // AO は乗算的に色を暗くし、GI を加算する（簡易的な SSGI 合成）
    float3 outColor = baseColor * (1.0 - ao) + gi;

    // 色のクリップ防止（DRAW マクロで saturate するが念のため clamp）
    float4 result = float4(saturate(outColor), color.a);

DRAW; }