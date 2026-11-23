#include <metal_stdlib>
using namespace metal;

// ============================================================================
//  Deep Multi-Bounce Mirror Ray Tracer — 4 Optical Mirror Chambers
//  Designed for Apple Silicon (M5 Max) high-bounce HDR + Bloom + ACES + FXAA
// ============================================================================

struct MirrorParams {
    uint width;
    uint height;
    uint scene_id;     // 0=Platonic Portal, 1=Wada Spheres, 2=Coxeter/Hyperbolic, 3=Dichroic Room
    uint max_bounces;  // 8..64
    uint coating_mode; // 0=Dichroic Rainbow, 1=Architectural Green, 2=Gold-Cobalt, 3=Pure Silver
    uint spp;          // 1, 4, or 9
    uint view_mode;    // 0=Inside Chamber, 1=Outside Portal
    uint frame_index;
    float time;
    float fov;
    float morph_param; // 0..1 scene-specific geometry/optical slider
    float exposure;
    float4 cam_pos;     // xyz = pos, w = roll
    float4 cam_forward; // xyz = forward
    float4 cam_right;   // xyz = right
    float4 cam_up;      // xyz = up
};

constant float PI  = 3.14159265359f;
constant float TAU = 6.28318530718f;
constant float PHI = 1.61803398875f;

// ============================================================================
//  Math & Spectral Optical Helpers
// ============================================================================

inline float3x3 rotY(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(c, 0.0f, s), float3(0.0f, 1.0f, 0.0f), float3(-s, 0.0f, c));
}

inline float3x3 rotX(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(1.0f, 0.0f, 0.0f), float3(0.0f, c, -s), float3(0.0f, s, c));
}

inline float3x3 rotZ(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(c, -s, 0.0f), float3(s, c, 0.0f), float3(0.0f, 0.0f, 1.0f));
}

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

inline float3 paletteCos(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(TAU * (c * t + d));
}

/// Physically inspired angle-dependent thin-film / mirror reflectance per bounce.
inline float3 mirrorReflectance(float cosTheta, uint bounce, uint coatingMode, float morph, float time) {
    float ct = clamp(cosTheta, 0.02f, 1.0f);
    float fresnel = pow(1.0f - ct, 4.0f);

    if (coatingMode == 0u) {
        // Dichroic Thin-Film Interference (R=630nm, G=532nm, B=455nm)
        float nFilm = 1.62f;
        float sinT2 = max(0.0f, 1.0f - ct * ct) / (nFilm * nFilm);
        float cosT = sqrt(max(0.01f, 1.0f - sinT2));
        float thicknessNm = 340.0f + 260.0f * morph + 35.0f * sin(time * 0.25f);
        float opd = 2.0f * nFilm * thicknessNm * cosT;
        float3 lambda = float3(630.0f, 532.0f, 455.0f);
        float3 phase = TAU * opd / lambda;
        float3 irid = 0.5f + 0.5f * cos(phase);
        // Keep base reflectivity high (~0.91-0.96) so 48+ bounces stay deep & luminous
        float3 baseR = mix(float3(0.84f, 0.87f, 0.91f), float3(0.955f, 0.965f, 0.975f), 0.35f + 0.65f * irid);
        return mix(baseR, float3(0.97f), 0.35f * fresnel);
    } else if (coatingMode == 1u) {
        // Classic Museum Two-Way Architectural Green Glass Mirror (iron-oxide soda-lime tint)
        float3 sodaLime = float3(0.895f, 0.958f, 0.942f);
        return mix(sodaLime, float3(0.96f, 0.98f, 0.97f), 0.30f * fresnel);
    } else if (coatingMode == 2u) {
        // Gold-Cobalt Spectral Mirror (warm gold at normal incidence, electric sapphire at grazing)
        float3 warmGold = float3(0.965f, 0.905f, 0.805f);
        float3 cobalt   = float3(0.76f, 0.88f, 0.985f);
        float shift = clamp(fresnel * 1.45f + 0.15f * sin(float(bounce) * 0.35f + time * 0.3f), 0.0f, 1.0f);
        return mix(warmGold, cobalt, shift);
    } else {
        // Pure Crystal Silver Mirror (high neutral reflectance for crisp geometric structure)
        return float3(0.948f, 0.952f, 0.958f);
    }
}

// Analytical ray-sphere intersection: returns nearest positive t, or -1.0
inline float intersectSphere(float3 ro, float3 rd, float3 center, float radius, thread float3 &outN) {
    float3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;
    if (h < 0.0f) return -1.0f;
    float sh = sqrt(h);
    float t = -b - sh;
    if (t < 1e-4f) t = -b + sh;
    if (t < 1e-4f) return -1.0f;
    float3 p = ro + rd * t;
    outN = normalize(p - center);
    if (dot(outN, rd) > 0.0f) outN = -outN;
    return t;
}

// Analytical ray-torus-like thin glowing ring (disc ring in a tilted plane)
inline float intersectGlowRing(
    float3 ro, float3 rd,
    float3 center, float3 axisN,
    float radius, float tubeHalfW,
    thread float &outRadialDist
) {
    float denom = dot(rd, axisN);
    if (abs(denom) < 1e-5f) return -1.0f;
    float t = dot(center - ro, axisN) / denom;
    if (t < 1e-4f) return -1.0f;
    float3 p = ro + rd * t - center;
    float r = length(p);
    float d = abs(r - radius);
    if (d <= tubeHalfW) {
        outRadialDist = d / tubeHalfW;
        return t;
    }
    return -1.0f;
}

// ============================================================================
//  SCENE 0: Platonic Infinity Portal (Dodecahedron <-> Icosidodecahedron <-> Icosahedron)
//  32 analytical half-spaces: 12 Dodecahedron planes + 20 Icosahedron planes
// ============================================================================

constant float3 PLATONIC_N[32] = {
    // 0..11: Regular Dodecahedron normals
    float3( 0.0f,  0.52573111f,  0.85065081f), float3( 0.0f, -0.52573111f,  0.85065081f),
    float3( 0.0f,  0.52573111f, -0.85065081f), float3( 0.0f, -0.52573111f, -0.85065081f),
    float3( 0.52573111f,  0.85065081f,  0.0f), float3(-0.52573111f,  0.85065081f,  0.0f),
    float3( 0.52573111f, -0.85065081f,  0.0f), float3(-0.52573111f, -0.85065081f,  0.0f),
    float3( 0.85065081f,  0.0f,  0.52573111f), float3( 0.85065081f,  0.0f, -0.52573111f),
    float3(-0.85065081f,  0.0f,  0.52573111f), float3(-0.85065081f,  0.0f, -0.52573111f),
    // 12..31: Regular Icosahedron normals
    float3( 0.57735027f,  0.57735027f,  0.57735027f), float3( 0.57735027f,  0.57735027f, -0.57735027f),
    float3( 0.57735027f, -0.57735027f,  0.57735027f), float3( 0.57735027f, -0.57735027f, -0.57735027f),
    float3(-0.57735027f,  0.57735027f,  0.57735027f), float3(-0.57735027f,  0.57735027f, -0.57735027f),
    float3(-0.57735027f, -0.57735027f,  0.57735027f), float3(-0.57735027f, -0.57735027f, -0.57735027f),
    float3( 0.0f,  0.35682209f,  0.93417236f), float3( 0.0f, -0.35682209f,  0.93417236f),
    float3( 0.0f,  0.35682209f, -0.93417236f), float3( 0.0f, -0.35682209f, -0.93417236f),
    float3( 0.35682209f,  0.93417236f,  0.0f), float3(-0.35682209f,  0.93417236f,  0.0f),
    float3( 0.35682209f, -0.93417236f,  0.0f), float3(-0.35682209f, -0.93417236f,  0.0f),
    float3( 0.93417236f,  0.0f,  0.35682209f), float3( 0.93417236f,  0.0f, -0.35682209f),
    float3(-0.93417236f,  0.0f,  0.35682209f), float3(-0.93417236f,  0.0f, -0.35682209f)
};

inline float3 getPlatonicNormal(int idx) {
    return PLATONIC_N[idx];
}

inline float getPlatonicPlaneDist(int idx, float morph) {
    // Smooth morph:
    // morph = 0.0 -> Pure Dodecahedron (dDod=2.2, dIco=3.1)
    // morph = 0.5 -> Icosidodecahedron (dDod=2.2, dIco=2.2) — 32-face star chamber!
    // morph = 1.0 -> Pure Icosahedron (dDod=3.1, dIco=2.2)
    float dDod = mix(2.20f, 2.95f, smoothstep(0.45f, 1.0f, morph));
    float dIco = mix(2.95f, 2.20f, smoothstep(0.0f, 0.55f, morph));
    return (idx < 12) ? dDod : dIco;
}

struct PlatonicFrame {
    float3x3 fwdRot;
    float3x3 invRot;
    float3 ringAxis1;
    float3 ringAxis2;
    float3 sphereCenter;
    float dDod;
    float dIco;
    int pStart;
    int pEnd;
};

inline PlatonicFrame buildPlatonicFrame(constant MirrorParams &P) {
    PlatonicFrame F;
    F.fwdRot = float3x3(float3(1.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f), float3(0.0f, 0.0f, 1.0f));
    F.invRot = F.fwdRot;
    if (P.view_mode == 1u) {
        float ry = P.time * 0.14f;
        float rx = 0.22f * sin(P.time * 0.11f);
        F.fwdRot = rotY(ry) * rotX(rx);
        F.invRot = transpose(F.fwdRot);
    }
    F.ringAxis1 = normalize(rotY(P.time * 0.35f) * rotX(0.65f) * float3(0.0f, 1.0f, 0.0f));
    F.ringAxis2 = normalize(rotZ(-P.time * 0.27f) * rotY(0.95f) * float3(1.0f, 0.0f, 0.0f));
    F.sphereCenter = float3(0.0f, 0.14f * sin(P.time * 0.7f), 0.0f);
    F.dDod = mix(2.20f, 2.95f, smoothstep(0.45f, 1.0f, P.morph_param));
    F.dIco = mix(2.95f, 2.20f, smoothstep(0.0f, 0.55f, P.morph_param));
    F.pStart = (P.morph_param > 0.98f) ? 12 : 0;
    F.pEnd   = (P.morph_param < 0.02f) ? 12 : 32;
    return F;
}

