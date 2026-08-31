// ---------------------------------------------------------------------------
// Shared helpers for the SSGI passes.
//
// Every pass is a screenspace_general pixel shader paired with GShader's
// pp_vs30 vertex shader, so the register layout is fixed by the engine:
//
//   s0..s3          $basetexture, $texture1..$texture3
//   c0..c3          $c0..$c3
//   c4              texel size of $basetexture (engine supplied)
//   c11..c14        $viewprojmat
//   c15..c18        $invviewprojmat
//
// G-buffer layout (GShader library):
//   _rt_WPDepth         .rgb = 1/worldPos            .a = 1/linearZ
//   _rt_NormalsTangents .rg  = octahedral normal     .b = diamond tangent
//                       .a   = handedness sign
// ---------------------------------------------------------------------------
#ifndef SSGI_COMMON_H
#define SSGI_COMMON_H

// _rt_WPDepth.a for a sky pixel. The reconstruction writes 1/(rawDepth*4000)
// and the sky writes rawDepth exactly 1, so a sky pixel is exactly 1/4000.
#define SSGI_SKY 0.00025f

// Test for equality, NOT for "further than this".
//
// With r_shaderlib_depthbuffer on, the depth buffer is floating point and keeps
// counting past 1.0 - 4000-8000 units land in 1..2, and so on. Real geometry
// further away than 4000 units therefore stores a value *smaller* than the sky
// constant, so `a <= SSGI_SKY` silently throws away everything in the distance.
// GShader's own note puts it plainly: "the sky is equal to exactly depth == 1".
//
// A relative window instead of a bare == keeps it safe across drivers; it is
// tight enough to only cover about half a unit either side of the sky plane.
// a <= 0 catches texels the reconstruction never wrote.
#define SSGI_IS_SKY( a ) ( abs( (a) - SSGI_SKY ) < SSGI_SKY * 1e-4f || (a) <= 0.0f )

#define SSGI_PI     3.14159265f
#define SSGI_TWOPI  6.28318531f

// Octahedron normal decode - knarkowicz.wordpress.com/2014/04/16
float3 SSGI_DecodeNormal( float2 f )
{
    f = f * 2.0f - 1.0f;
    float3 n = float3( f.x, f.y, 1.0f - abs( f.x ) - abs( f.y ) );
    float t = saturate( -n.z );
    n.xy += n.xy >= 0.0f ? -t : t;
    return normalize( n );
}

// _rt_WPDepth stores reciprocals; unpack without dividing by zero on cleared
// texels (which read back as 0 and would otherwise produce inf).
float3 SSGI_WorldPos( float4 wpd ) { return 1.0f / wpd.rgb; }
float  SSGI_LinearZ ( float4 wpd ) { return 1.0f / max( wpd.a, 1e-7f ); }

float SSGI_Luma( float3 c ) { return dot( c, float3( 0.2126f, 0.7152f, 0.0722f ) ); }

// Cheap sRGB <-> linear. Exact pow(2.2) is not worth the ALU here and the
// squared form is what every Source-era GI hack uses.
float3 SSGI_ToLinear  ( float3 c ) { return c * c; }
float3 SSGI_FromLinear( float3 c ) { return sqrt( max( c, 0.0f ) ); }

#endif // SSGI_COMMON_H
