#include "build_common.hlsl"

「A」 // #defineとか、uniformとか、ヘルパー関数とか、君が追加したいもの群

float4 main( PS_INPUT i ) : COLOR
{ UNPACK_GBUFFER;

    「B」 // SSGI処理の結果をresultに格納したい

DRAW; }