float3 tracePlatonicPortal(float3 roWorld, float3 rdWorld, constant MirrorParams &P, thread const PlatonicFrame &F) {
    float3 col = float3(0.0f);
    float3 throughput = float3(1.0f);

    float3 ro = (P.view_mode == 1u) ? (F.invRot * roWorld) : roWorld;
    float3 rd = (P.view_mode == 1u) ? normalize(F.invRot * rdWorld) : rdWorld;

    if (P.view_mode == 1u) {
        float tNear = -1e9f;
        float tFar  =  1e9f;
        int hitFace = -1;
        for (int i = F.pStart; i < F.pEnd; ++i) {
            float3 n = PLATONIC_N[i];
            float d = (i < 12) ? F.dDod : F.dIco;
            float denom = dot(rd, n);
            float numer = d - dot(ro, n);
            if (abs(denom) < 1e-6f) {
                if (numer < 0.0f) return float3(0.012f, 0.014f, 0.020f);
            } else {
                float t = numer / denom;
                if (denom < 0.0f) {
                    if (t > tNear) { tNear = t; hitFace = i; }
                } else {
                    if (t < tFar) tFar = t;
                }
            }
        }
        if (tNear > tFar || tFar < 0.0f || hitFace < 0) {
            float grad = clamp(rdWorld.y * 0.5f + 0.5f, 0.0f, 1.0f);
            float floorGlow = exp(-abs(rdWorld.y + 0.25f) * 9.0f) * 0.045f;
            return mix(float3(0.008f, 0.010f, 0.016f), float3(0.022f, 0.026f, 0.038f), grad) + float3(0.06f, 0.08f, 0.12f) * floorGlow;
        }
        if (tNear > 1e-4f) {
            float3 pHit = ro + rd * tNear;
            float3 nOut = PLATONIC_N[hitFace];
            float minEdge = 1e9f;
            for (int j = F.pStart; j < F.pEnd; ++j) {
                if (j == hitFace) continue;
                float3 nJ = PLATONIC_N[j];
                if (dot(nOut, nJ) < 0.20f) continue;
                float gap = ((j < 12) ? F.dDod : F.dIco) - dot(pHit, nJ);
                if (gap < minEdge) minEdge = gap;
            }
            if (minEdge < 0.075f) {
                float3 rEnv = reflect(rdWorld, F.fwdRot * nOut);
                float spec = pow(max(0.0f, dot(rEnv, normalize(float3(0.5f, 0.8f, 0.4f)))), 28.0f);
                return float3(0.035f, 0.038f, 0.045f) + float3(0.45f, 0.50f, 0.60f) * spec;
            }
            float cosI = max(0.0f, dot(-rd, nOut));
            float fOut = 0.08f + 0.45f * pow(1.0f - cosI, 4.0f);
            float3 rEnv = reflect(rdWorld, F.fwdRot * nOut);
            float studioLight = pow(max(0.0f, dot(rEnv, normalize(float3(0.4f, 0.85f, 0.35f)))), 18.0f) * 0.45f
                              + pow(max(0.0f, dot(rEnv, normalize(float3(-0.7f, 0.4f, -0.5f)))), 10.0f) * 0.22f;
            col += float3(0.65f, 0.82f, 1.0f) * studioLight * fOut;
            throughput *= (1.0f - fOut * 0.55f);
            ro = pHit + rd * 2e-3f;
        }
    }

    const float sphereRadius = 0.44f;
    uint maxB = clamp(P.max_bounces, 4u, 64u);
    for (uint b = 0u; b < maxB; ++b) {
        float tPoly = 1e9f;
        int hitFace = -1;
        for (int i = F.pStart; i < F.pEnd; ++i) {
            float3 n = PLATONIC_N[i];
            float denom = dot(rd, n);
            if (denom > 1e-6f) {
                float d = (i < 12) ? F.dDod : F.dIco;
                float t = (d - dot(ro, n)) / denom;
                if (t > 1e-4f && t < tPoly) {
                    tPoly = t;
                    hitFace = i;
                }
            }
        }

        float3 nSph = float3(0.0f);
        float tSph = intersectSphere(ro, rd, F.sphereCenter, sphereRadius, nSph);

        float rDist1 = 0.0f, rDist2 = 0.0f;
        float tRing1 = intersectGlowRing(ro, rd, F.sphereCenter, F.ringAxis1, 0.92f, 0.018f, rDist1);
        float tRing2 = intersectGlowRing(ro, rd, F.sphereCenter, F.ringAxis2, 1.18f, 0.015f, rDist2);

        float tBest = tPoly;
        int kind = 0;
        if (tSph > 0.0f && tSph < tBest) { tBest = tSph; kind = 1; }
        if (tRing1 > 0.0f && tRing1 < tBest) { tBest = tRing1; kind = 2; }
        if (tRing2 > 0.0f && tRing2 < tBest) { tBest = tRing2; kind = 3; }

        if (kind == 2 || kind == 3) {
            float edgeFade = 1.0f - (kind == 2 ? rDist1 : rDist2);
            float3 ringCol = (kind == 2)
                ? float3(1.15f, 0.82f, 0.38f)
                : float3(0.28f, 0.88f, 1.25f);
            col += throughput * ringCol * (0.25f + 0.85f * edgeFade * edgeFade);
            throughput *= 0.35f;
            ro = ro + rd * (tBest + 2e-3f);
            if (max(throughput.r, max(throughput.g, throughput.b)) < 0.015f) break;
            continue;
        }

        if (kind == 1) {
            float3 pHit = ro + rd * tSph;
            float cosI = max(0.0f, dot(-rd, nSph));
            float eq = exp(-abs(dot(nSph, F.ringAxis1)) * 30.0f);
            col += throughput * float3(0.65f, 0.85f, 1.15f) * eq * 0.35f;
            throughput *= mirrorReflectance(cosI, b, P.coating_mode, P.morph_param, P.time) * 0.94f;
            ro = pHit + nSph * 1.5e-3f;
            rd = reflect(rd, nSph);
            if (max(throughput.r, max(throughput.g, throughput.b)) < 0.015f) break;
            continue;
        }

        if (hitFace < 0) break;
        float3 pHit = ro + rd * tPoly;
        float3 nOut = PLATONIC_N[hitFace];
        float3 nIn  = -nOut;

        // Only adjacent faces (dot > 0.20) can form edges/vertices with hitFace -> 2.5x-4x faster!
        float edge1 = 1e9f;
        float edge2 = 1e9f;
        for (int j = F.pStart; j < F.pEnd; ++j) {
            if (j == hitFace) continue;
            float3 nJ = PLATONIC_N[j];
            if (dot(nOut, nJ) < 0.20f) continue;
            float gap = ((j < 12) ? F.dDod : F.dIco) - dot(pHit, nJ);
            if (gap < edge1) {
                edge2 = edge1;
                edge1 = gap;
            } else if (gap < edge2) {
                edge2 = gap;
            }
        }

        float wave = 0.72f + 0.28f * sin(P.time * 1.35f + pHit.x * 1.4f + pHit.y * 1.7f - pHit.z * 1.1f);
        float edgeGlow = exp(-pow(edge1 / 0.017f, 2.0f));
        float sharpCore = smoothstep(0.015f, 0.003f, edge1);
        float vertexGlow = exp(-pow(edge2 / 0.036f, 2.0f)) * edgeGlow;

        float3 ledTint = (hitFace < 12)
            ? mix(float3(0.42f, 0.85f, 1.15f), float3(1.15f, 0.82f, 0.45f), 0.5f + 0.5f * sin(P.time * 0.28f + float(hitFace) * 0.52f))
            : mix(float3(0.32f, 1.05f, 0.88f), float3(0.95f, 0.48f, 1.25f), 0.5f + 0.5f * cos(P.time * 0.31f + float(hitFace) * 0.41f));

        col += throughput * ledTint * (edgeGlow * 0.34f + sharpCore * 0.72f) * wave;
        col += throughput * float3(1.25f, 1.15f, 1.05f) * vertexGlow * 0.65f;

        if (edge1 < 0.010f) {
            break;
        }

        float cosI = max(0.0f, dot(-rd, nIn));
        throughput *= mirrorReflectance(cosI, b, P.coating_mode, P.morph_param, P.time) * 0.935f;
        throughput *= exp(-tPoly * 0.022f);

        ro = pHit + nIn * 1.5e-3f;
        rd = reflect(rd, nIn);

        if (max(throughput.r, max(throughput.g, throughput.b)) < 0.015f) break;
    }

    return col;
}

// ============================================================================
//  SCENE 1: Wada Basin Chaotic Mirror Spheres (4 Mutually Tangent Mirror Spheres)
//  Exponential chaotic scattering between 4 curved mirrors -> infinite Wada fractals!
// ============================================================================

inline float3 evalWadaSky(float3 rd, float time, float morph) {
    // 4 tetrahedral opening directions (opposite the 4 sphere centers)
    const float s = 0.5773502692f;
    const float3 d0 = float3(-s, -s, -s);
    const float3 d1 = float3(-s,  s,  s);
    const float3 d2 = float3( s, -s,  s);
    const float3 d3 = float3( s,  s, -s);

    // Rotate the 4 colored portal domes slowly so the Wada fractal colors shimmer & breathe
    float3 r = rotY(time * 0.16f) * rotX(0.18f * sin(time * 0.12f)) * rd;

    float w0 = max(0.0f, dot(r, d0));
    float w1 = max(0.0f, dot(r, d1));
    float w2 = max(0.0f, dot(r, d2));
    float w3 = max(0.0f, dot(r, d3));

    // Sharpen each tetrahedral basin sky into a rich stained-glass dome with deep dark valleys
    float p = 4.4f;
    float e0 = pow(w0, p);
    float e1 = pow(w1, p);
    float e2 = pow(w2, p);
    float e3 = pow(w3, p);

    // Crisp concentric optical interference ribs inside each light portal for 4K reflection detail
    float a0 = acos(clamp(w0, -1.0f, 1.0f));
    float a1 = acos(clamp(w1, -1.0f, 1.0f));
    float a2 = acos(clamp(w2, -1.0f, 1.0f));
    float a3 = acos(clamp(w3, -1.0f, 1.0f));
    float ring0 = 0.58f + 0.42f * cos(a0 * 18.0f - time * 1.4f);
    float ring1 = 0.58f + 0.42f * cos(a1 * 18.0f - time * 1.2f);
    float ring2 = 0.58f + 0.42f * cos(a2 * 18.0f - time * 1.6f);
    float ring3 = 0.58f + 0.42f * cos(a3 * 18.0f - time * 1.1f);

    float3 c0 = float3(0.05f, 0.82f, 1.32f) * (e0 * ring0); // Electric Cyan-Sapphire
    float3 c1 = float3(1.35f, 0.12f, 0.58f) * (e1 * ring1); // Vivid Magenta-Rose
    float3 c2 = float3(1.38f, 0.82f, 0.10f) * (e2 * ring2); // Solar Amber-Gold
    float3 c3 = float3(0.10f, 1.28f, 0.62f) * (e3 * ring3); // Luminous Emerald-Mint

    // Controlled specular core in each gap (avoids pastel white clipping)
    float core = pow(max(max(w0, w1), max(w2, w3)), 32.0f) * (0.48f + 0.22f * morph);
    return (c0 + c1 + c2 + c3) * 1.08f + float3(1.0f, 0.96f, 0.92f) * core + float3(0.010f, 0.012f, 0.020f);
}

float3 traceWadaSpheres(float3 ro, float3 rd, constant MirrorParams &P) {
    // 4 spheres of radius R=1.0 placed at regular tetrahedron vertices
    // morph_param opens a subtle controllable gap (0.0002m = touching -> 0.16m = open fractal throat)
    float R = 1.0f;
    float gap = 0.0005f + 0.16f * P.morph_param;
    float s = (2.0f * R + gap) / (2.0f * sqrt(2.0f));
    float3 centers[4] = {
        float3( s,  s,  s),
        float3( s, -s, -s),
        float3(-s,  s, -s),
        float3(-s, -s,  s)
    };

    float3 col = float3(0.0f);
    float3 throughput = float3(1.0f);
    uint maxB = clamp(P.max_bounces, 4u, 64u);

    for (uint b = 0u; b < maxB; ++b) {
        float tMin = 1e9f;
        float3 nHit = float3(0.0f);
        int hitIdx = -1;

        for (int i = 0; i < 4; ++i) {
            float3 nTmp;
            float t = intersectSphere(ro, rd, centers[i], R, nTmp);
            if (t > 0.0f && t < tMin) {
                tMin = t;
                nHit = nTmp;
                hitIdx = i;
            }
        }

        if (hitIdx < 0) {
            // Escaped the 4-sphere chaotic trap -> sample the 4-color Wada light basin sky!
            float bounceBoost = 1.0f + 0.035f * min(float(b), 10.0f);
            col += throughput * evalWadaSky(rd, P.time, P.morph_param) * bounceBoost;
            break;
        }

        float3 pHit = ro + rd * tMin;
        float cosI = max(0.0f, dot(-rd, nHit));

        // Subtle emissive micro-ring right around the kissing points where spheres touch
        float minOtherD = 1e9f;
        for (int j = 0; j < 4; ++j) {
            if (j == hitIdx) continue;
            minOtherD = min(minOtherD, length(pHit - centers[j]) - R);
        }
        float kissGlow = exp(-max(0.0f, minOtherD) * 28.0f) * 0.14f;
        col += throughput * float3(1.0f, 0.92f, 0.80f) * kissGlow;

        throughput *= mirrorReflectance(cosI, b, P.coating_mode, P.morph_param, P.time);
        // Slightly higher retention for Wada basins so 40-64 bounce fractal filaments shine clearly
        throughput = min(throughput * 1.02f, float3(0.985f));

        ro = pHit + nHit * 1.0e-4f;
        rd = reflect(rd, nHit);

        if (max(throughput.r, max(throughput.g, throughput.b)) < 0.002f) break;
    }

    // Trapped rays that reach maxB right on the Cantor-like Wada boundary get a crisp pearlescent highlight
    if (length(col) < 1e-4f) {
        col = throughput * float3(0.75f, 0.78f, 0.95f);
    }
    return col;
}

// ============================================================================
//  SCENE 2: Coxeter Reflection Chamber & Hyperbolic Curved-Mirror Kaleidoscope
//  morph_param = 0.0 -> Exact flat 60-60-60 equilateral Coxeter prism (Euclidean tiling)
//  morph_param > 0.0 -> Smoothly curves the 3 walls into inward cylindrical mirrors (Hyperbolic!)
// ============================================================================

