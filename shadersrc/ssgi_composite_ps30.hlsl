// ---------------------------------------------------------------------------
// SSGI resolve - joint bilateral upsample + composite, in one full res pass.
//
// The SSGI signal lives at a fraction of the screen resolution. A plain
// bilinear stretch drags occlusion across depth discontinuities and produces
// the halos that make cheap SSAO look glued on, so the four nearest low res
// taps are reweighted by how well their depth and normal match the full res
// pixel being shaded, and only then blended.
// ---------------------------------------------------------------------------
#include "ssgi_common.h"

sampler ColorBuffer   : register( s0 );   // _rt_FullFrameFB
sampler WPDepthBuffer : register( s1 );   // _rt_WPDepth
sampler NormalBuffer  : register( s2 );   // _rt_NormalsTangents
sampler SSGIBuffer    : register( s3 );   // denoised SSGI, trace resolution

const float4 C0 : register( c0 );   // xy = 1/fullSize   zw = 1/ssgiSize
const float4 C1 : register( c1 );   // x = giScale  y = aoScale  z = albedoBleed  w = debug
const float4 C2 : register( c2 );   // xy = ssgiSize   z = depthTol   w = normalPow
const float4 C3 : register( c3 );   // x = splitX  y = diffGain  z = aoLightBias  w = linearise

#define g_InvFullSize C0.xy
#define g_InvSSGISize C0.zw
#define g_GIScale     C1.x
#define g_AOScale     C1.y
#define g_AlbedoBleed C1.z
#define g_Debug       C1.w
#define g_SSGISize    C2.xy
#define g_DepthTol    C2.z
#define g_NormalPow   C2.w
#define g_Split       C3.x
#define g_DiffGain    C3.y
#define g_AOLightBias C3.z
#define g_Linearise   C3.w

// Debug view ids. Kept as float compares because $c registers are floats.
#define DBG_IS( n ) ( abs( g_Debug - (n) ) < 0.5f )

struct PS_INPUT
{
    float2 vPos : VPOS;
    float2 uv   : TEXCOORD0;
};

