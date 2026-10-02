#include <metal_stdlib>
using namespace metal;
struct U { float2 extent; int rotation; int bgra; float4 crop; float4 color; float4 range; };
struct R { float4 rect; float4 options; };
struct V { float4 position [[position]]; float2 uv; };
float3 displayEncoded(float3 rgb, constant U &u) {
    if(u.range.w==0) return rgb;
    float3 v=max(rgb,float3(0));
    float3 linear=select(pow((v+0.055)/1.055,float3(2.4)),v/12.92,v<=0.04045);
    return select(1.099*pow(linear,float3(0.45))-0.099,4.5*linear,linear<0.018);
}
float3 refined(float3 base, float2 uv, constant R &r, texture2d<float> image) {
    if(r.options.x==0 || any(uv<r.rect.xy) || any(uv>=r.rect.xy+r.rect.zw)) return base;
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float3 rgb=image.sample(s,clamp((uv-r.rect.xy)/r.rect.zw,r.options.zw,1-r.options.zw)).rgb;
    if(r.options.y==0) return rgb;
    float3 v=max(rgb,float3(0));
    float3 linear=select(pow((v+0.055)/1.055,float3(2.4)),v/12.92,v<=0.04045);
    return select(1.099*pow(linear,float3(0.45))-0.099,4.5*linear,linear<0.018);
}
vertex V vertexPicture(uint i [[vertex_id]], constant U &u [[buffer(0)]]) {
    float2 p[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
    float2 t[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
    float2 uv = t[i];
    if(u.rotation==1) uv=float2(uv.y,1-uv.x);
    if(u.rotation==2) uv=1-uv;
    if(u.rotation==3) uv=float2(1-uv.y,uv.x);
    V o; o.position=float4(p[i]*u.extent,0,1); o.uv=u.crop.xy+uv*u.crop.zw; return o;
}
fragment float4 fragmentNV12(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]], constant R &r [[buffer(1)]], texture2d<float> refinement [[texture(2)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 t=clamp(v.uv,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
    float l=(y.sample(s,t).r-u.color.z)*u.color.w;
    float2 c=(uv.sample(s,t).rg-float2(128.0/255.0))*u.range.x;
    float kr=u.color.x,kb=u.color.y,kg=1-kr-kb;
    return float4(refined(displayEncoded(float3(l+2*(1-kr)*c.y,l-2*kb*(1-kb)/kg*c.x-2*kr*(1-kr)/kg*c.y,l+2*(1-kb)*c.x),u),v.uv,r,refinement),1);
}
fragment float4 fragmentBGRA(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]], constant R &r [[buffer(1)]], texture2d<float> refinement [[texture(2)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 t=clamp(v.uv,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
    return float4(refined(displayEncoded(image.sample(s,t).rgb,u),v.uv,r,refinement),1);
}