float3 traceCoxeterHyperbolic(float3 ro, float3 rd, constant MirrorParams &P) {
    float3 col = float3(0.0f);
    float3 throughput = float3(1.0f);

    // 3 mirror walls with 120-degree symmetry, inscribed radius rIn = 1.65
    const float rIn = 1.65f;
    const float yHalf = 2.45f;
    float curv = P.morph_param; // 0 = flat Coxeter, 1 = strongly curved hyperbolic chamber

    // Precompute 3 wall outward unit normals in XZ
    float3 wallN[3] = {
        float3( 0.0f,       0.0f,  1.0f),
        float3( 0.8660254f, 0.0f, -0.5f),
        float3(-0.8660254f, 0.0f, -0.5f)
    };

    // Animated floating jewel core inside the triangular kaleidoscope
    float3 orb1 = float3(0.42f * cos(P.time * 0.55f), 0.55f * sin(P.time * 0.42f), 0.42f * sin(P.time * 0.55f));
    float3 orb2 = float3(-0.38f * sin(P.time * 0.48f), -0.48f * cos(P.time * 0.37f), 0.38f * cos(P.time * 0.48f));
    float3 ringA = normalize(rotY(P.time * 0.40f) * float3(0.5f, 0.866f, 0.0f));
    float3 ringB = normalize(rotZ(-P.time * 0.33f) * float3(0.8f, 0.2f, 0.55f));

    uint maxB = clamp(P.max_bounces, 4u, 64u);
    for (uint b = 0u; b < maxB; ++b) {
        float tBest = 1e9f;
        float3 nBest = float3(0.0f);
        int hitKind = -1; // 0=side mirror, 1=cap mirror, 2=orb1, 3=orb2, 4=ringA, 5=ringB
        int hitWall = 0;

        // 1. Intersect 3 triangular walls (flat planes if curv < 0.01, else large vertical cylinders tangent at rIn!)
        if (curv < 0.015f) {
            for (int i = 0; i < 3; ++i) {
                float denom = dot(rd, wallN[i]);
                if (denom > 1e-6f) {
                    float t = (rIn - dot(ro, wallN[i])) / denom;
                    if (t > 1e-4f && t < tBest) {
                        tBest = t;
                        nBest = -wallN[i];
                        hitKind = 0;
                        hitWall = i;
                    }
                }
            }
        } else {
            // Convex inward-bulging cylinders centered outside each wall at (rIn + cylR) * wallN[i]
            // As curv -> 1.0, cylR shrinks from ~80m down to 2.2m, producing hyperbolic Poincaré arcs!
            float cylR = mix(42.0f, 2.25f, curv * curv);
            for (int i = 0; i < 3; ++i) {
                float2 cXZ = wallN[i].xz * (rIn + cylR);
                float2 oc = ro.xz - cXZ;
                float2 d2 = rd.xz;
                float a = dot(d2, d2);
                if (a > 1e-8f) {
                    float b2 = dot(oc, d2);
                    float c2 = dot(oc, oc) - cylR * cylR;
                    float h = b2 * b2 - a * c2;
                    if (h >= 0.0f) {
                        float sh = sqrt(h);
                        float t = (-b2 - sh) / a;
                        if (t > 1e-4f && t < tBest) {
                            float2 hitXZ = ro.xz + d2 * t;
                            float2 n2 = normalize(hitXZ - cXZ);
                            tBest = t;
                            nBest = float3(n2.x, 0.0f, n2.y);
                            hitKind = 0;
                            hitWall = i;
                        }
                    }
                }
            }
        }

        // 2. Floor & Ceiling mirrors (y = -yHalf, +yHalf)
        if (abs(rd.y) > 1e-6f) {
            float tTop = (yHalf - ro.y) / rd.y;
            if (tTop > 1e-4f && tTop < tBest) {
                tBest = tTop;
                nBest = float3(0.0f, -1.0f, 0.0f);
                hitKind = 1;
            }
            float tBot = (-yHalf - ro.y) / rd.y;
            if (tBot > 1e-4f && tBot < tBest) {
                tBest = tBot;
                nBest = float3(0.0f, 1.0f, 0.0f);
                hitKind = 1;
            }
        }

        // 3. Floating glowing orbs & neon rings inside the prism
        float3 nTmp;
        float tO1 = intersectSphere(ro, rd, orb1, 0.21f, nTmp);
        if (tO1 > 0.0f && tO1 < tBest) { tBest = tO1; nBest = nTmp; hitKind = 2; }
        float tO2 = intersectSphere(ro, rd, orb2, 0.17f, nTmp);
        if (tO2 > 0.0f && tO2 < tBest) { tBest = tO2; nBest = nTmp; hitKind = 3; }

        float rD1 = 0.0f, rD2 = 0.0f;
        float tR1 = intersectGlowRing(ro, rd, float3(0.0f, 0.15f * sin(P.time * 0.5f), 0.0f), ringA, 0.85f, 0.028f, rD1);
        if (tR1 > 0.0f && tR1 < tBest) { tBest = tR1; hitKind = 4; }
        float tR2 = intersectGlowRing(ro, rd, float3(0.0f, -0.20f * cos(P.time * 0.4f), 0.0f), ringB, 0.62f, 0.024f, rD2);
        if (tR2 > 0.0f && tR2 < tBest) { tBest = tR2; hitKind = 5; }

        if (hitKind < 0) break;

        if (hitKind == 2 || hitKind == 3) {
            // Sculpted glossy crystal jewel orbs (deep saturated core + Fresnel rim, zero white clipping)
            float ndv = max(0.0f, dot(-rd, nBest));
            float rim = pow(1.0f - ndv, 2.6f);
            float spec = pow(max(0.0f, dot(reflect(rd, nBest), normalize(float3(0.4f, 0.85f, -0.35f)))), 48.0f);
            float3 baseE = (hitKind == 2)
                ? float3(1.15f, 0.16f, 0.68f)  // deep ruby-magenta crystal
                : float3(0.08f, 0.88f, 1.18f); // deep aquamarine crystal
            col += throughput * (baseE * (0.22f + 0.55f * pow(ndv, 1.6f) + 0.95f * rim) + float3(1.0f, 0.96f, 0.92f) * spec * 0.95f);
            throughput *= 0.42f;
            ro = ro + rd * tBest + nBest * 1.5e-3f;
            rd = reflect(rd, nBest);
            if (max(throughput.r, max(throughput.g, throughput.b)) < 0.012f) break;
            continue;
        }

        if (hitKind == 4 || hitKind == 5) {
            float ef = 1.0f - (hitKind == 4 ? rD1 : rD2);
            float3 rc = (hitKind == 4)
                ? float3(1.25f, 0.88f, 0.24f)  // saturated golden filament
                : float3(0.20f, 1.18f, 0.72f); // saturated emerald filament
            col += throughput * rc * (0.28f + 0.95f * ef * ef);
            throughput *= 0.35f;
            ro = ro + rd * (tBest + 2e-3f);
            if (max(throughput.r, max(throughput.g, throughput.b)) < 0.012f) break;
            continue;
        }

        float3 pHit = ro + rd * tBest;

        if (hitKind == 0) {
            float nearY = yHalf - abs(pHit.y);
            float seamY = exp(-pow(nearY / 0.026f, 2.0f));
            float minCorner = 1e9f;
            for (int k = 0; k < 3; ++k) {
                if (k == hitWall) continue;
                minCorner = min(minCorner, abs(rIn - dot(pHit, wallN[k])));
            }
            float seamV = exp(-pow(minCorner / 0.032f, 2.0f));
            float3 seamCol = paletteCos(
                float(hitWall) * 0.33f + P.time * 0.07f + pHit.y * 0.12f,
                float3(0.55f, 0.55f, 0.72f),
                float3(0.45f, 0.42f, 0.48f),
                float3(1.0f, 1.0f, 1.0f),
                float3(0.05f, 0.33f, 0.67f)
            );
            col += throughput * seamCol * (seamY * 0.38f + seamV * 0.48f);
        } else {
            float r2 = length(pHit.xz);
            float ringEtch = exp(-pow(abs(fract(r2 * 0.85f - P.time * 0.12f) - 0.5f) / 0.020f, 2.0f)) * 0.22f;
            col += throughput * float3(0.65f, 0.95f, 1.35f) * ringEtch;
        }

        float cosI = max(0.0f, dot(-rd, nBest));
        throughput *= mirrorReflectance(cosI, b, P.coating_mode, P.morph_param, P.time) * 0.935f;
        throughput *= exp(-tBest * 0.018f);

        ro = pHit + nBest * 1.5e-3f;
        rd = reflect(rd, nBest);

        if (max(throughput.r, max(throughput.g, throughput.b)) < 0.015f) break;
    }

    return col;
}

// ============================================================================
//  SCENE 3: Dichroic Infinity Mirror Room (Kusama-inspired Architectural Hall)
//  Octagonal dichroic mirror hall + 16 floating starlight lanterns + central crystal spire
// ============================================================================

struct RoomFrame {
    float3 lanternPos[12];
    float3 lanternCol[12];
    float  lanternRad2[12];
    float3 centerRingN;
};

inline RoomFrame buildRoomFrame(constant MirrorParams &P) {
    RoomFrame F;
    for (int i = 0; i < 12; ++i) {
        float fi = float(i);
        float ang = fi * 2.3999632f + P.time * (0.09f + 0.02f * fract(fi * 0.37f));
        float rad = 0.78f + 1.85f * sqrt((fi + 0.5f) / 12.0f);
        float y = -1.15f + 2.55f * fract(fi * 0.618034f) + 0.16f * sin(P.time * 0.75f + fi * 1.3f);
        F.lanternPos[i] = float3(cos(ang) * rad, y, sin(ang) * rad);
        float lr = 0.085f + 0.045f * fract(fi * 0.43f);
        F.lanternRad2[i] = lr * lr;
        float hue = fract(fi * 0.21f + P.time * 0.03f);
        F.lanternCol[i] = paletteCos(
            hue,
            float3(0.72f, 0.58f, 0.68f),
            float3(0.55f, 0.50f, 0.58f),
            float3(1.0f, 1.0f, 1.0f),
            float3(0.00f, 0.28f, 0.58f)
        ) * 1.18f;
    }
    F.centerRingN = normalize(rotY(P.time * 0.22f) * float3(0.32f, 0.95f, 0.0f));
    return F;
}

