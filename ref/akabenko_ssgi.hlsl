#include "common_ps_bayer.h"
#include "common_octahedron_encoding.h"
#include "common_diamond_encoding.h"
#include "common_ps_fxc.h"

sampler FrameBuffer           	: register( s0 );
sampler WPDepthBuffer           : register( s1 );
sampler NormalTangentBuffer     : register( s2 );
sampler BlueNoiseSampler        : register( s3 );

const float4 Constant0			: register( c0 );
const float4 Constant1			: register( c1 );
const float4 Constant2			: register( c2 );
const float4 Constant3			: register( c3 );
const float2 TexBaseSize        : register( c4 );
const float2 TileSize           : register( c7 );

const float4x4 ViewProj         : register( c11 );

struct PS_IN
{
    float2 pos                      : VPOS;
    float2 uv                : TEXCOORD0;
};

static const int samples = 16;
static const float TAU = 6.28318530718;
static const float PI = 3.1415925;
static const float PI2 = PI * 2;
#define intens          Constant0.x
#define stepSize        Constant0.w
#define stepFalloff     Constant1.w
#define depthThreshold  Constant2.w
#define scale           Constant2.x
#define minRayDistance Constant2.y

float3 HemisphereSample(float3x3 TBN, float2 noise) {
    float phi = PI2 * noise.x;
    float cosTheta = sqrt(1 - noise.y);
    float sinTheta = sqrt(1 - cosTheta * cosTheta);

    float cosPhi, sinPhi;
    sincos(phi, sinPhi, cosPhi);
    
    float3 localDir = float3(
        sinTheta * cosPhi,
        sinTheta * sinPhi,
        cosTheta
    );
    
    return mul(localDir, TBN);
}

float4 main(PS_IN input) : COLOR0 {
    float2 uv = input.uv;
    float4 wpdepth = tex2D(WPDepthBuffer, uv);
    float depth = wpdepth.a;
    
    if (depth == 0.00025) discard;
    
    float3 worldPos = 1/wpdepth.xyz;
    
    float4 normals_tangets = tex2D(NormalTangentBuffer,uv);
    float flipSign = normals_tangets.a;
    float3 worldNormal = Decode(normals_tangets.xy);
    float3 tangents = decode_tangent(worldNormal, normals_tangets.z);
    float3 binormals = normalize(cross(worldNormal,tangents)) * flipSign;
    float3x3 TBN = float3x3(tangents, binormals, worldNormal);
    
    
    float2 blueNoise = tex2D(BlueNoiseSampler, input.pos * TexBaseSize / TileSize * scale).ar;
    //return float4(blueNoise,0,1);
    float3 rayDir = HemisphereSample(TBN, blueNoise);

    float3 accumulatedColor = 0;
    float3 rayPos = worldPos;

    [loop]
    for(int i = 0; i < samples; i++) {
        rayPos += rayDir * stepSize;
        
        float4 projPos = mul(float4(rayPos, 1), ViewProj);
        float2 sampleTexCoord = projPos.xy / projPos.w * 0.5 + 0.5;
        
        if(dot(sampleTexCoord - saturate(sampleTexCoord), 1.0) != 0.0) break;
        
        float sampleDepth = tex2Dlod(WPDepthBuffer, float4(sampleTexCoord,0,0)).a;
        if (sampleDepth == 0.00025) continue;

        float rayLength = length(rayPos - worldPos);
        if(rayLength < minRayDistance) continue;

        if(abs(depth - sampleDepth) < depthThreshold) {
            float3 sampleColor = tex2Dlod(FrameBuffer, float4(sampleTexCoord,0,0)).rgb;
            float3 sampleNormal = Decode(tex2Dlod(NormalTangentBuffer, float4(sampleTexCoord,0,0)).xy);
            
            float NdotRay = max(0, dot(sampleNormal, -rayDir));
            accumulatedColor += sampleColor * NdotRay * stepFalloff;
            //break;
        }
    }
    
    return float4(accumulatedColor * intens, depth);
}
