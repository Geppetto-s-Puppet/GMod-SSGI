// ---------------------------------------------------------------------------
// SSGI spatial denoise - edge-avoiding a-trous wavelet transform.
//
// Dammertz et al. 2010 (jo.dreggn.org/home/2010_atrous.pdf). Run several times
// with a doubling stride: each pass is a small kernel but the support grows
// geometrically, so a 5x5 run three times reaches 33x33 for the cost of three
// small passes.
//
// Define SSGI_ATROUS_RADIUS (1 for 3x3, 2 for 5x5) before including.
// ---------------------------------------------------------------------------
#include "ssgi_common.h"

sampler InputBuffer   : register( s0 );   // SSGI signal being filtered
sampler WPDepthBuffer : register( s1 );   // _rt_WPDepth
sampler NormalBuffer  : register( s2 );   // _rt_NormalsTangents

const float4 C0 : register( c0 );   // xy = 1/rtSize   zw = rtSize
const float4 C1 : register( c1 );   // x = stride   y = sigmaZ   z = sigmaN   w = sigmaL

#define g_InvRTSize C0.xy
#define g_Stride    C1.x
#define g_SigmaZ    C1.y
#define g_SigmaN    C1.z
#define g_SigmaL    C1.w

struct PS_INPUT
{
    float2 vPos : VPOS;
    float2 uv   : TEXCOORD0;
};

// B3 spline row, indexed by |offset|.
static const float kH[3] = { 0.375f, 0.25f, 0.0625f };

float4 main( PS_INPUT i ) : COLOR0
{
    float2 uv = ( i.vPos + 0.5f ) * g_InvRTSize;

    float4 wpd = tex2Dlod( WPDepthBuffer, float4( uv, 0, 0 ) );
    float4 c   = tex2Dlod( InputBuffer,   float4( uv, 0, 0 ) );
    if ( SSGI_IS_SKY( wpd.a ) ) return c;

    float  z = SSGI_LinearZ( wpd );
    float3 n = SSGI_DecodeNormal( tex2Dlod( NormalBuffer, float4( uv, 0, 0 ) ).rg );
    float  l = SSGI_Luma( c.rgb );

    // Depth tolerance scales with distance - a 4 unit step matters up close and
    // is noise at the far end of a corridor.
    float invZTol = 1.0f / max( g_SigmaZ * z * 0.01f, 1e-3f );

    float4 sum  = c * kH[0] * kH[0];
    float  wsum = kH[0] * kH[0];

    [unroll]
    for ( int y = -SSGI_ATROUS_RADIUS; y <= SSGI_ATROUS_RADIUS; y++ )
    {
        [unroll]
        for ( int x = -SSGI_ATROUS_RADIUS; x <= SSGI_ATROUS_RADIUS; x++ )
        {
            if ( x == 0 && y == 0 ) continue;

            float2 suv = uv + float2( x, y ) * g_Stride * g_InvRTSize;
            if ( suv.x < 0.0f || suv.x > 1.0f || suv.y < 0.0f || suv.y > 1.0f ) continue;

            float4 swpd = tex2Dlod( WPDepthBuffer, float4( suv, 0, 0 ) );
            if ( SSGI_IS_SKY( swpd.a ) ) continue;

            float4 sc = tex2Dlod( InputBuffer,  float4( suv, 0, 0 ) );
            float3 sn = SSGI_DecodeNormal( tex2Dlod( NormalBuffer, float4( suv, 0, 0 ) ).rg );
            float  sz = SSGI_LinearZ( swpd );

            float wz = exp( -abs( z - sz ) * invZTol );
            float wn = pow( max( dot( n, sn ), 1e-4f ), g_SigmaN );
            float wl = exp( -abs( l - SSGI_Luma( sc.rgb ) ) / g_SigmaL );

            float w = kH[abs( x )] * kH[abs( y )] * wz * wn * wl;
            sum  += sc * w;
            wsum += w;
        }
    }

    return sum / max( wsum, 1e-5f );
}