float3 traceDichroicRoom(float3 ro, float3 rd, constant MirrorParams &P, thread const RoomFrame &F) {
    float3 col = float3(0.0f);
    float3 throughput = float3(1.0f);

    const float octR = 3.25f;
    const float floorY = -1.95f;
    const float ceilY  =  2.25f;

    const float3 octN[8] = {
        float3( 1.0f, 0.0f,  0.0f), float3( 0.70710678f, 0.0f,  0.70710678f),
        float3( 0.0f, 0.0f,  1.0f), float3(-0.70710678f, 0.0f,  0.70710678f),
        float3(-1.0f, 0.0f,  0.0f), float3(-0.70710678f, 0.0f, -0.70710678f),
        float3( 0.0f, 0.0f, -1.0f), float3( 0.70710678f, 0.0f, -0.70710678f)
    };

    uint maxB = clamp(P.max_bounces, 4u, 64u);
    for (uint b = 0u; b < maxB; ++b) {
        float tBest = 1e9f;
        float3 nBest = float3(0.0f);
        int hitKind = -1;
        int hitIdx = 0;

        for (int i = 0; i < 8; ++i) {
            float denom = dot(rd, octN[i]);
            if (denom > 1e-6f) {
                float t = (octR - dot(ro, octN[i])) / denom;
                if (t > 1e-4f && t < tBest) {
                    tBest = t;
                    nBest = -octN[i];
                    hitKind = 0;
                    hitIdx = i;
                }
            }
        }

        if (abs(rd.y) > 1e-6f) {
            float tC = (ceilY - ro.y) / rd.y;
            if (tC > 1e-4f && tC < tBest) { tBest = tC; nBest = float3(0.0f, -1.0f, 0.0f); hitKind = 1; hitIdx = 1; }
            float tF = (floorY - ro.y) / rd.y;
            if (tF > 1e-4f && tF < tBest) { tBest = tF; nBest = float3(0.0f,  1.0f, 0.0f); hitKind = 1; hitIdx = 0; }
        }

        // Deferred-normal fast sphere loop over 12 lanterns (skips rsqrt/normalize until winning hit!)
        for (int i = 0; i < 12; ++i) {
            float3 oc = ro - F.lanternPos[i];
            float b2 = dot(oc, rd);
            if (b2 > 0.0f) continue;
            float c2 = dot(oc, oc) - F.lanternRad2[i];
            float h = b2 * b2 - c2;
            if (h > 0.0f) {
                float tL = -b2 - sqrt(h);
                if (tL > 1e-4f && tL < tBest) {
                    tBest = tL;
                    hitKind = 2;
                    hitIdx = i;
                }
            }
        }

        float3 nCs;
        float tCs = intersectSphere(ro, rd, float3(0.0f, 0.15f, 0.0f), 0.42f, nCs);
        if (tCs > 0.0f && tCs < tBest) { tBest = tCs; nBest = nCs; hitKind = 3; }

        float rD = 0.0f;
        float tCr = intersectGlowRing(ro, rd, float3(0.0f, 0.15f, 0.0f), F.centerRingN, 0.88f, 0.018f, rD);
        if (tCr > 0.0f && tCr < tBest) { tBest = tCr; hitKind = 4; }

        if (hitKind < 0) break;

        if (hitKind == 2) {
            float3 nLan = normalize(ro + rd * tBest - F.lanternPos[hitIdx]);
            float ndv = max(0.0f, dot(-rd, nLan));
            float filament = pow(ndv, 5.5f);
            float glassBody = 0.28f + 0.68f * pow(ndv, 1.2f);
            float rim = pow(1.0f - ndv, 3.0f) * 0.45f;
            col += throughput * (F.lanternCol[hitIdx] * (glassBody + rim) + float3(1.15f, 1.05f, 0.90f) * filament * 0.65f);
            break;
        }

        if (hitKind == 4) {
            float ef = 1.0f - rD;
            col += throughput * float3(1.45f, 1.15f, 0.65f) * (0.35f + 1.15f * ef * ef);
            throughput *= 0.35f;
            ro = ro + rd * (tBest + 2e-3f);
            if (max(throughput.r, max(throughput.g, throughput.b)) < 0.015f) break;
            continue;
        }

        float3 pHit = ro + rd * tBest;

        if (hitKind == 0) {
            float dNext = abs(octR - dot(pHit, octN[(hitIdx + 1) & 7]));
            float dPrev = abs(octR - dot(pHit, octN[(hitIdx + 7) & 7]));
            float cornerD = min(dNext, dPrev);
            float verticalD = min(abs(pHit.y - ceilY), abs(pHit.y - floorY));

            float pillarGlow = exp(-pow(cornerD / 0.024f, 2.0f));
            float trimGlow   = exp(-pow(verticalD / 0.022f, 2.0f));
            col += throughput * float3(0.55f, 0.78f, 1.25f) * (pillarGlow * 0.32f + trimGlow * 0.25f);
        } else if (hitKind == 1 && hitIdx == 0) {
            float rippleAmp = 0.012f * P.morph_param;
            if (rippleAmp > 1e-4f) {
                float r = length(pHit.xz);
                float wave = sin(r * 6.5f - P.time * 1.6f) * rippleAmp;
                nBest = normalize(float3(pHit.x * wave, 1.0f, pHit.z * wave));
            }
        }

        float cosI = max(0.0f, dot(-rd, nBest));
        throughput *= mirrorReflectance(cosI, b, P.coating_mode, P.morph_param, P.time) * 0.935f;
        throughput *= exp(-tBest * 0.015f);

        ro = pHit + nBest * 1.5e-3f;
        rd = reflect(rd, nBest);

        if (max(throughput.r, max(throughput.g, throughput.b)) < 0.015f) break;
    }

    return col;
}

// ============================================================================
//  SCENE 4 (Key 5): Jack Storms Cold-Worked Dichroic Optical Crystal Cube
//  High-IOR Lead Crystal (n=1.72, RGB Cauchy dispersion) + TIR + 8 Internal Dichroic Lamellae
// ============================================================================

inline float3 evalStudioGallerySky(float3 rd) {
    float3 d = normalize(rd);
    float topBox   = smoothstep(0.76f, 0.94f, d.y) * smoothstep(0.32f, 0.10f, abs(d.x)) * smoothstep(0.38f, 0.10f, abs(d.z));
    float keyStrip = pow(max(0.0f, dot(d, normalize(float3( 0.72f, 0.48f, -0.50f)))), 42.0f);
    float rimStrip = pow(max(0.0f, dot(d, normalize(float3(-0.75f, 0.35f,  0.55f)))), 36.0f);
    float3 base = mix(float3(0.008f, 0.010f, 0.016f), float3(0.022f, 0.026f, 0.040f), d.y * 0.5f + 0.5f);
    return base
        + float3(1.65f, 1.62f, 1.55f) * topBox
        + float3(2.20f, 1.55f, 0.95f) * keyStrip
        + float3(0.75f, 1.55f, 2.40f) * rimStrip;
}

inline float intersectCube(float3 ro, float3 rd, float halfS, thread float3 &outN, thread bool &inside) {
    float3 invD = 1.0f / select(rd, float3(1e-6f), abs(rd) < 1e-6f);
    float3 t0 = (-halfS - ro) * invD;
    float3 t1 = ( halfS - ro) * invD;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    float tNear = max(max(tmin.x, tmin.y), tmin.z);
    float tFar  = min(min(tmax.x, tmax.y), tmax.z);
    if (tFar < max(tNear, 1e-4f)) return -1.0f;

    inside = (tNear < 1e-4f);
    float tHit = inside ? tFar : tNear;
    float3 p = ro + rd * tHit;
    float3 ap = abs(p);
    if (ap.x >= ap.y && ap.x >= ap.z) outN = float3(sign(p.x), 0.0f, 0.0f);
    else if (ap.y >= ap.z)            outN = float3(0.0f, sign(p.y), 0.0f);
    else                              outN = float3(0.0f, 0.0f, sign(p.z));
    if (inside) outN = -outN;
    return tHit;
}

inline float3 evalDichroicSliceFilm(float cosI, float sliceId, float morph, float time) {
    float ct = clamp(cosI, 0.05f, 1.0f);
    float thick = 310.0f + 190.0f * morph + 75.0f * sliceId + 45.0f * sin(time * 0.35f + sliceId);
    float3 phase = TAU * (2.0f * 1.58f * thick * ct) / float3(635.0f, 535.0f, 450.0f);
    return 0.5f + 0.5f * cos(phase);
}

float3 traceDichroicCrystalCube(float3 roWorld, float3 rdWorld, constant MirrorParams &P) {
    float halfS = 1.26f;
    // Graceful museum turntable rotation on the crystal cube
    float3x3 fwdRot = rotY(P.time * 0.22f) * rotX(0.35f + 0.14f * sin(P.time * 0.17f)) * rotZ(0.28f);
    float3x3 invRot = transpose(fwdRot);

    float3 roBase = invRot * roWorld;
    float3 rdBase = normalize(invRot * rdWorld);

    // Fast single early-out for background pixels that miss the crystal cube completely
    float3 nEarly;
    bool insEarly = false;
    if (intersectCube(roBase, rdBase, halfS, nEarly, insEarly) < 0.0f) {
        return evalStudioGallerySky(rdWorld);
    }

    // 3-channel Cauchy dispersion for 32% optical lead crystal (nR=1.68, nG=1.72, nB=1.78)
    const float iorRGB[3] = { 1.675f, 1.725f, 1.785f };
    const float3 chMask[3] = { float3(1.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f), float3(0.0f, 0.0f, 1.0f) };

    // Internal dichroic glass lamellae normals (angled crystal core slices!)
    float angTilt = 0.25f + 0.55f * P.morph_param;
    float3 sliceN1 = normalize(float3(cos(angTilt), sin(angTilt), 0.25f));
    float3 sliceN2 = normalize(float3(-sin(angTilt), 0.25f, cos(angTilt)));

    float3 totalCol = float3(0.0f);
    uint maxB = clamp(P.max_bounces, 6u, 32u);

    for (int ch = 0; ch < 3; ++ch) {
        float ior = iorRGB[ch];
        float3 ro = roBase;
        float3 rd = rdBase;
        float3 thru = float3(1.0f);
        float3 acc = float3(0.0f);
        bool inGlass = (max(abs(ro.x), max(abs(ro.y), abs(ro.z))) < halfS - 1e-3f);

        for (uint b = 0u; b < maxB; ++b) {
            float3 nCube;
            bool cubeInside = false;
            float tCube = intersectCube(ro, rd, halfS, nCube, cubeInside);

            if (!inGlass) {
                if (tCube < 0.0f) {
                    acc += thru * evalStudioGallerySky(fwdRot * rd);
                    break;
                }
                float3 pHit = ro + rd * tCube;
                float cosI = max(0.0f, dot(-rd, nCube));
                float f0 = pow((ior - 1.0f) / (ior + 1.0f), 2.0f);
                float fresnel = f0 + (1.0f - f0) * pow(1.0f - cosI, 5.0f);
                // Specular reflection off outer polished crystal face
                acc += thru * fresnel * evalStudioGallerySky(fwdRot * reflect(rd, nCube));
                // Refract into lead crystal!
                float3 rRefr = refract(rd, nCube, 1.0f / ior);
                thru *= (1.0f - fresnel);
                ro = pHit - nCube * 2.0e-3f;
                rd = normalize(rRefr);
                inGlass = true;
                continue;
            }

            // Inside the lead crystal: check both outer cube exit AND internal dichroic glass slices!
            float tBest = (tCube > 0.0f) ? tCube : 1e9f;
            float3 nBest = nCube;
            int hitKind = 0; // 0 = outer crystal wall, 1 = internal dichroic lamella
            float sliceId = 0.0f;

            // 8 internal dichroic slices (4 along sliceN1, 4 along sliceN2)
            float spacing = mix(0.52f, 0.34f, P.morph_param);
            for (int k = 0; k < 8; ++k) {
                float3 sn = (k < 4) ? sliceN1 : sliceN2;
                float off = (float(k & 3) - 1.5f) * spacing;
                float denom = dot(rd, sn);
                if (abs(denom) > 1e-5f) {
                    float tS = (off - dot(ro, sn)) / denom;
                    if (tS > 2.5e-3f && tS < tBest) {
                        float3 ps = ro + rd * tS;
                        if (max(abs(ps.x), max(abs(ps.y), abs(ps.z))) < halfS * 0.90f) {
                            tBest = tS;
                            nBest = (denom < 0.0f) ? sn : -sn;
                            hitKind = 1;
                            sliceId = float(k);
                        }
                    }
                }
            }

            if (tBest > 1e8f) break;
            float3 pHit = ro + rd * tBest;

            if (hitKind == 1) {
                float cosI = max(0.0f, dot(-rd, nBest));
                float3 filmR = evalDichroicSliceFilm(cosI, sliceId, P.morph_param, P.time);
                float3 filmSat = pow(clamp(filmR, 0.0f, 1.0f), float3(1.35f));
                float3 filmT = float3(1.0f) - filmR * 0.55f;

                float crossDist = abs(dot(pHit, (sliceId < 3.5f) ? sliceN2 : sliceN1));
                float seamGrid = exp(-pow(fract(crossDist / spacing + 0.5f) - 0.5f, 2.0f) * 165.0f);
                acc += thru * (0.05f + 0.62f * filmSat) * (0.18f + 0.82f * seamGrid);

                // Partial dichroic reflection on grazing angles, transmission on steep angles -> layered jewel!
                if (cosI < 0.52f + 0.18f * fract(sliceId * 0.37f)) {
                    thru *= mix(float3(0.50f), float3(0.92f), filmR);
                    ro = pHit + nBest * 2.5e-3f;
                    rd = reflect(rd, nBest);
                } else {
                    thru *= filmT * 0.92f;
                    ro = pHit - nBest * 2.5e-3f;
                }
            } else {
                // Hit outer crystal face from inside -> check Total Internal Reflection (TIR)!
                float cosI = max(0.0f, dot(-rd, nBest));
                float3 rOut = refract(rd, nBest, ior);
                // Crisp beveled edge sparkle along the 12 crystal edges
                float3 edgeD = halfS - abs(pHit);
                float eMin = min(edgeD.x, min(edgeD.y, edgeD.z));
                float e2 = edgeD.x + edgeD.y + edgeD.z - eMin - max(edgeD.x, max(edgeD.y, edgeD.z));
                float bevelGlow = exp(-pow(e2 / 0.022f, 2.0f)) * 0.38f;
                acc += thru * float3(1.05f, 1.15f, 1.35f) * bevelGlow;

                if (length(rOut) < 1e-4f) {
                    // 100% Total Internal Reflection (TIR)!
                    thru *= 0.955f;
                    ro = pHit + nBest * 2.0e-3f;
                    rd = reflect(rd, nBest);
                } else {
                    float f0 = pow((ior - 1.0f) / (ior + 1.0f), 2.0f);
                    float fresnel = f0 + (1.0f - f0) * pow(1.0f - cosI, 5.0f);
                    // Refracted exit ray samples studio gallery lights without highlight clipping
                    acc += thru * (1.0f - fresnel) * evalStudioGallerySky(fwdRot * normalize(rOut)) * 0.85f;
                    // Continue internal Fresnel reflection
                    thru *= max(fresnel, 0.18f);
                    ro = pHit + nBest * 2.0e-3f;
                    rd = reflect(rd, nBest);
                }
            }

            if (max(thru.r, max(thru.g, thru.b)) < 0.015f) break;
        }
        totalCol += acc * chMask[ch];
    }

    return totalCol;
}

