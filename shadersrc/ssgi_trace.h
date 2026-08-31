// ---------------------------------------------------------------------------
// SSGI trace pass - horizon search with a visibility bitmask.
//
// Therrien et al. 2023, "Screen Space Indirect Lighting with Visibility
// Bitmask" (arxiv.org/pdf/2301.11376). The paper keeps a 32 bit mask of which
// angular sectors of the hemisphere are already occluded, so an occluder only
// contributes light for the sectors it is the *first* to cover. That removes
// the double counting that makes plain HBAO/HBIL over-darken, and it lets light
// through gaps between separate occluders.
//
// ps_3_0 has no integer ops, so the mask is four float4s instead: 16 sectors
// holding fractional coverage. Fractional coverage is strictly better than
// hard bits here - it antialiases the sector boundaries, which is exactly the
// banding you would otherwise have to dither away.
//
// The sectors are uniform in sin^2(theta) rather than in theta. Under the
// cosine-weighted projected solid angle measure that makes every sector carry
// the same weight, so the integral is just (covered sectors / 16) and no acos
// is needed anywhere in the inner loop.
//
// Define SSGI_SLICES and SSGI_STEPS before including.
// ---------------------------------------------------------------------------
#include "ssgi_common.h"

sampler ColorBuffer   : register( s0 );   // _rt_FullFrameFB
sampler WPDepthBuffer : register( s1 );   // _rt_WPDepth
sampler NormalBuffer  : register( s2 );   // _rt_NormalsTangents
sampler NoiseBuffer   : register( s3 );   // ssgi_bluenoise (64x64, wrapped)

const float4 C0 : register( c0 );   // xy = 1/rtSize   zw = rtSize
const float4 C1 : register( c1 );   // x = radius   y = projScale    z = thickness   w = minRadiusPx
const float4 C2 : register( c2 );   // x = frame    y = maxRadiusPx  zw = unused
const float4 C3 : register( c3 );   // xyz = eyePos                                 w = linearise

#define g_InvRTSize     C0.xy
#define g_RTSize        C0.zw
#define g_Radius        C1.x
#define g_ProjScale     C1.y
#define g_Thickness     C1.z
#define g_MinRadiusPx   C1.w
#define g_Frame         C2.x
#define g_MaxRadiusPx   C2.y
#define g_EyePos        C3.xyz
#define g_Linearise     C3.w

// Sector index vectors - 16 sectors across the hemisphere.
static const float4 kSect0 = float4(  0.0f,  1.0f,  2.0f,  3.0f );
static const float4 kSect1 = float4(  4.0f,  5.0f,  6.0f,  7.0f );
static const float4 kSect2 = float4(  8.0f,  9.0f, 10.0f, 11.0f );
static const float4 kSect3 = float4( 12.0f, 13.0f, 14.0f, 15.0f );
#define SSGI_NSECT    16.0f
#define SSGI_INVNSECT 0.0625f

struct PS_INPUT
{
    float2 vPos : VPOS;
    float2 uv   : TEXCOORD0;
};

