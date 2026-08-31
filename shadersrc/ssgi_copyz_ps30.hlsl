// Snapshot this frame's linear depth so next frame's temporal pass can test it
// for disocclusion. Written at the trace resolution into an R32F target.
#include "ssgi_common.h"

sampler WPDepthBuffer : register( s0 );   // _rt_WPDepth

const float4 C0 : register( c0 );   // xy = 1/rtSize

struct PS_INPUT
{
    float2 vPos : VPOS;
    float2 uv   : TEXCOORD0;
};

float4 main( PS_INPUT i ) : COLOR0
{
    float2 uv = ( i.vPos + 0.5f ) * C0.xy;
    return SSGI_LinearZ( tex2Dlod( WPDepthBuffer, float4( uv, 0, 0 ) ) ).xxxx;
}