// ============================================================================
//  SCENE 5 (Key 6): 6-Band Spectral Dispersion Brilliant-Cut Diamond / Gem
//  26-facet Tolkowsky Brilliant Cut + True 6-Wavelength Cauchy Dispersion + Floor Caustics
// ============================================================================

// Precomputed 26-facet Tolkowsky Brilliant-Cut Diamond table (xyz = unit normal, w = plane dist)
// Eliminates ~3,120 cos/sin trig calls per ray inside the 6-band spectral loop!
constant float4 DIAMOND_FACETS[26] = {
    float4( 0.000000f,  1.000000f,  0.000000f, 0.68f),
    // 8 Crown bezel facets (34.5 deg)
    float4( 0.566196f,  0.824271f,  0.000000f, 1.14f),
    float4( 0.400361f,  0.824271f,  0.400361f, 1.14f),
    float4( 0.000000f,  0.824271f,  0.566196f, 1.14f),
    float4(-0.400361f,  0.824271f,  0.400361f, 1.14f),
    float4(-0.566196f,  0.824271f,  0.000000f, 1.14f),
    float4(-0.400361f,  0.824271f, -0.400361f, 1.14f),
    float4( 0.000000f,  0.824271f, -0.566196f, 1.14f),
    float4( 0.400361f,  0.824271f, -0.400361f, 1.14f),
    // 8 Upper girdle / star facets (rotated 22.5 deg)
    float4( 0.850576f,  0.390297f,  0.352320f, 1.38f),
    float4( 0.352320f,  0.390297f,  0.850576f, 1.38f),
    float4(-0.352320f,  0.390297f,  0.850576f, 1.38f),
    float4(-0.850576f,  0.390297f,  0.352320f, 1.38f),
    float4(-0.850576f,  0.390297f, -0.352320f, 1.38f),
    float4(-0.352320f,  0.390297f, -0.850576f, 1.38f),
    float4( 0.352320f,  0.390297f, -0.850576f, 1.38f),
    float4( 0.850576f,  0.390297f, -0.352320f, 1.38f),
    // 8 Steep Pavilion facets (40.8 deg)
    float4( 0.757315f, -0.653050f,  0.000000f, 1.02f),
    float4( 0.535503f, -0.653050f,  0.535503f, 1.02f),
    float4( 0.000000f, -0.653050f,  0.757315f, 1.02f),
    float4(-0.535503f, -0.653050f,  0.535503f, 1.02f),
    float4(-0.757315f, -0.653050f,  0.000000f, 1.02f),
    float4(-0.535503f, -0.653050f, -0.535503f, 1.02f),
    float4( 0.000000f, -0.653050f, -0.757315f, 1.02f),
    float4( 0.535503f, -0.653050f, -0.535503f, 1.02f),
    // Culet
    float4( 0.000000f, -1.000000f,  0.000000f, 1.24f)
};

inline float3 getDiamondFacet(int idx, thread float &outDist) {
    float4 f = DIAMOND_FACETS[idx];
    outDist = f.w;
    return f.xyz;
}

inline bool intersectDiamond(float3 ro, float3 rd, thread float &tNear, thread float &tFar, thread float3 &nNear, thread float3 &nFar) {
    tNear = -1e9f;
    tFar  =  1e9f;
    nNear = float3(0.0f);
    nFar  = float3(0.0f);
    for (int i = 0; i < 26; ++i) {
        float4 f = DIAMOND_FACETS[i];
        float denom = dot(rd, f.xyz);
        float numer = f.w - dot(ro, f.xyz);
        if (abs(denom) < 1e-6f) {
            if (numer < 0.0f) return false;
        } else {
            float t = numer / denom;
            if (denom < 0.0f) {
                if (t > tNear) { tNear = t; nNear = f.xyz; }
            } else {
                if (t < tFar)  { tFar  = t; nFar  = f.xyz; }
            }
        }
    }
    return (tNear <= tFar) && (tFar > 1e-4f);
}

// Fast inside-only exit intersection for convex diamond (skips tNear/nNear on 95% of bounces!)
inline bool intersectDiamondInside(float3 ro, float3 rd, thread float &tFar, thread float3 &nFar) {
    tFar = 1e9f;
    nFar = float3(0.0f);
    for (int i = 0; i < 26; ++i) {
        float4 f = DIAMOND_FACETS[i];
        float denom = dot(rd, f.xyz);
        if (denom > 1e-6f) {
            float t = (f.w - dot(ro, f.xyz)) / denom;
            if (t < tFar) {
                tFar = t;
                nFar = f.xyz;
            }
        }
    }
    return (tFar > 1e-4f && tFar < 1e8f);
}

inline float3 diamondLightRig(float3 rd) {
    float3 d = normalize(rd);
    float s1 = pow(max(0.0f, dot(d, normalize(float3( 0.45f, 0.85f,  0.26f)))), 150.0f) * 4.8f;
    float s2 = pow(max(0.0f, dot(d, normalize(float3(-0.65f, 0.68f, -0.34f)))), 120.0f) * 4.2f;
    float s3 = pow(max(0.0f, dot(d, normalize(float3( 0.15f, 0.72f, -0.68f)))), 130.0f) * 3.8f;
    float s4 = pow(max(0.0f, dot(d, normalize(float3(-0.25f, 0.94f,  0.22f)))), 200.0f) * 5.2f;
    float ring = exp(-pow((d.y - 0.35f) / 0.045f, 2.0f)) * (0.25f + 0.75f * pow(max(0.0f, cos(atan2(d.z, d.x) * 8.0f)), 10.0f));
    return float3(0.010f, 0.012f, 0.018f) + float3(1.0f, 0.98f, 0.95f) * (s1 + s2 + s3 + s4 + ring * 1.15f);
}

struct DiamondFrame {
    float3x3 fwdRot;
    float3x3 invRot;
    float3 roGem;
    float dispScale;
};

inline DiamondFrame buildDiamondFrame(constant MirrorParams &P) {
    DiamondFrame F;
    F.fwdRot = rotY(P.time * 0.28f) * rotX(0.24f * sin(P.time * 0.19f));
    F.invRot = transpose(F.fwdRot);
    F.roGem = F.invRot * P.cam_pos.xyz;
    F.dispScale = 0.032f + 0.085f * P.morph_param;
    return F;
}

float3 traceSpectralDiamond(float3 roWorld, float3 rdWorld, constant MirrorParams &P, thread const DiamondFrame &F) {
    const float lambdas[6] = { 0.650f, 0.595f, 0.545f, 0.495f, 0.455f, 0.420f };
    const float3 specRGB[6] = {
        float3(1.15f, 0.12f, 0.00f),
        float3(0.95f, 0.72f, 0.00f),
        float3(0.18f, 1.05f, 0.14f),
        float3(0.00f, 0.85f, 0.92f),
        float3(0.08f, 0.28f, 1.20f),
        float3(0.55f, 0.04f, 1.05f)
    };

    float3 rdGem = normalize(F.invRot * rdWorld);

    float tFloor = (rdWorld.y < -1e-4f && P.view_mode == 0u) ? (-1.65f - roWorld.y) / rdWorld.y : -1.0f;
    float tNear0, tFar0;
    float3 nNear0, nFar0;
    bool hitGem0 = intersectDiamond(F.roGem, rdGem, tNear0, tFar0, nNear0, nFar0);

    if ((!hitGem0 || (tFloor > 0.0f && tFloor < tNear0)) && P.view_mode == 0u) {
        if (tFloor > 0.0f && tFloor < 35.0f) {
            float3 pf = roWorld + rdWorld * tFloor;
            float r = length(pf.xz);
            float ang = atan2(pf.z, pf.x) - P.time * 0.28f;
            float3 caustics = float3(0.0f);
            for (int k = 0; k < 6; ++k) {
                float shift = (float(k) - 2.5f) * (0.042f + 0.045f * P.morph_param);
                float petal8  = pow(max(0.0f, cos((ang + shift * 0.55f) * 8.0f)), 24.0f);
                float petal16 = pow(max(0.0f, cos((ang - shift * 0.35f) * 16.0f + 0.4f)), 32.0f);
                float ring1 = exp(-pow((r - (1.85f + shift * 1.4f)) / 0.15f, 2.0f));
                float ring2 = exp(-pow((r - (3.05f + shift * 2.1f)) / 0.22f, 2.0f)) * 0.72f;
                float streak = exp(-pow((r - (2.40f + shift * 1.7f)) / 0.75f, 2.0f)) * petal8;
                caustics += specRGB[k] * (ring1 * (0.14f + 1.15f * petal8 + 0.65f * petal16) + ring2 * (petal8 + 0.55f * petal16) + streak * 0.55f);
            }
            float tableMask = exp(-r * r * 0.050f);
            return float3(0.011f, 0.013f, 0.019f) + caustics * tableMask * 0.58f;
        }
        return diamondLightRig(rdWorld) * 0.10f + float3(0.009f, 0.011f, 0.017f);
    }

    float3 totalCol = float3(0.0f);
    uint maxB = clamp(P.max_bounces, 6u, 16u);
    bool startInside = (P.view_mode == 1u) || (tNear0 < 1e-4f);
    float3 pEntry0 = F.roGem + rdGem * tNear0;
    float cosEntry0 = max(0.0f, dot(-rdGem, nNear0));
    float envRefl0 = dot(diamondLightRig(F.fwdRot * reflect(rdGem, nNear0)), float3(0.333f));

    for (int w = 0; w < 6; ++w) {
        float ior = 2.36f + F.dispScale / (lambdas[w] * lambdas[w]);
        float f0 = pow((ior - 1.0f) / (ior + 1.0f), 2.0f);
        float3 ro = F.roGem;
        float3 rd = rdGem;
        float thru = 1.0f;
        float acc = 0.0f;

        if (!startInside) {
            float fres = f0 + (1.0f - f0) * pow(1.0f - cosEntry0, 5.0f);
            acc += fres * envRefl0;
            thru *= (1.0f - fres);
            ro = pEntry0 - nNear0 * 2.0e-3f;
            rd = normalize(refract(rdGem, nNear0, 1.0f / ior));
        }

        for (uint b = 0u; b < maxB; ++b) {
            float tf;
            float3 nf;
            if (!intersectDiamondInside(ro, rd, tf, nf)) {
                acc += thru * dot(diamondLightRig(F.fwdRot * rd), float3(0.333f));
                break;
            }
            float3 pHit = ro + rd * tf;
            float3 nIn = -nf;
            float cosI = max(0.0f, dot(-rd, nIn));
            float3 rOut = refract(rd, nIn, ior);
            if (length(rOut) < 1e-4f) {
                thru *= 0.975f;
                ro = pHit + nIn * 2.0e-3f;
                rd = reflect(rd, nIn);
            } else {
                float fres = f0 + (1.0f - f0) * pow(1.0f - cosI, 5.0f);
                acc += thru * (1.0f - fres) * dot(diamondLightRig(F.fwdRot * normalize(rOut)), float3(0.333f)) * 1.45f;
                thru *= max(fres, 0.18f);
                ro = pHit + nIn * 2.0e-3f;
                rd = reflect(rd, nIn);
            }
            if (thru < 0.045f) break;
        }
        totalCol += specRGB[w] * (acc / 2.2f);
    }

    return totalCol;
}

