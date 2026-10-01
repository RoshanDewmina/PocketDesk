// The home hero's background: one WebGL quad behind the hero, in one of three looks Roshan is choosing between
// (?bg=spectrum|aurora|bloom on the preview, spectrum by default):
//   spectrum  full-rainbow light curtains hanging from the top, swaying, some columns read as LED dots
//   aurora    the same curtains in the Reach ember palette only
//   bloom     a soft ember/amber/gold bloom seen through a coarse LED tile grid, breathing and turning
// A CSS poster of the same look (home.css, .hero-bg[data-bg]) is there from the first paint; the shader fades in
// over it once it has drawn a frame. ≤ 30 fps, rendered below full resolution, paused off screen and on hidden
// tabs, frozen by the pause button. Reduce Motion and Save-Data keep the poster and never start WebGL.

import { motionAllowed, onMotionChange } from "../scripts/motion";

export const LOOKS = ["spectrum", "aurora", "bloom"] as const;
export type Look = (typeof LOOKS)[number];

/** The look from ?bg= (preview comparison), else the default. Sets the poster straight away. */
export function pickLook(el: HTMLElement): Look {
  const q = new URLSearchParams(location.search).get("bg") as Look | null;
  const look: Look = q && (LOOKS as readonly string[]).includes(q) ? q : "spectrum";
  el.dataset.bg = look;
  return look;
}

const VERT = `attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}`;

const FRAG = `precision highp float;
uniform vec2 uRes;
uniform float uScale;
uniform float uTime;
uniform int uMode;

float h1(float n){return fract(sin(n)*43758.5453);}
float h2(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float n1(float x){float i=floor(x),f=fract(x);return mix(h1(i),h1(i+1.),f*f*(3.-2.*f));}
vec3 hsv(float h,float s,float v){vec3 k=clamp(abs(mod(h*6.+vec3(0.,4.,2.),6.)-3.)-1.,0.,1.);return v*mix(vec3(1.),k,s);}

// Reach ember palette, cyclic: deep red, ember, amber, gold, rose.
vec3 ember(float t){
  t=fract(t)*5.;
  vec3 a=vec3(.42,.04,.03),b=vec3(1.,.357,.122),c=vec3(1.,.58,.16),d=vec3(1.,.78,.3),e=vec3(.95,.36,.42);
  if(t<1.)return mix(a,b,t);
  if(t<2.)return mix(b,c,t-1.);
  if(t<3.)return mix(c,d,t-2.);
  if(t<4.)return mix(d,e,t-3.);
  return mix(e,a,t-4.);
}

// Light curtains: x,y in 0..1 of the hero (y down). Returns light.
vec3 curtain(float x,float y,float t,bool spec){
  float sway=(n1(y*2.6+t*.13)-.5)*.05*(.25+y)+sin(t*.19+y*2.1)*.014*y;
  float xs=x+sway;
  float n=n1(xs*6.+t*.025);
  float b=.5+.5*sin(xs*34.+n*5.5+t*.11);
  b=smoothstep(.22,.92,b);
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
  // Some columns are LED dots: sample the light at each cell centre and draw a round dot.
  float cols=S.x<640.?7.:12.;
  float g=floor(x*cols);
  if(h1(g*7.31+2.)>.58){
    float cell=S.x<640.?8.:10.;
    vec2 c=(floor(p/cell)+.5)*cell;
    float d=length(p-c)/cell;
    float led=1.-smoothstep(.3,.42,d);
    return curtain(c.x/S.x,c.y/S.y,t,spec)*led*1.35;
  }
  return curtain(x,y,t,spec);
}

vec3 bloom(vec2 p,vec2 S,float t){
  float tile=S.x<640.?12.:16.;
  vec2 cell=floor(p/tile);
  vec2 c=(cell+.5)*tile;
  vec2 q=c-vec2(S.x*.5,S.y*.66);
  float R=max(S.x,S.y)*.52*(1.+.05*sin(t*.45));
  float ang=atan(q.y,q.x)+t*.045;
  float r=length(q)/R;
  float pet=1.+.15*sin(6.*ang)+.06*sin(11.*ang-t*.27);
  float I=exp(-r*r*pet*pet*2.6);
  vec3 col=mix(vec3(.4,.04,.03),vec3(1.,.357,.122),smoothstep(.04,.35,I));
  col=mix(col,vec3(1.,.64,.2),smoothstep(.35,.72,I));
  col=mix(col,vec3(1.,.86,.48),smoothstep(.72,1.,I));
  float fl=.93+.07*h2(cell+floor(t*6.));
  vec2 f=fract(p/tile);
  float gap=1.6/tile;
  float inside=step(gap,f.x)*step(gap,f.y);
  vec2 dd=abs(f-.5)*2.;
  float led=mix(.82,1.,1.-smoothstep(.75,1.,max(dd.x,dd.y)));
  return col*I*fl*inside*led;
}

void main(){
  vec2 S=uRes/uScale;
  vec2 p=vec2(gl_FragCoord.x,uRes.y-gl_FragCoord.y)/uScale;
  vec3 c=uMode==2?bloom(p,S,uTime):curtains(p,S,uTime,uMode==0);
  c*=1.-smoothstep(.74,1.,p.y/S.y);
  gl_FragColor=vec4(vec3(.0196)+c*(uMode==2?1.:1.3),1.);
}`;