float4 main( PS_INPUT i ) : COLOR0
{
    float2 uv = ( i.vPos + 0.5f ) * g_InvRTSize;

    float4 wpd = tex2Dlod( WPDepthBuffer, float4( uv, 0, 0 ) );
    if ( SSGI_IS_SKY( wpd.a ) ) return 0.0f;

    float3 P  = SSGI_WorldPos( wpd );
    float  z  = SSGI_LinearZ( wpd );
    float3 N  = SSGI_DecodeNormal( tex2Dlod( NormalBuffer, float4( uv, 0, 0 ) ).rg );
    float3 V  = normalize( g_EyePos - P );   // towards the camera

    // World radius projected to screen pixels, then clamped at both ends: the
    // cap stops nearby surfaces from marching across the whole screen, the floor
    // stops distant surfaces from falling off a cliff into no effect at all.
    //
    // Clamping changes how far the march actually reaches, so the world radius
    // has to be recomputed from the clamped pixel radius. Skipping that step is
    // what makes occlusion visibly change size and snap as you walk towards a
    // wall: the march is clamped but the falloff still uses the radius it asked
    // for, and the two disagree by more and more.
    float radiusPx    = clamp( g_Radius * g_ProjScale / z, g_MinRadiusPx, g_MaxRadiusPx );
    float worldRadius = radiusPx * z / g_ProjScale;
    float invRadius   = 1.0f / worldRadius;

    // Blue noise, decorrelated per frame with the R2 low discrepancy sequence.
    float2 bn = tex2Dlod( NoiseBuffer, float4( ( i.vPos + 0.5f ) * 0.015625f, 0, 0 ) ).rg;
    bn = frac( bn + g_Frame * float2( 0.7548776662f, 0.5698402909f ) );

    float  stepPx = max( radiusPx / (float)SSGI_STEPS, 1.0f );
    float3 giSum  = 0.0f;
    float  aoSum  = 0.0f;

    // SSGI_SLICES is always even, so slice k and slice k + SLICES/2 point in
    // exactly opposite directions. Antithetic pairs like that cancel most of the
    // first order error in a horizon search, which is what stops the result
    // swinging around as the camera rotates.
    [loop]
    for ( int sl = 0; sl < SSGI_SLICES; sl++ )
    {
        float  phi = ( (float)sl + bn.x ) * ( SSGI_TWOPI / (float)SSGI_SLICES );
        float  sinPhi, cosPhi;
        sincos( phi, sinPhi, cosPhi );
        float2 dirUV = float2( cosPhi, sinPhi ) * stepPx * g_InvRTSize;

        float4 m0 = 0.0f, m1 = 0.0f, m2 = 0.0f, m3 = 0.0f;
        float2 suv = uv + dirUV * bn.y;

        [loop]
        for ( int st = 0; st < SSGI_STEPS; st++ )
        {
            suv += dirUV;
            if ( suv.x < 0.0f || suv.x > 1.0f || suv.y < 0.0f || suv.y > 1.0f ) break;

            float4 swpd = tex2Dlod( WPDepthBuffer, float4( suv, 0, 0 ) );

            float3 S    = SSGI_WorldPos( swpd );
            float3 d    = S - P;
            float  dist = length( d );
            float3 Vf   = d / max( dist, 1e-4f );

            float cF = dot( N, Vf );

            // Reject sky, degenerate taps and anything below the tangent plane.
            float valid = ( !SSGI_IS_SKY( swpd.a ) && dist > 1e-3f && cF > 0.02f ) ? 1.0f : 0.0f;

            // Assumed occluder thickness: the far side of the sample, pushed
            // directly away from the camera. Without it every occluder would be
            // treated as an infinite wall.
            float3 Vb = normalize( ( S - V * g_Thickness ) - P );
            float cB  = saturate( dot( N, Vb ) );
            cF = saturate( cF );

            // Sector coordinates. sin^2(theta) = 1 - cos^2(theta), and the
            // sectors are uniform in that measure.
            float sF = 1.0f - cF * cF;
            float sB = 1.0f - cB * cB;
            float a  = min( sF, sB ) * SSGI_NSECT;
            float b  = max( sF, sB ) * SSGI_NSECT;

            // Distance falloff, squared so the edge of the radius is soft.
            float atten = saturate( 1.0f - dist * invRadius );
            atten *= atten * valid;

            float4 o0 = saturate( min( b, kSect0 + 1.0f ) - max( a, kSect0 ) ) * atten;
            float4 o1 = saturate( min( b, kSect1 + 1.0f ) - max( a, kSect1 ) ) * atten;
            float4 o2 = saturate( min( b, kSect2 + 1.0f ) - max( a, kSect2 ) ) * atten;
            float4 o3 = saturate( min( b, kSect3 + 1.0f ) - max( a, kSect3 ) ) * atten;

            // Only sectors this occluder is the first to cover carry light.
            float newCov = dot( saturate( o0 - m0 ), 1.0f )
                         + dot( saturate( o1 - m1 ), 1.0f )
                         + dot( saturate( o2 - m2 ), 1.0f )
                         + dot( saturate( o3 - m3 ), 1.0f );

            m0 = max( m0, o0 );
            m1 = max( m1, o1 );
            m2 = max( m2, o2 );
            m3 = max( m3, o3 );

            [branch]
            if ( newCov > 0.0f )
            {
                float3 Nf = SSGI_DecodeNormal( tex2Dlod( NormalBuffer, float4( suv, 0, 0 ) ).rg );
                float  bounce = saturate( dot( Nf, -Vf ) );   // occluder faces us

                float3 c = tex2Dlod( ColorBuffer, float4( suv, 0, 0 ) ).rgb;
                c = lerp( c, SSGI_ToLinear( c ), g_Linearise );

                giSum += c * ( newCov * SSGI_INVNSECT * bounce );
            }
        }

        aoSum += ( dot( m0, 1.0f ) + dot( m1, 1.0f ) + dot( m2, 1.0f ) + dot( m3, 1.0f ) ) * SSGI_INVNSECT;
    }

    // Intensity is deliberately not applied here: it belongs to the composite
    // so that tweaking it does not force the temporal history to reconverge.
    float invSlices = 1.0f / (float)SSGI_SLICES;
    return float4( giSum * invSlices, saturate( aoSum * invSlices ) );
}
