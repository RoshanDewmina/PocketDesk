// The home hero's background, in one of four looks (?bg=reach|spectrum|aurora|bloom on preview hosts only;
// everyone else gets the look the page carries in data-bg, set from site.config.ts `look.heroBackground`). "reach" is concept 21's original halftone art (reach.ts, a 2D canvas in a
// worker); the other three are one WebGL quad each, drawn here:
//   spectrum  full-rainbow light curtains hanging from the top, swaying, some columns read as LED dots
//   aurora    the same curtains in the Reach ember palette only
//   bloom     a soft ember/amber/gold bloom seen through a coarse LED tile grid, breathing and turning
// A CSS poster of the same look (home.css + the generated poster.css) is there from the first paint and matches
// the shader's first frame; the shader fades in over it. ≤ 30 fps (24 on phones), rendered below full resolution,
// paused off screen and on hidden tabs, frozen by the pause button. Reduce Motion, Save-Data and software-only
// WebGL (no GPU) show the poster.

import { isPaused, motionAllowed, onMotionChange, prefersReduced } from "../scripts/motion";
import { BLOOM, DOT_CELL, DOT_COLS, T0 } from "./pattern";

export const LOOKS = ["reach", "spectrum", "aurora", "bloom"] as const;
export type Look = (typeof LOOKS)[number];

const preview = () => /(^|\.)pages\.dev$|^localhost$|^127\.0\.0\.1$/.test(location.hostname);

/** The look from ?bg= on a preview host, else the page's data-bg (site.config.ts). Sets the poster straight away. */
export function pickLook(el: HTMLElement): Look {
  const q = preview() ? (new URLSearchParams(location.search).get("bg") as Look | null) : null;
  const set = el.dataset.bg as Look | undefined;
  const look: Look = q && (LOOKS as readonly string[]).includes(q) ? q : set && (LOOKS as readonly string[]).includes(set) ? set : "reach";
  el.dataset.bg = look;
  return look;
}

const VERT = `attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}`;