// ============================================================================
//  SCENE 6 (Key 7): Chris Wood Dichroic Glass Light Caustics Mandala Wall
//  24 vertical dichroic glass fins projecting EXACT transmitted + reflected rainbow caustics!
// ============================================================================

inline float intersectFinQuad(
    float3 ro, float3 rd,
    float3 finCenter, float3 finN, float3 finT,
    float halfLen, float halfDepth
) {
    float denom = dot(rd, finN);
    if (abs(denom) < 1e-5f) return -1.0f;
    float t = dot(finCenter - ro, finN) / denom;
    if (t < 1e-4f) return -1.0f;
    float3 d = ro + rd * t - finCenter;
    float u = dot(d, finT);
    float v = d.z;
    if (abs(u) <= halfLen && abs(v) <= halfDepth) return t;
    return -1.0f;
}

struct CausticsFrame {
    float3 lights[2];
    float3 finC[16];
    float3 finN[16];
    float3 finT[16];
    float  finLen[16];
};

inline CausticsFrame buildCausticsFrame(constant MirrorParams &P) {
    CausticsFrame F;
    const float wallZ = 1.85f;
    const float finDepth = 0.28f;
    const float finCenterZ = wallZ - finDepth;
    float aL0 = P.time * 0.42f;
    float aL1 = -P.time * 0.31f + 2.1f;
    F.lights[0] = float3(2.65f * cos(aL0), 2.15f * sin(aL0 * 0.7f), -1.45f);
    F.lights[1] = float3(2.45f * cos(aL1), 1.95f * sin(aL1 * 0.8f), -1.25f);
    float twistAng = P.morph_param * PI * 0.65f + 0.15f * sin(P.time * 0.22f);
    for (int i = 0; i < 16; ++i) {
        bool inner = (i < 8);
        float phi = (float(i & 7) / 8.0f) * TAU + (inner ? 0.0f : (PI / 8.0f));
        float rad = inner ? 0.82f : 1.72f;
        F.finC[i] = float3(cos(phi) * rad, sin(phi) * rad, finCenterZ);
        float orient = phi + (inner ? 0.58f : -0.52f) + twistAng;
        F.finT[i] = float3(cos(orient), sin(orient), 0.0f);
        F.finN[i] = float3(-sin(orient), cos(orient), 0.0f);
        F.finLen[i] = inner ? 0.36f : 0.44f;
    }
    return F;
}

float3 traceDichroicCausticsWall(float3 ro, float3 rd, constant MirrorParams &P, thread const CausticsFrame &F) {
    const float wallZ = 1.85f;
    const float finDepth = 0.28f;
    const float3 lightCols[2] = {
        float3(1.15f, 1.08f, 1.00f),
        float3(0.95f, 1.05f, 1.20f)
    };

    float tWall = (rd.z > 1e-5f) ? (wallZ - ro.z) / rd.z : 1e9f;
    float tFin = 1e9f;
    int hitFin = -1;
    for (int i = 0; i < 16; ++i) {
        float t = intersectFinQuad(ro, rd, F.finC[i], F.finN[i], F.finT[i], F.finLen[i], finDepth);
        if (t > 0.0f && t < tFin && t < tWall) {
            tFin = t;
            hitFin = i;
        }
    }

    float3 col = float3(0.0f);
    float3 thru = float3(1.0f);

    if (hitFin >= 0) {
        float3 pF = ro + rd * tFin;
        float cosI = abs(dot(rd, F.finN[hitFin]));
        float3 filmR = evalDichroicSliceFilm(cosI, float(hitFin) * 0.42f, P.morph_param, P.time);
        float edgeGlow = exp(-pow((pF.z - (wallZ - 2.0f * finDepth)) / 0.022f, 2.0f));
        col += (0.12f + 0.95f * filmR * filmR) * (0.28f + 1.45f * edgeGlow);
        thru *= mix(float3(0.35f), float3(0.92f), float3(1.0f) - filmR * 0.55f);
    }

    if (tWall > 1e8f) {
        return col + thru * float3(0.03f, 0.035f, 0.045f);
    }

    float3 pW = ro + rd * tWall;
    float rWall = length(pW.xy);
    float3 wallAlbedo = float3(0.20f, 0.20f, 0.21f) * clamp(1.06f - 0.13f * rWall, 0.40f, 1.0f);
    float3 wallLight = float3(0.07f, 0.075f, 0.085f);

    for (int l = 0; l < 2; ++l) {
        float3 toL = F.lights[l] - pW;
        float distL = length(toL);
        float3 lDir = toL / distL;
        float ndl = max(0.0f, -lDir.z);
        float atten = 2.8f / (1.0f + 0.18f * distL * distL);

        float3 transTint = float3(1.0f);
        bool hitTrans = false;
        if (rWall < 3.4f) {
            for (int i = 0; i < 16; ++i) {
                float2 dXY = pW.xy - F.finC[i].xy;
                if (dot(dXY, dXY) > 4.2f) continue;
                float tS = intersectFinQuad(pW + float3(0.0f, 0.0f, -1e-3f), lDir, F.finC[i], F.finN[i], F.finT[i], F.finLen[i], finDepth);
                if (tS > 0.0f && tS < distL) {
                    float cosL = abs(dot(lDir, F.finN[i]));
                    float3 filmR = evalDichroicSliceFilm(cosL, float(i) * 0.42f, P.morph_param, P.time);
                    float3 filmT = clamp(float3(1.18f) - filmR * 1.12f, 0.04f, 1.18f);
                    transTint *= filmT;
                    hitTrans = true;
                }
            }
        }
        wallLight += lightCols[l] * ndl * atten * (hitTrans ? (transTint * 1.48f) : float3(0.28f));

        if (rWall < 3.4f) {
            for (int i = 0; i < 16; ++i) {
                float2 dXY = pW.xy - F.finC[i].xy;
                if (dot(dXY, dXY) > 3.6f) continue;
                float dSigned = dot(F.lights[l] - F.finC[i], F.finN[i]);
                if (dot(pW - F.finC[i], F.finN[i]) * dSigned <= 0.0f) continue;
                float3 lMir = F.lights[l] - 2.0f * dSigned * F.finN[i];
                float3 toMir = lMir - pW;
                float distMir = length(toMir);
                float3 mDir = toMir / distMir;
                float tR = intersectFinQuad(pW + float3(0.0f, 0.0f, -1e-3f), mDir, F.finC[i], F.finN[i], F.finT[i], F.finLen[i], finDepth);
                if (tR > 0.0f && tR < distMir) {
                    float cosR = abs(dot(mDir, F.finN[i]));
                    float3 filmR = evalDichroicSliceFilm(cosR, float(i) * 0.42f, P.morph_param, P.time);
                    float rAtten = 5.0f / (1.0f + 0.16f * distMir * distMir);
                    wallLight += lightCols[l] * max(0.0f, -mDir.z) * rAtten * (0.05f + 1.55f * filmR * filmR);
                }
            }
        }
    }

    // Soft highlight roll-off so overlapping caustic ribbons stay saturated instead of clipping white
    wallLight = wallLight / (1.0f + 0.22f * wallLight);
    return col + thru * wallAlbedo * wallLight;
}

// ============================================================================
//  SCENE 7 (Key 8): Olafur Eliasson Colour-Filter Mirror Tunnel
//  Infinite hexagonal mirror corridor + alternating semi-transparent coloured glass aperture rings
// ============================================================================

float3 traceEliassonTunnel(float3 ro, float3 rd, constant MirrorParams &P) {
    float3 col = float3(0.0f);
    float3 thru = float3(1.0f);

    const float2 hexBase[6] = {
        float2( 1.0f,  0.0f), float2( 0.5f,  0.8660254f), float2(-0.5f,  0.8660254f),
        float2(-1.0f,  0.0f), float2(-0.5f, -0.8660254f), float2( 0.5f, -0.8660254f)
    };
    const float hexR = 2.05f;
    const float ringStep = 1.65f;
    float twistAmt = P.morph_param * 0.18f;
    uint maxB = clamp(P.max_bounces, 6u, 64u);

    for (uint b = 0u; b < maxB; ++b) {
        float localTwist = twistAmt * ro.z;
        float ct = cos(localTwist), st = sin(localTwist);
        float tWall = 1e9f;
        float3 nWall = float3(0.0f);
        int hitSide = 0;

        for (int i = 0; i < 6; ++i) {
            float2 h = hexBase[i];
            float3 wn = float3(h.x * ct - h.y * st, h.x * st + h.y * ct, 0.0f);
            float denom = dot(rd, wn);
            if (denom > 1e-6f) {
                float t = (hexR - dot(ro, wn)) / denom;
                if (t > 1e-4f && t < tWall) {
                    tWall = t;
                    nWall = -wn;
                    hitSide = i;
                }
            }
        }

        float tBaffle = 1e9f;
        float zBaffle = 0.0f;
        if (abs(rd.z) > 1e-5f) {
            float cell = (rd.z > 0.0f) ? (floor(ro.z / ringStep) + 1.0f) : (ceil(ro.z / ringStep) - 1.0f);
            zBaffle = cell * ringStep;
            float tb = (zBaffle - ro.z) / rd.z;
            if (tb > 2e-3f && tb < tWall) {
                tBaffle = tb;
            }
        }

        if (tBaffle < tWall) {
            float3 pb = ro + rd * tBaffle;
            float rXY = length(pb.xy);
            float ringIdx = round(zBaffle / ringStep);
            float innerHole = 1.08f + 0.18f * sin(ringIdx * 0.7f + P.time * 0.45f);

            if (rXY > innerHole) {
                float dirBias = (rd.z > 0.0f) ? 0.0f : 0.48f;
                float hue = fract(ringIdx * 0.145f + dirBias + P.time * 0.04f);
                float3 glassCol = paletteCos(
                    hue,
                    float3(0.50f, 0.46f, 0.54f),
                    float3(0.48f, 0.46f, 0.50f),
                    float3(1.0f, 1.0f, 1.0f),
                    float3(0.00f, 0.33f, 0.67f)
                );
                // Optical glass bevel, subtle concentric etch & grazing Fresnel sheen
                float innerRim = exp(-pow((rXY - innerHole) / 0.022f, 2.0f));
                float bevelGrad = clamp((rXY - innerHole) / 0.95f, 0.0f, 1.0f);
                float sheen = 0.65f + 0.35f * pow(1.0f - abs(rd.z), 2.0f);
                float etch = exp(-pow(abs(fract(rXY * 3.0f) - 0.5f) / 0.025f, 2.0f)) * 0.08f;
                col += thru * glassCol * ((0.045f + 0.045f * bevelGrad) * sheen + 0.82f * innerRim + etch);
                thru *= mix(glassCol, float3(0.85f), 0.16f) * 0.82f;
                ro = pb + rd * 3e-3f;
                if (max(thru.r, max(thru.g, thru.b)) < 0.015f) break;
                continue;
            } else {
                ro = pb + rd * 3e-3f;
                continue;
            }
        }

        if (tWall > 1e8f) break;
        float3 pHit = ro + rd * tWall;
        float2 hn = hexBase[(hitSide + 1) % 6];
        float2 hp = hexBase[(hitSide + 5) % 6];
        float3 wnNext = float3(hn.x * ct - hn.y * st, hn.x * st + hn.y * ct, 0.0f);
        float3 wnPrev = float3(hp.x * ct - hp.y * st, hp.x * st + hp.y * ct, 0.0f);
        float seam = min(abs(hexR - dot(pHit, wnNext)), abs(hexR - dot(pHit, wnPrev)));
        float ribGlow = exp(-pow(seam / 0.025f, 2.0f));
        col += thru * float3(0.55f, 0.78f, 1.15f) * ribGlow * 0.32f;

        float cosI = max(0.0f, dot(-rd, nWall));
        thru *= mirrorReflectance(cosI, b, P.coating_mode, P.morph_param, P.time) * 0.93f;
        thru *= exp(-tWall * 0.020f);

        ro = pHit + nWall * 1.5e-3f;
        rd = reflect(rd, nWall);
        if (max(thru.r, max(thru.g, thru.b)) < 0.015f) break;
    }

    return col;
}