float4 main( PS_INPUT i ) : COLOR0
{
    float2 uv = ( i.vPos + 0.5f ) * g_InvFullSize;

    float4 color = tex2Dlod( ColorBuffer, float4( uv, 0, 0 ) );
    float4 wpd   = tex2Dlod( WPDepthBuffer, float4( uv, 0, 0 ) );

    // Normals are useful on sky pixels too, so this one comes first.
    if ( DBG_IS( 4 ) )
        return float4( SSGI_DecodeNormal( tex2Dlod( NormalBuffer, float4( uv, 0, 0 ) ).rg ) * 0.5f + 0.5f, 1.0f );

    // Pixels with no G-buffer behind them: real sky, and the 3D skybox while
    // r_shaderlib_3dskybox is off. Screen space has nothing to trace against.
    // Distant *real* geometry is not in this set - see SSGI_IS_SKY.
    //
    // Every isolating debug view returns that term's *neutral* value rather than
    // the scene, so the excluded region reads as flat and its edge is visible.
    // Leaving the photographic sky in the middle of an occlusion view just looks
    // like the effect failed.
    if ( SSGI_IS_SKY( wpd.a ) )
    {
        if ( DBG_IS( 1 ) ) return float4( 0.0f, 0.0f, 0.0f, 1.0f );   // no indirect light
        if ( DBG_IS( 2 ) ) return float4( 1.0f, 1.0f, 1.0f, 1.0f );   // no occlusion
        if ( DBG_IS( 3 ) ) return float4( 1.0f, 1.0f, 1.0f, 1.0f );
        if ( DBG_IS( 5 ) ) return float4( 1.0f, 1.0f, 1.0f, 1.0f );   // infinitely far
        if ( DBG_IS( 7 ) ) return float4( 0.0f, 0.0f, 0.0f, 1.0f );   // nothing changed
        if ( DBG_IS( 8 ) ) return float4( 1.0f, 0.0f, 1.0f, 1.0f );   // outside coverage
        return color;
    }

    float  z = SSGI_LinearZ( wpd );
    float3 n = SSGI_DecodeNormal( tex2Dlod( NormalBuffer, float4( uv, 0, 0 ) ).rg );

    if ( DBG_IS( 5 ) )
        return float4( ( z / 2000.0f ).xxx, 1.0f );

    // 8: coverage. Anywhere magenta, the G-buffer has no data and no screen
    //    space technique can reach - this is the map of where SSGI can work.
    if ( DBG_IS( 8 ) )
        return float4( SSGI_Luma( color.rgb ).xxx * 0.6f, 1.0f );

    // ---- joint bilateral upsample -------------------------------------------
    // Bottom-left of the 2x2 low res quad this pixel sits in, plus the bilinear
    // fractions used as the base weights.
    float2 lowCoord = uv * g_SSGISize - 0.5f;
    float2 lowBase  = floor( lowCoord );
    float2 f        = lowCoord - lowBase;

    float4 bilin = float4( ( 1.0f - f.x ) * ( 1.0f - f.y ),
                                   f.x   * ( 1.0f - f.y ),
                           ( 1.0f - f.x ) *         f.y,
                                   f.x   *         f.y );

    // ps_3_0 has no bitwise ops, so the 2x2 offsets are a literal table.
    const float2 kQuad[4] = { float2( 0, 0 ), float2( 1, 0 ), float2( 0, 1 ), float2( 1, 1 ) };

    float invZTol = 1.0f / max( g_DepthTol * z * 0.01f, 1e-3f );

    float4 ssgi = 0.0f;
    float  wsum = 0.0f;

    [unroll]
    for ( int t = 0; t < 4; t++ )
    {
        float2 suv = ( lowBase + kQuad[t] + 0.5f ) * g_InvSSGISize;

        float4 swpd = tex2Dlod( WPDepthBuffer, float4( suv, 0, 0 ) );
        float  sz   = SSGI_LinearZ( swpd );
        float3 sn   = SSGI_DecodeNormal( tex2Dlod( NormalBuffer, float4( suv, 0, 0 ) ).rg );

        float wz = exp( -abs( z - sz ) * invZTol );
        float wn = pow( max( dot( n, sn ), 1e-4f ), g_NormalPow );
        float w  = bilin[t] * wz * wn + 1e-5f;

        ssgi += tex2Dlod( SSGIBuffer, float4( suv, 0, 0 ) ) * w;
        wsum += w;
    }
    ssgi /= wsum;

    float3 gi = max( ssgi.rgb, 0.0f ) * g_GIScale;
    float  ao = saturate( ssgi.a * g_AOScale );

    if ( DBG_IS( 1 ) ) return float4( gi, 1.0f );                       // indirect only
    if ( DBG_IS( 2 ) ) return float4( ( 1.0f - ao ).xxx, 1.0f );        // occlusion only
    if ( DBG_IS( 3 ) ) return float4( gi + ( 1.0f - ao ).xxx, 1.0f );   // both, unlit

    // ---- composite ----------------------------------------------------------
    float3 base = lerp( color.rgb, SSGI_ToLinear( color.rgb ), g_Linearise );

    // Occlusion belongs to the ambient term, but the framebuffer has direct and
    // indirect already summed and no way to separate them. Fading occlusion out
    // on bright pixels is the standard stand-in: it keeps sunlit surfaces from
    // being darkened by geometry that never shadowed them.
    ao *= saturate( 1.0f - SSGI_Luma( base ) * g_AOLightBias );

    // Same problem for the bounce: no albedo to reflect off, so the surface's
    // own shaded colour stands in and keeps the bounce tinted by the material
    // instead of washing everything towards white.
    float3 albedo = lerp( 1.0f.xxx, saturate( base * 2.0f ), g_AlbedoBleed );

    float3 result = base * ( 1.0f - ao ) + gi * albedo;
    result = lerp( result, SSGI_FromLinear( result ), g_Linearise );

    // ---- comparison views ---------------------------------------------------
    // 6: A/B split. Left of the divider is the untouched frame, right is the
    //    composite, so one screenshot carries both halves.
    if ( DBG_IS( 6 ) )
    {
        if ( uv.x < g_Split - g_InvFullSize.x ) return color;
        if ( uv.x < g_Split + g_InvFullSize.x ) return float4( 1.0f, 0.0f, 1.0f, 1.0f );
    }

    // 7: what the effect actually changed, amplified. This is the view that
    //    makes an otherwise invisible difference readable.
    if ( DBG_IS( 7 ) )
        return float4( abs( result - color.rgb ) * g_DiffGain, 1.0f );

    return float4( result, color.a );
}
