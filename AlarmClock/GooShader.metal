#include <metal_stdlib>
using namespace metal;

// Goo threshold: applied AFTER a blur. The blur spreads the digit shapes;
// this pass re-solidifies them (alpha pushed to 0 or 1), so where two digits
// come close their blurred edges merge into one liquid-looking shape.
[[ stitchable ]] half4 gooThreshold(float threshold, float edge, half4 color) {
    float a = smoothstep(threshold - edge, threshold + edge, (float)color.a);
    half3 rgb = half3(0.0h);
    if (color.a > (half)1e-4) {
        rgb = color.rgb / color.a;
    }
    half ha = (half)a;
    return half4(rgb * ha, ha);
}