// ============================================================================
//  SCENE 8 (Key 9): 3D Apollonian / Soddy Mirror + Crystal Sphere Packing
//  19 analytically tangent spheres alternating Chrome Mirror & Refractive Crystal Glass!
// ============================================================================

float3 traceApollonianCluster(float3 roWorld, float3 rdWorld, constant MirrorParams &P) {
    float breathe = 0.015f + 0.14f * P.morph_param;
    float R0 = 1.0f;
    float s = (2.0f * R0 + breathe) / (2.0f * sqrt(2.0f));

    float3 sPos[19];
    float  sRad[19];
    bool   sGlass[19];

    sPos[0] = float3( s,  s,  s); sRad[0] = R0; sGlass[0] = false;
    sPos[1] = float3( s, -s, -s); sRad[1] = R0; sGlass[1] = true;
    sPos[2] = float3(-s,  s, -s); sRad[2] = R0; sGlass[2] = false;
    sPos[3] = float3(-s, -s,  s); sRad[3] = R0; sGlass[3] = true;

    sPos[4] = float3(0.0f);
    sRad[4] = max(0.18f, sqrt(3.0f) * s - R0 - 0.005f);
    sGlass[4] = true;

    const int eA[6] = { 0, 0, 0, 1, 1, 2 };
    const int eB[6] = { 1, 2, 3, 2, 3, 3 };
    for (int k = 0; k < 6; ++k) {
        float3 mid = 0.5f * (sPos[eA[k]] + sPos[eB[k]]);
        float3 dir = normalize(mid);
        sPos[5 + k] = dir * (length(mid) + 0.58f);
        sRad[5 + k] = 0.36f;
        sGlass[5 + k] = ((k & 1) == 0);
    }

    for (int k = 0; k < 4; ++k) {
        float3 fDir = normalize(-sPos[k]);
        sPos[11 + k] = fDir * (0.98f + breathe * 0.8f);
        sRad[11 + k] = 0.31f;
        sGlass[11 + k] = true;
    }

    for (int k = 0; k < 4; ++k) {
        float3 fDir = normalize(-sPos[k]);
        sPos[15 + k] = fDir * (1.88f + breathe);
        sRad[15 + k] = 0.44f;
        sGlass[15 + k] = false;
    }

    float3 ro = roWorld;
    float3 rd = rdWorld;
    float3 col = float3(0.0f);
    float3 thru = float3(1.0f);
    uint maxB = clamp(P.max_bounces, 6u, 48u);

    for (uint b = 0u; b < maxB; ++b) {
        float tMin = 1e9f;
        float3 nHit = float3(0.0f);
        int hitIdx = -1;
        bool insideHit = false;

        for (int i = 0; i < 19; ++i) {
            float3 oc = ro - sPos[i];
            float b2 = dot(oc, rd);
            float c2 = dot(oc, oc) - sRad[i] * sRad[i];
            float h = b2 * b2 - c2;
            if (h < 0.0f) continue;
            float sh = sqrt(h);
            float t = -b2 - sh;
            bool ins = false;
            if (t < 1.5e-4f) {
                t = -b2 + sh;
                ins = true;
            }
            if (t > 1.5e-4f && t < tMin) {
                tMin = t;
                hitIdx = i;
                insideHit = ins;
                float3 p = ro + rd * t;
                nHit = normalize(p - sPos[i]);
                if (ins) nHit = -nHit;
            }
        }

        if (hitIdx < 0) {
            col += thru * evalWadaSky(rd, P.time * 0.8f, P.morph_param);
            break;
        }

        float3 pHit = ro + rd * tMin;
        float cosI = max(0.0f, dot(-rd, nHit));

        if (!sGlass[hitIdx]) {
            thru *= mirrorReflectance(cosI, b, P.coating_mode, P.morph_param, P.time);
            ro = pHit + nHit * 3.0e-4f;
            rd = reflect(rd, nHit);
        } else {
            float ior = 1.60f;
            float eta = insideHit ? ior : (1.0f / ior);
            float f0 = pow((ior - 1.0f) / (ior + 1.0f), 2.0f);
            float fres = f0 + (1.0f - f0) * pow(1.0f - cosI, 5.0f);
            float3 rRefr = refract(rd, nHit, eta);

            if (length(rRefr) < 1e-4f) {
                thru *= 0.96f;
                ro = pHit + nHit * 3.0e-4f;
                rd = reflect(rd, nHit);
            } else {
                if (!insideHit) {
                    col += thru * fres * evalWadaSky(reflect(rd, nHit), P.time * 0.8f, P.morph_param) * 0.85f;
                }
                float3 crystalTint = mix(float3(0.96f, 0.99f, 1.00f), evalDichroicSliceFilm(cosI, float(hitIdx) * 0.4f, P.morph_param, P.time) * 0.35f + 0.72f, 0.35f);
                thru *= (1.0f - fres * 0.65f) * crystalTint;
                ro = pHit - nHit * 3.0e-4f;
                rd = normalize(rRefr);
            }
        }

        if (max(thru.r, max(thru.g, thru.b)) < 0.004f) break;
    }

    return col;
}

// ============================================================================
//  SCENE 9 (Key 0): GRIN Curved-Light Optical Crystal (V=0) & Corner-Cube Retroreflector Wall (V=1)
// ============================================================================

inline float3 evalGrinCathedralRoom(float3 p, float3 rd, float time) {
    const float roomR = 6.5f;
    float3 invD = 1.0f / select(rd, float3(1e-6f), abs(rd) < 1e-6f);
    float3 t1 = (roomR * sign(rd) - p) * invD;
    float tHit = min(min(t1.x, t1.y), t1.z);
    float3 q = p + rd * max(tHit, 0.0f);

    float3 g = abs(fract(q * 0.65f + 0.5f) - 0.5f);
    float lineXY = exp(-pow(min(g.x, g.y) / 0.017f, 2.0f));
    float lineYZ = exp(-pow(min(g.y, g.z) / 0.017f, 2.0f));
    float lineXZ = exp(-pow(min(g.x, g.z) / 0.017f, 2.0f));

    float3 g2 = abs(fract(q * 2.60f + 0.5f) - 0.5f);
    float subXY = exp(-pow(min(g2.x, g2.y) / 0.022f, 2.0f));
    float subYZ = exp(-pow(min(g2.y, g2.z) / 0.022f, 2.0f));
    float subXZ = exp(-pow(min(g2.x, g2.z) / 0.022f, 2.0f));

    float3 aq = abs(q);
    float grid = (aq.z >= aq.x && aq.z >= aq.y) ? (lineXY + 0.22f * subXY) : ((aq.x >= aq.y) ? (lineYZ + 0.22f * subYZ) : (lineXZ + 0.22f * subXZ));

    float hue = fract(atan2(q.z, q.x) / TAU + q.y * 0.06f + time * 0.03f);
    float3 wallCol = paletteCos(
        hue,
        float3(0.45f, 0.52f, 0.78f),
        float3(0.45f, 0.42f, 0.48f),
        float3(1.0f, 1.0f, 1.0f),
        float3(0.05f, 0.25f, 0.58f)
    );
    float star = pow(max(0.0f, sin(q.x * 2.4f) * cos(q.y * 2.4f) * sin(q.z * 2.4f)), 24.0f);
    return float3(0.010f, 0.014f, 0.024f) + wallCol * grid * 1.15f + float3(2.2f, 1.65f, 0.95f) * star * 1.65f;
}

float3 traceGrinCurvedLight(float3 ro, float3 rd, constant MirrorParams &P) {
    const float eps = 0.24f;
    const float baseA = 0.72f + 1.35f * P.morph_param;
    const float disp[3] = { 0.94f, 1.00f, 1.07f };
    const float3 chMask[3] = { float3(1.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f), float3(0.0f, 0.0f, 1.0f) };

    float3 finalCol = float3(0.0f);
    uint steps = clamp(P.max_bounces, 28u, 56u);

    for (int ch = 0; ch < 3; ++ch) {
        float A = baseA * disp[ch];
        float3 pos = ro;
        float3 dir = rd;
        float3 glowAcc = float3(0.0f);
        bool trapped = false;

        for (uint s = 0u; s < steps; ++s) {
            float r2 = dot(pos, pos);
            if (r2 > 34.0f) break;
            if (r2 < 0.09f) {
                trapped = true;
                break;
            }
            float r = sqrt(r2);
            float dt = clamp(0.048f + 0.085f * r, 0.048f, 0.42f);

            float denom = r2 + eps;
            float nVal = 1.0f + A / denom;
            float3 gradN = (-2.0f * A / (denom * denom)) * pos;
            float3 accel = (gradN - dir * dot(gradN, dir)) / nVal;

            float3 midDir = normalize(dir + accel * (0.5f * dt));
            float3 midPos = pos + midDir * (0.5f * dt);
            float mr2 = dot(midPos, midPos);
            float mDen = mr2 + eps;
            float mN = 1.0f + A / mDen;
            float3 mGrad = (-2.0f * A / (mDen * mDen)) * midPos;
            float3 mAccel = (mGrad - midDir * dot(mGrad, midDir)) / mN;

            pos += midDir * dt;
            dir = normalize(dir + mAccel * dt);

            float haloDist = abs(r - (0.78f + 0.18f * P.morph_param)) + abs(pos.y) * 3.2f;
            float halo = exp(-haloDist * 10.5f) * dt * 0.34f;
            glowAcc += float3(1.45f, 1.05f, 0.65f) * halo;
        }

        float3 sky = trapped ? float3(0.012f, 0.018f, 0.036f) : evalGrinCathedralRoom(pos, dir, P.time);
        finalCol += (sky + glowAcc) * chMask[ch];
    }

    return finalCol;
}

float3 traceCornerCubeRetroWall(float3 ro, float3 rd, constant MirrorParams &P) {
    const float wallZ = 2.0f;
    float cellScale = mix(1.4f, 3.8f, P.morph_param);

    float3 lightRingN = normalize(rotY(P.time * 0.45f) * float3(0.35f, 0.72f, 0.60f));
    // Wide-spread starlight beacons behind the viewer so only aligned prism facets ignite
    float3 star1 = float3(3.6f * cos(P.time * 0.75f),  2.4f * sin(P.time * 0.55f), -1.8f);
    float3 star2 = float3(-3.4f * sin(P.time * 0.62f), -2.2f * cos(P.time * 0.48f), -2.0f);
    float3 star3 = float3(2.2f * sin(P.time * 0.41f),  3.1f * cos(P.time * 0.53f), -1.6f);

    if (rd.z <= 1e-4f) {
        return float3(0.008f, 0.010f, 0.018f);
    }

    float tW = (wallZ - ro.z) / rd.z;
    float3 pW = ro + rd * tW;

    float2 q = pW.xy * cellScale;
    float2 cellId = floor(q);
    float2 f = fract(q) - 0.5f;

    const float3 n1 = normalize(float3( 0.8164966f,  0.0f,       -0.5773503f));
    const float3 n2 = normalize(float3(-0.4082483f,  0.7071068f, -0.5773503f));
    const float3 n3 = normalize(float3(-0.4082483f, -0.7071068f, -0.5773503f));

    float seed = hash12(cellId);
    float3 d = rd;
    float3 thru = float3(1.0f);

    float ang = atan2(f.y, f.x);
    int order = (ang < -PI / 3.0f) ? 0 : ((ang < PI / 3.0f) ? 1 : 2);
    float3 triad[3] = { n1, n2, n3 };
    for (int k = 0; k < 3; ++k) {
        float3 nk = triad[(order + k) % 3];
        float cosI = max(0.05f, abs(dot(d, nk)));
        thru *= mirrorReflectance(cosI, uint(k), P.coating_mode, P.morph_param + seed * 0.25f, P.time);
        d = reflect(d, nk);
    }
    // Distinct per-facet optical tilt so the 3 internal triangular mirrors of each cube show crisp 3D contrast
    float3 facetTilt = triad[order] * 0.24f + float3(f.x, f.y, 0.0f) * 0.42f + float3(cos(seed * TAU), sin(seed * TAU), 0.0f) * 0.14f;
    d = normalize(d + facetTilt);

    // Crisp diamond-cut micro-bevels along cell borders and internal 120-deg prism creases
    float borderDist = 0.5f - max(abs(f.x), abs(f.y));
    float rayEdge = abs(sin(3.0f * ang)) * length(f);
    float groove = min(borderDist, rayEdge);
    float3 bevelGlow = float3(0.22f, 0.48f, 0.88f) * exp(-pow(groove / 0.016f, 2.0f)) * 0.34f;

    // Deep obsidian mirror chamber base with per-facet shading
    float facetShade = (order == 0) ? 0.55f : ((order == 1) ? 0.85f : 1.15f);
    float3 retCol = float3(0.014f, 0.018f, 0.032f) * facetShade;

    float rD = 0.0f;
    float tR = intersectGlowRing(pW, d, float3(0.0f, 0.0f, -1.8f), lightRingN, 1.85f, 0.085f, rD);
    if (tR > 0.0f) {
        float ef = 1.0f - rD;
        retCol += float3(1.55f, 0.92f, 0.28f) * (0.25f + 1.05f * ef * ef);
    }

    float g1 = pow(max(0.0f, dot(d, normalize(star1 - pW))), 140.0f);
    float g2 = pow(max(0.0f, dot(d, normalize(star2 - pW))), 140.0f);
    float g3 = pow(max(0.0f, dot(d, normalize(star3 - pW))), 140.0f);
    retCol += float3(0.10f, 1.35f, 2.15f) * g1 * 1.45f
            + float3(2.05f, 0.16f, 1.05f) * g2 * 1.45f
            + float3(1.95f, 1.35f, 0.14f) * g3 * 1.35f;

    // Subtle jewel dichroic shimmer per corner-cube facet
    float radialSpark = exp(-length(pW.xy) * 0.42f) * (0.18f + 0.82f * pow(max(0.0f, dot(d, -rd)), 14.0f));
    float3 cellHue = paletteCos(
        seed * 0.65f + float(order) * 0.31f + P.time * 0.05f,
        float3(0.22f, 0.26f, 0.38f),
        float3(0.28f, 0.28f, 0.36f),
        float3(1.0f, 1.0f, 1.0f),
        float3(0.05f, 0.33f, 0.67f)
    );
    retCol += cellHue * radialSpark * 0.42f * facetShade;

    return thru * retCol + bevelGlow;
}