// Hashes use only multiply/add/fract (no sin of large numbers), so every GPU draws the same picture and it
// stays stable however long the page is open; src/hero-bg/pattern.ts mirrors them for the poster.
const FRAG = `precision highp float;
uniform vec2 uRes;
uniform float uScale;
uniform float uTime;
uniform int uMode;

float h1(float p){p=fract(p*.1031);p*=p+33.33;p*=p+p;return fract(p);}
float h2(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}
float n1(float x){float i=floor(x),f=fract(x);return mix(h1(i),h1(i+1.),f*f*(3.-2.*f));}
vec3 hsv(float h,float s,float v){vec3 k=clamp(abs(mod(h*6.+vec3(0.,4.,2.),6.)-3.)-1.,0.,1.);return v*mix(vec3(1.),k,s);}

vec3 ember(float t){
  t=fract(t)*5.;
  vec3 a=vec3(.42,.04,.03),b=vec3(1.,.357,.122),c=vec3(1.,.58,.16),d=vec3(1.,.78,.3),e=vec3(.95,.36,.42);
  if(t<1.)return mix(a,b,t);
  if(t<2.)return mix(b,c,t-1.);
  if(t<3.)return mix(c,d,t-2.);
  if(t<4.)return mix(d,e,t-3.);
  return mix(e,a,t-4.);
}

vec3 curtain(float x,float y,float t,bool spec){
  float sway=(n1(y*2.6+t*.13)-.5)*.05*(.25+y)+sin(t*.19+y*2.1)*.014*y;
  float xs=x+sway;
  float n=n1(xs*6.+t*.025);
  float b=smoothstep(.22,.92,.5+.5*sin(xs*34.+n*5.5+t*.11));
  float s=.62+.38*n1(xs*150.+t*.5);
  float len=.5+.45*n1(xs*4.3+13.7+t*.018);
  float fall=1.-smoothstep(0.,len,y);
  fall*=fall;
  float I=b*s*fall*(.86+.14*sin(y*13.-t*1.1+xs*19.));
  vec3 col=spec?hsv(fract(-xs*.92+.03*sin(t*.09)),.82,1.):ember(xs*1.25+n*.35+t*.012);
  return col*I;
}

vec3 curtains(vec2 p,vec2 S,float t,bool spec){
  float x=p.x/S.x,y=p.y/S.y;
  bool narrow=S.x<640.;
  float g=floor(x*(narrow?${DOT_COLS.narrow}.:${DOT_COLS.wide}.));
  if(h1(g*7.31+2.)>.58){
    float cell=narrow?${DOT_CELL.narrow}.:${DOT_CELL.wide}.;
    vec2 c=(floor(p/cell)+.5)*cell;
    float led=1.-smoothstep(.3,.42,length(p-c)/cell);
    return curtain(c.x/S.x,c.y/S.y,t,spec)*led*1.35;
  }
  return curtain(x,y,t,spec);
}

// The LED grid is laid out in render pixels, so every tile and every grid line is the same size on screen.
vec3 bloom(vec2 fc,vec2 S,float t){
  float tp=max(4.,floor((S.x<640.?12.:16.)*uScale+.5));
  float line=max(1.,floor(1.6*uScale+.5));
  vec2 cell=floor(fc/tp);
  vec2 c=(cell+.5)*tp/uScale;
  vec2 q=c-vec2(S.x*${BLOOM.x},S.y*${BLOOM.y});
  float R=max(S.x,S.y)*${BLOOM.r}*(1.+.05*sin(t*.45));
  float ang=atan(q.y,q.x)+t*.045;
  float r=length(q)/R;
  float pet=1.+.15*sin(6.*ang)+.06*sin(11.*ang-t*.27);
  float I=exp(-r*r*pet*pet*2.6);
  vec3 col=mix(vec3(.4,.04,.03),vec3(1.,.357,.122),smoothstep(.04,.35,I));
  col=mix(col,vec3(1.,.64,.2),smoothstep(.35,.72,I));
  col=mix(col,vec3(1.,.86,.48),smoothstep(.72,1.,I));
  float fl=.93+.07*h2(cell+mod(floor(t*6.),997.));
  vec2 f=fc-cell*tp;
  float inside=step(line,f.x)*step(line,f.y);
  vec2 dd=abs(f/tp-.5)*2.;
  float led=mix(.82,1.,1.-smoothstep(.75,1.,max(dd.x,dd.y)));
  return col*I*fl*inside*led;
}

void main(){
  vec2 S=uRes/uScale;
  vec2 fc=vec2(gl_FragCoord.x,uRes.y-gl_FragCoord.y);
  vec2 p=fc/uScale;
  vec3 c=uMode==2?bloom(fc,S,uTime):curtains(p,S,uTime,uMode==0);
  c*=1.-smoothstep(.74,1.,p.y/S.y);
  gl_FragColor=vec4(vec3(.0196)+c*(uMode==2?1.:1.3),1.);
}`;

const MODE: Record<Exclude<Look, "reach">, number> = { spectrum: 0, aurora: 1, bloom: 2 };

function softwareGl(c: WebGLRenderingContext) {
  const info = c.getExtension("WEBGL_debug_renderer_info");
  const name = String(c.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : c.RENDERER));
  return /swiftshader|llvmpipe|softpipe|software|basic render/i.test(name);
}

/** Rendered at this fraction of CSS px (× DPR, capped) and scaled up: the looks are soft by design. */
const RES = 0.6;
const MAX_PIXELS = 900_000;

export function startHeroBg(el: HTMLElement, look: Exclude<Look, "reach">) {
  // Motion off now (Reduce Motion, Save-Data, or a pause remembered from an earlier visit): keep the poster,
  // and start the first time motion is allowed again.
  if (!motionAllowed()) {
    let waiting = true;
    onMotionChange(() => {
      if (waiting && motionAllowed()) {
        waiting = false;
        run(el, look);
      }
    });
    return;
  }
  run(el, look);
}