const MODE: Record<Look, number> = { spectrum: 0, aurora: 1, bloom: 2 };
const FRAME_MS = 1000 / 30;
/** Rendered at this fraction of CSS px (× DPR, capped) and scaled up: the looks are soft by design. */
const RES = 0.6;
const MAX_PIXELS = 900_000;

export function startHeroBg(el: HTMLElement, look: Look) {
  if (!motionAllowed()) return;
  const cv = el.querySelector<HTMLCanvasElement>("canvas");
  const gl = cv?.getContext("webgl", { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: "low-power", preserveDrawingBuffer: true });
  if (!cv || !gl) return;

  const shader = (type: number, src: string) => {
    const s = gl.createShader(type)!;
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
  };
  const vs = shader(gl.VERTEX_SHADER, VERT), fs = shader(gl.FRAGMENT_SHADER, FRAG);
  if (!vs || !fs) return;
  const prog = gl.createProgram()!;
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;
  gl.useProgram(prog);
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, "a");
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const uRes = gl.getUniformLocation(prog, "uRes"), uScale = gl.getUniformLocation(prog, "uScale"), uTime = gl.getUniformLocation(prog, "uTime");
  gl.uniform1i(gl.getUniformLocation(prog, "uMode"), MODE[look]);

  let scale = 1;
  const resize = () => {
    const w = el.clientWidth, h = el.clientHeight;
    if (!w || !h) return;
    scale = Math.min(2, window.devicePixelRatio || 1) * RES;
    if (w * h * scale * scale > MAX_PIXELS) scale = Math.sqrt(MAX_PIXELS / (w * h));
    cv.width = Math.round(w * scale);
    cv.height = Math.round(h * scale);
    gl.viewport(0, 0, cv.width, cv.height);
    gl.uniform2f(uRes, cv.width, cv.height);
    gl.uniform1f(uScale, scale);
    draw();
  };

  // A fixed start in the loop's time, so the first frame is a good one; time only advances while running.
  let t = 37;
  const draw = () => {
    gl.uniform1f(uTime, t);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  };

  let raf = 0, last = 0, onScreen = true, shown = false;
  const frame = (now: number) => {
    raf = 0;
    if (!running()) return;
    if (!last || now - last >= FRAME_MS - 2) {
      t += last ? Math.min(0.1, (now - last) / 1000) : 0;
      last = now;
      draw();
      if (!shown) {
        shown = true;
        el.classList.add("bg-on");
      }
    }
    raf = requestAnimationFrame(frame);
  };
  const running = () => motionAllowed() && onScreen && !document.hidden;
  const sync = () => {
    if (running() && !raf) {
      last = 0;
      raf = requestAnimationFrame(frame);
    }
  };

  new ResizeObserver(resize).observe(el);
  new IntersectionObserver((es) => {
    onScreen = es[es.length - 1]!.isIntersecting;
    sync();
  }).observe(el);
  document.addEventListener("visibilitychange", sync);
  onMotionChange(sync);
  cv.addEventListener("webglcontextlost", (e) => {
    e.preventDefault();
    el.classList.remove("bg-on");
  });
  resize();
  sync();
}