// ============================================================================
//  10 Dedicated Per-Scene Compute Kernels (Low Register Footprint -> High M5 Max GPU Occupancy!)
// ============================================================================

inline float3 evalCameraRay(uint2 gid, float ox, float oy, constant MirrorParams &P) {
    float aspect = float(P.width) / float(P.height);
    float tanHalfFov = tan(P.fov * 0.5f);
    float2 uv = (float2(gid) + float2(ox, oy)) / float2(P.width, P.height);
    float2 ndc = uv * 2.0f - 1.0f;
    ndc.y = -ndc.y;
    return normalize(
        P.cam_forward.xyz
        + P.cam_right.xyz * (ndc.x * aspect * tanHalfFov)
        + P.cam_up.xyz    * (ndc.y * tanHalfFov)
    );
}

// Rotated Grid Supersampling (RGSS) 4x & 9x for razor-sharp diagonal & filament anti-aliasing
constant float2 RGSS4[4] = {
    float2(0.375f, 0.125f), float2(0.875f, 0.375f),
    float2(0.125f, 0.625f), float2(0.625f, 0.875f)
};
constant float2 RGSS9[9] = {
    float2(0.167f, 0.056f), float2(0.500f, 0.167f), float2(0.833f, 0.278f),
    float2(0.056f, 0.389f), float2(0.389f, 0.500f), float2(0.722f, 0.611f),
    float2(0.278f, 0.722f), float2(0.611f, 0.833f), float2(0.944f, 0.944f)
};

#define DEFINE_SCENE_KERNEL_INIT(KERNEL_NAME, INIT_STMT, TRACE_EXPR)                            \
kernel void KERNEL_NAME(                                                                        \
    texture2d<half, access::write> outHDR [[texture(0)]],                                       \
    constant MirrorParams &P              [[buffer(0)]],                                        \
    uint2 gid                             [[thread_position_in_grid]]                           \
) {                                                                                             \
    if (gid.x >= P.width || gid.y >= P.height) return;                                          \
    INIT_STMT;                                                                                  \
    uint nSamples = (P.spp >= 9u) ? 9u : ((P.spp >= 4u) ? 4u : 1u);                             \
    float3 accum = float3(0.0f);                                                                \
    for (uint s = 0u; s < nSamples; ++s) {                                                      \
        float2 off = (nSamples == 1u) ? float2(0.5f) : ((nSamples == 4u) ? RGSS4[s] : RGSS9[s]); \
        float3 rd = evalCameraRay(gid, off.x, off.y, P);                                        \
        accum += max((TRACE_EXPR), float3(0.0f));                                               \
    }                                                                                           \
    outHDR.write(half4(half3(accum / float(nSamples)), half(1.0f)), gid);                       \
}

#define DEFINE_SCENE_KERNEL(KERNEL_NAME, TRACE_EXPR) DEFINE_SCENE_KERNEL_INIT(KERNEL_NAME, (void)0, TRACE_EXPR)

DEFINE_SCENE_KERNEL_INIT(renderScene0, PlatonicFrame F = buildPlatonicFrame(P), tracePlatonicPortal(P.cam_pos.xyz, rd, P, F))
DEFINE_SCENE_KERNEL(renderScene1, traceWadaSpheres(P.cam_pos.xyz, rd, P))
DEFINE_SCENE_KERNEL(renderScene2, traceCoxeterHyperbolic(P.cam_pos.xyz, rd, P))
DEFINE_SCENE_KERNEL_INIT(renderScene3, RoomFrame F = buildRoomFrame(P), traceDichroicRoom(P.cam_pos.xyz, rd, P, F))
DEFINE_SCENE_KERNEL(renderScene4, traceDichroicCrystalCube(P.cam_pos.xyz, rd, P))
DEFINE_SCENE_KERNEL_INIT(renderScene5, DiamondFrame F = buildDiamondFrame(P), traceSpectralDiamond(P.cam_pos.xyz, rd, P, F))
DEFINE_SCENE_KERNEL_INIT(renderScene6, CausticsFrame F = buildCausticsFrame(P), traceDichroicCausticsWall(P.cam_pos.xyz, rd, P, F))
DEFINE_SCENE_KERNEL(renderScene7, traceEliassonTunnel(P.cam_pos.xyz, rd, P))
DEFINE_SCENE_KERNEL(renderScene8, traceApollonianCluster(P.cam_pos.xyz, rd, P))
DEFINE_SCENE_KERNEL(renderScene9, (P.view_mode == 0u ? traceGrinCurvedLight(P.cam_pos.xyz, rd, P) : traceCornerCubeRetroWall(P.cam_pos.xyz, rd, P)))

// ============================================================================
//  Post-Processing: HDR Bloom Extract + Separable Gaussian Blur + ACES + FXAA
// ============================================================================

kernel void bloomExtract(
    texture2d<half, access::sample> srcHDR [[texture(0)]],
    texture2d<half, access::write>  dst    [[texture(1)]],
    uint2 gid                              [[thread_position_in_grid]]
) {
    uint w = dst.get_width();
    uint h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float3 c = float3(srcHDR.sample(lin, uv).rgb);
    float lum = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    float knee = smoothstep(1.35f, 3.20f, lum);
    float3 outC = min(c * knee * 0.36f, float3(4.0f));
    dst.write(half4(half3(outC), half(1.0f)), gid);
}

kernel void bloomBlurH(
    texture2d<half, access::sample> src [[texture(0)]],
    texture2d<half, access::write>  dst [[texture(1)]],
    uint2 gid                           [[thread_position_in_grid]]
) {
    uint w = dst.get_width();
    uint h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float dx = 1.65f / float(w);

    const float weights[5] = { 0.227027f, 0.1945946f, 0.1216216f, 0.054054f, 0.016216f };
    float3 sum = float3(src.sample(lin, uv).rgb) * weights[0];
    for (int i = 1; i < 5; ++i) {
        float off = dx * float(i);
        sum += float3(src.sample(lin, uv + float2(off, 0.0f)).rgb) * weights[i];
        sum += float3(src.sample(lin, uv - float2(off, 0.0f)).rgb) * weights[i];
    }
    dst.write(half4(half3(sum), half(1.0f)), gid);
}

kernel void bloomBlurV(
    texture2d<half, access::sample> src [[texture(0)]],
    texture2d<half, access::write>  dst [[texture(1)]],
    uint2 gid                           [[thread_position_in_grid]]
) {
    uint w = dst.get_width();
    uint h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float dy = 1.65f / float(h);

    const float weights[5] = { 0.227027f, 0.1945946f, 0.1216216f, 0.054054f, 0.016216f };
    float3 sum = float3(src.sample(lin, uv).rgb) * weights[0];
    for (int i = 1; i < 5; ++i) {
        float off = dy * float(i);
        sum += float3(src.sample(lin, uv + float2(0.0f, off)).rgb) * weights[i];
        sum += float3(src.sample(lin, uv - float2(0.0f, off)).rgb) * weights[i];
    }
    dst.write(half4(half3(sum), half(1.0f)), gid);
}

inline float3 acesFilm(float3 x) {
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

kernel void compositeToDrawable(
    texture2d<half, access::sample>  hdrTex   [[texture(0)]],
    texture2d<half, access::sample>  bloomTex [[texture(1)]],
    texture2d<float, access::write>  outTex   [[texture(2)]],
    constant MirrorParams &P                  [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]]
) {
    uint w = outTex.get_width();
    uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float2 px = 1.0f / float2(hdrTex.get_width(), hdrTex.get_height());

    // Lightweight 5-tap edge-aware anti-aliasing on high-contrast mirror filaments
    float3 cM = float3(hdrTex.sample(lin, uv).rgb);
    float3 cN = float3(hdrTex.sample(lin, uv + float2(0.0f, -px.y)).rgb);
    float3 cS = float3(hdrTex.sample(lin, uv + float2(0.0f,  px.y)).rgb);
    float3 cE = float3(hdrTex.sample(lin, uv + float2( px.x, 0.0f)).rgb);
    float3 cW = float3(hdrTex.sample(lin, uv + float2(-px.x, 0.0f)).rgb);

    float lM = dot(cM, float3(0.299f, 0.587f, 0.114f));
    float lMax = max(lM, max(max(dot(cN, float3(0.299f, 0.587f, 0.114f)), dot(cS, float3(0.299f, 0.587f, 0.114f))),
                             max(dot(cE, float3(0.299f, 0.587f, 0.114f)), dot(cW, float3(0.299f, 0.587f, 0.114f)))));
    float lMin = min(lM, min(min(dot(cN, float3(0.299f, 0.587f, 0.114f)), dot(cS, float3(0.299f, 0.587f, 0.114f))),
                             min(dot(cE, float3(0.299f, 0.587f, 0.114f)), dot(cW, float3(0.299f, 0.587f, 0.114f)))));
    float contrast = (lMax - lMin) / max(lMax, 0.25f);
    float3 avg4 = 0.25f * (cN + cS + cE + cW);
    float3 hdr;
    if (P.spp == 1u && contrast > 0.35f) {
        hdr = mix(cM, avg4, clamp((contrast - 0.35f) * 0.45f, 0.0f, 0.35f));
    } else if (P.spp >= 4u) {
        // Subtle Contrast-Adaptive Sharpening (CAS) for tack-sharp 4K/5K optical edges without ringing
        float sharpW = 0.22f * (1.0f - clamp(contrast * 0.75f, 0.0f, 0.85f));
        hdr = max(cM + (cM - avg4) * sharpW, float3(0.0f));
    } else {
        hdr = cM;
    }

    float3 bloom = float3(bloomTex.sample(lin, uv).rgb);
    float3 linearCol = (hdr + bloom * 0.34f) * P.exposure;

    // Subtle cinema vignette
    float2 q = uv - 0.5f;
    linearCol *= (1.0f - 0.26f * dot(q, q));

    float3 mapped = acesFilm(linearCol);
    // sRGB transfer + subtle dither to eliminate 8-bit banding in deep dark mirror fades
    float3 srgb = pow(max(mapped, float3(0.0f)), float3(1.0f / 2.2f));
    float dither = (hash12(float2(gid)) - 0.5f) / 255.0f;
    outTex.write(float4(clamp(srgb + dither, 0.0f, 1.0f), 1.0f), gid);
}
