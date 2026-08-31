// ---------------------------------------------------------------------------
// SSGI temporal pass - reprojected history accumulation.
//
// The single biggest noise win available here. _rt_WPDepth already holds a
// world position per pixel, so the previous frame's screen position is an exact
// matrix multiply - no velocity buffer and no motion vectors needed for static
// geometry, which is most of a Source map.
//
// Disocclusion is caught by comparing the depth the surface *should* have had
// last frame (the w of the reprojected clip position, which is exactly
// perpendicular view depth under GShader's projection) against the depth that
// was actually there. Ghosting from moving objects and from lighting changes is
// caught by clamping the history into the neighbourhood of the current frame.
// ---------------------------------------------------------------------------
#include "ssgi_common.h"

sampler RawBuffer     : register( s0 );   // this frame's trace output
sampler WPDepthBuffer : register( s1 );   // _rt_WPDepth
sampler HistoryBuffer : register( s2 );   // last frame's accumulated result
sampler PrevZBuffer   : register( s3 );   // last frame's linear depth

const float4 C0 : register( c0 );   // xy = 1/rtSize   zw = rtSize
const float4 C1 : register( c1 );   // x = alpha   y = clampK   z = depthTol   w = unused

const float4x4 g_PrevViewProj : register( c11 );   // $viewprojmat, previous frame

#define g_InvRTSize C0.xy
#define g_Alpha     C1.x
#define g_ClampK    C1.y
#define g_DepthTol  C1.z

struct PS_INPUT
{
    float2 vPos : VPOS;
    float2 uv   : TEXCOORD0;
};

float4 main( PS_INPUT i ) : COLOR0
{
    float2 uv  = ( i.vPos + 0.5f ) * g_InvRTSize;
    float4 cur = tex2Dlod( RawBuffer, float4( uv, 0, 0 ) );

    float4 wpd = tex2Dlod( WPDepthBuffer, float4( uv, 0, 0 ) );
    if ( SSGI_IS_SKY( wpd.a ) ) return cur;

    // 3x3 neighbourhood of the current frame. Doubles as the clamp window and
    // as a cheap prefilter for the variance estimate.
    float4 mom1 = 0.0f, mom2 = 0.0f;
    [unroll]
    for ( int y = -1; y <= 1; y++ )
    {
        [unroll]
        for ( int x = -1; x <= 1; x++ )
        {
            float4 s = tex2Dlod( RawBuffer, float4( uv + float2( x, y ) * g_InvRTSize, 0, 0 ) );
            mom1 += s;
            mom2 += s * s;
        }
    }
    mom1 /= 9.0f;
    mom2 /= 9.0f;
    float4 sigma = sqrt( max( mom2 - mom1 * mom1, 0.0f ) );

    // Reproject through last frame's view-projection.
    float3 P    = SSGI_WorldPos( wpd );
    float4 clip = mul( float4( P, 1.0f ), g_PrevViewProj );

    float2 prevUV = ( clip.xy / clip.w ) * 0.5f + 0.5f;

    float valid = ( clip.w > 0.0f
                 && prevUV.x >= 0.0f && prevUV.x <= 1.0f
                 && prevUV.y >= 0.0f && prevUV.y <= 1.0f ) ? 1.0f : 0.0f;

    // clip.w is perpendicular view depth in the previous frame; PrevZBuffer
    // holds what was actually rendered there.
    float prevZ = tex2Dlod( PrevZBuffer, float4( prevUV, 0, 0 ) ).r;
    float rel   = abs( clip.w - prevZ ) / max( clip.w, 1e-3f );
    valid *= ( rel < g_DepthTol ) ? 1.0f : 0.0f;

    float4 hist = tex2Dlod( HistoryBuffer, float4( prevUV, 0, 0 ) );
    hist = clamp( hist, mom1 - sigma * g_ClampK, mom1 + sigma * g_ClampK );

    float a = lerp( 1.0f, g_Alpha, valid );
    return lerp( hist, cur, a );
}
