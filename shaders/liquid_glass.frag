#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform float u_corner_radius;
uniform float u_bezel_width;
uniform float u_refraction;
uniform float u_aberration;
uniform sampler2D u_texture_input;

out vec4 frag_color;

float roundedBoxSdf(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + vec2(radius);
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

vec2 toSampleUv(vec2 logicalPos, vec2 safeSize) {
  vec2 uv = clamp(logicalPos / safeSize, vec2(0.001), vec2(0.999));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  vec2 safeSize = max(u_size, vec2(1.0));
  vec2 pos = FlutterFragCoord().xy;
  vec2 halfSize = safeSize * 0.5;
  float r = min(u_corner_radius, min(halfSize.x, halfSize.y));
  vec2 centered = pos - halfSize;

  float dist = roundedBoxSdf(centered, halfSize, r);
  float bw = max(u_bezel_width, 1.0);

  // 中心平坦区保持零形变采样，保证容器内部文字 100% 清晰锐利
  if (dist < -bw || dist > 0.5) {
    frag_color = texture(u_texture_input, toSampleUv(pos, safeSize));
    return;
  }

  // 解析法线（指向形状外缘），避免数值差分出现像素阶梯噪点
  vec2 q = abs(centered) - halfSize + vec2(r);
  vec2 maxQ = max(q, 0.0);
  vec2 localNormal = length(maxQ) > 0.0001
      ? normalize(maxQ)
      : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
  vec2 normal = localNormal * sign(centered);

  // 弯月面凸边剖面：越接近物理边缘（dist -> 0），斜率折射越强
  float t = clamp((dist + bw) / bw, 0.0, 1.0);
  float curve = t * t * (3.0 - 2.0 * t);

  vec2 baseShift = normal * (curve * u_refraction);
  vec2 caShift = normal * (curve * u_aberration);

  float rCh = texture(u_texture_input, toSampleUv(pos - baseShift - caShift, safeSize)).r;
  vec4 center = texture(u_texture_input, toSampleUv(pos - baseShift, safeSize));
  float bCh = texture(u_texture_input, toSampleUv(pos - baseShift + caShift, safeSize)).b;

  vec3 refracted = vec3(rCh, center.g, bCh) + vec3(curve * 0.04);
  frag_color = vec4(clamp(refracted, 0.0, 1.0), center.a);
}