function run(el: HTMLElement, look: Exclude<Look, "reach">) {
  const cv = el.querySelector<HTMLCanvasElement>("canvas");
  if (!cv) return;
  const frameMs = 1000 / (window.innerWidth < 640 ? 24 : 30);
  let gl: WebGLRenderingContext | null = null;
  let uRes: WebGLUniformLocation | null = null, uScale: WebGLUniformLocation | null = null, uTime: WebGLUniformLocation | null = null;
  // The loop's own time, from the same start as the poster; it only advances while running.
  let t = T0;
  let raf = 0, last = 0, onScreen = true, lost = false;
  // Motion state is cached and only refreshed from onMotionChange: reading matchMedia().matches every frame would
  // refresh Chrome's cached value and swallow the "change" event the rest of the page listens for.
  let allowed = motionAllowed();

  const draw = () => {
    if (!gl || lost) return;
    gl.uniform1f(uTime, t);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  };

  const resize = () => {
    if (!gl || lost) return;
    const w = el.clientWidth, h = el.clientHeight;
    if (!w || !h) return;
    let scale = Math.min(2, window.devicePixelRatio || 1) * RES;
    if (w * h * scale * scale > MAX_PIXELS) scale = Math.sqrt(MAX_PIXELS / (w * h));
    cv.width = Math.round(w * scale);
    cv.height = Math.round(h * scale);
    gl.viewport(0, 0, cv.width, cv.height);
    gl.uniform2f(uRes, cv.width, cv.height);
    gl.uniform1f(uScale, scale);
    draw();
  };

  const init = () => {
    // Software WebGL (no usable GPU, e.g. SwiftShader): every frame would be drawn on the CPU and read back
    // for compositing, blocking the page, so the poster stays instead.
    const c = cv.getContext("webgl", { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: "low-power", failIfMajorPerformanceCaveat: true });
    if (!c || softwareGl(c)) return false;
    gl = c;
    const shader = (type: number, src: string) => {
      const s = c.createShader(type)!;
      c.shaderSource(s, src);
      c.compileShader(s);
      return c.getShaderParameter(s, c.COMPILE_STATUS) ? s : null;
    };
    const vs = shader(c.VERTEX_SHADER, VERT), fs = shader(c.FRAGMENT_SHADER, FRAG);
    if (!vs || !fs) return false;
    const prog = c.createProgram()!;
    c.attachShader(prog, vs);
    c.attachShader(prog, fs);
    c.linkProgram(prog);
    if (!c.getProgramParameter(prog, c.LINK_STATUS)) return false;
    c.useProgram(prog);
    c.bindBuffer(c.ARRAY_BUFFER, c.createBuffer());
    c.bufferData(c.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), c.STATIC_DRAW);
    const loc = c.getAttribLocation(prog, "a");
    c.enableVertexAttribArray(loc);
    c.vertexAttribPointer(loc, 2, c.FLOAT, false, 0, 0);
    uRes = c.getUniformLocation(prog, "uRes");
    uScale = c.getUniformLocation(prog, "uScale");
    uTime = c.getUniformLocation(prog, "uTime");
    c.uniform1i(c.getUniformLocation(prog, "uMode"), MODE[look]);
    lost = false;
    resize();
    return true;
  };

  const running = () => !lost && allowed && onScreen && !document.hidden;
  const frame = (now: number) => {
    raf = 0;
    if (!running()) return;
    if (!last || now - last >= frameMs - 2) {
      t += last ? Math.min(0.1, (now - last) / 1000) : 0;
      last = now;
      draw();
      el.classList.add("bg-on");
    }
    raf = requestAnimationFrame(frame);
  };
  const sync = () => {
    if (prefersReduced() && !isPaused()) el.classList.remove("bg-on");
    if (running() && !raf) {
      last = 0;
      raf = requestAnimationFrame(frame);
    } else if (!running() && raf) {
      cancelAnimationFrame(raf);
      raf = 0;
    }
  };

  if (!init()) return;
  new ResizeObserver(resize).observe(el);
  new IntersectionObserver((es) => {
    onScreen = es[es.length - 1]!.isIntersecting;
    sync();
  }).observe(el);
  document.addEventListener("visibilitychange", sync);
  onMotionChange(() => {
    allowed = motionAllowed();
    // Reduce Motion or Save-Data turned on mid-visit: back to the poster. The pause button keeps the last frame.
    sync();
  });
  // iOS drops WebGL contexts under memory pressure: show the poster, and rebuild when the browser gives it back.
  cv.addEventListener("webglcontextlost", (e) => {
    e.preventDefault();
    lost = true;
    el.classList.remove("bg-on");
    sync();
  });
  cv.addEventListener("webglcontextrestored", () => {
    if (init()) sync();
  });
  sync();
}
