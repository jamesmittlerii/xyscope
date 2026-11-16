#include <metal_stdlib>
using namespace metal;

struct Fullscreen {
    float4 position [[position]];
    float2 uv;
};

vertex Fullscreen fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    Fullscreen out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = float2(positions[vid].x * 0.5 + 0.5, 0.5 - positions[vid].y * 0.5);
    return out;
}

fragment float4 decay_fragment(Fullscreen in [[stage_in]],
                               texture2d<float> source [[texture(0)]],
                               constant float &decay [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float4 center = source.sample(nearest, in.uv);
    float4 around = source.sample(nearest, in.uv + float2(texel.x, 0.0))
                  + source.sample(nearest, in.uv - float2(texel.x, 0.0))
                  + source.sample(nearest, in.uv + float2(0.0, texel.y))
                  + source.sample(nearest, in.uv - float2(0.0, texel.y));
    constexpr float spread = 0.05;
    float4 softened = center * (1.0 - spread) + around * (spread * 0.25);
    return softened * decay;
}

struct BeamVarying {
    float4 position [[position]];
    float across;
};

vertex BeamVarying stroke_vertex(uint vid [[vertex_id]],
                                 const device float4 *vertices [[buffer(0)]]) {
    float4 sample = vertices[vid];
    BeamVarying out;
    out.position = float4(sample.xy, 0.0, 1.0);
    out.across = sample.z;
    return out;
}

fragment float4 stroke_fragment(BeamVarying in [[stage_in]]) {
    // across is -1 at one edge and +1 at the other. Width does not scale this down.
    float profile = exp(-in.across * in.across * 1.35);
    float3 color = float3(0.22, 0.62, 0.16) * profile;
    return float4(color, 1.0);
}

fragment float4 present_fragment(Fullscreen in [[stage_in]],
                                 texture2d<float> source [[texture(0)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler softened(filter::linear, address::clamp_to_edge);
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float3 core = source.sample(nearest, in.uv).rgb;

    float3 close = source.sample(softened, in.uv + texel * float2( 1.6, 0.0)).rgb
                 + source.sample(softened, in.uv + texel * float2(-1.6, 0.0)).rgb
                 + source.sample(softened, in.uv + texel * float2(0.0,  1.6)).rgb
                 + source.sample(softened, in.uv + texel * float2(0.0, -1.6)).rgb;
    close *= 0.25;

    float2 wideStep = texel * 3.2;
    float3 wide = source.sample(softened, in.uv + float2( wideStep.x,  wideStep.y)).rgb
                + source.sample(softened, in.uv + float2(-wideStep.x,  wideStep.y)).rgb
                + source.sample(softened, in.uv + float2( wideStep.x, -wideStep.y)).rgb
                + source.sample(softened, in.uv + float2(-wideStep.x, -wideStep.y)).rgb;
    wide *= 0.25;

    float3 color = core + close * float3(0.22, 0.48, 0.16) + wide * float3(0.08, 0.22, 0.06);
    color *= 4.2;
    color = color / (1.0 + color);
    return float4(color, 1.0);
}
