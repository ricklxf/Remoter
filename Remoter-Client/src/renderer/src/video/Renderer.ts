// WebGL2 video renderer with 5-tap optimized Catmull-Rom Bicubic sampling,
// AMD FidelityFX CAS (Contrast Adaptive Sharpening), and optional ACES Filmic
// SDR tone-mapping for HDR streams.
// Supports both WebCodecs VideoFrame and WebRTC <video> zero-copy texture upload,
// with automatic fallback to 2D canvas if WebGL2 is unavailable.

export type SharpnessLevel = 'off' | 'low' | 'medium' | 'high'

const SHARPNESS_VALUES: Record<SharpnessLevel, number> = {
  off: 0.0,
  low: 0.35,
  medium: 0.65,
  high: 1.0,
}

const VERTEX_SHADER_SRC = `#version 300 es
precision highp float;

out vec2 vUv;

void main() {
  // Fullscreen triangle via gl_VertexID (no VBO needed).
  // Texel v=0 is top of image (UNPACK_FLIP_Y_WEBGL = false).
  vec2 pos;
  if (gl_VertexID == 0) {
    pos = vec2(-1.0, -1.0);
    vUv = vec2(0.0, 1.0);
  } else if (gl_VertexID == 1) {
    pos = vec2(3.0, -1.0);
    vUv = vec2(2.0, 1.0);
  } else {
    pos = vec2(-1.0, 3.0);
    vUv = vec2(0.0, -1.0);
  }
  gl_Position = vec4(pos, 0.0, 1.0);
}
`

const FRAGMENT_SHADER_SRC = `#version 300 es
precision highp float;

uniform sampler2D uTexture;
uniform vec2 uTexelSize;
uniform float uSharpness;
uniform int uToneMap;

in vec2 vUv;
out vec4 fragColor;

// 5-tap optimized Catmull-Rom Bicubic sampling leveraging hardware bilinear filtering.
// Identity at exact 1:1 texel centers (0 degradation), razor-sharp at non-1:1 / DPI scaling.
vec3 sampleCatmullRom5(sampler2D tex, vec2 uv, vec2 texSize, vec2 texelSize) {
  vec2 samplePos = uv * texSize;
  vec2 texPos1 = floor(samplePos - 0.5) + 0.5;
  vec2 f = samplePos - texPos1;

  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
  vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
  vec2 w3 = f * f * (-0.5 + 0.5 * f);

  vec2 w12 = w1 + w2;
  vec2 offset12 = w2 / max(w12, vec2(1e-5));

  vec2 texPos0  = (texPos1 - 1.0) * texelSize;
  vec2 texPos3  = (texPos1 + 2.0) * texelSize;
  vec2 texPos12 = (texPos1 + offset12) * texelSize;

  vec3 result = vec3(0.0);
  result += texture(tex, vec2(texPos12.x, texPos0.y)).rgb  * (w12.x * w0.y);
  result += texture(tex, vec2(texPos0.x,  texPos12.y)).rgb * (w0.x  * w12.y);
  result += texture(tex, vec2(texPos12.x, texPos12.y)).rgb * (w12.x * w12.y);
  result += texture(tex, vec2(texPos3.x,  texPos12.y)).rgb * (w3.x  * w12.y);
  result += texture(tex, vec2(texPos12.x, texPos3.y)).rgb  * (w12.x * w3.y);

  float weightSum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
  return clamp(result / max(weightSum, 1e-5), 0.0, 1.0);
}

// ACES Filmic SDR tone-mapping (Narkowicz 2015 fit)
vec3 acesFilmic(vec3 x) {
  const float a = 2.51;
  const float b = 0.03;
  const float c = 2.43;
  const float d = 0.59;
  const float e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
  vec2 texSize = vec2(textureSize(uTexture, 0));
  vec3 e = sampleCatmullRom5(uTexture, vUv, texSize, uTexelSize);
  vec3 color = e;

  // AMD FidelityFX CAS (Contrast Adaptive Sharpening) 5-tap cross filter
  if (uSharpness > 0.001) {
    vec3 b = texture(uTexture, vUv + vec2(0.0, -uTexelSize.y)).rgb;
    vec3 d = texture(uTexture, vUv + vec2(-uTexelSize.x, 0.0)).rgb;
    vec3 f = texture(uTexture, vUv + vec2(uTexelSize.x, 0.0)).rgb;
    vec3 h = texture(uTexture, vUv + vec2(0.0, uTexelSize.y)).rgb;

    vec3 mnRGB = min(min(min(d, e), min(f, b)), h);
    vec3 mxRGB = max(max(max(d, e), max(f, b)), h);

    vec3 rcpMxRGB = 1.0 / max(mxRGB, vec3(1e-5));
    vec3 ampRGB = clamp(min(mnRGB, 1.0 - mxRGB) * rcpMxRGB, 0.0, 1.0);
    ampRGB = sqrt(ampRGB);

    float peak = -1.0 / mix(8.0, 5.0, clamp(uSharpness, 0.0, 1.0));
    vec3 wRGB = ampRGB * peak;
    vec3 rcpWeightRGB = 1.0 / (1.0 + 4.0 * wRGB);

    color = clamp(((b + d + f + h) * wRGB + e) * rcpWeightRGB, 0.0, 1.0);
  }

  // Optional ACES Filmic SDR tone-mapping for HDR content on SDR displays
  if (uToneMap != 0) {
    vec3 linear = pow(max(color, vec3(0.0)), vec3(2.2));
    vec3 mapped = acesFilmic(linear * 1.15);
    color = pow(mapped, vec3(1.0 / 2.2));
  }

  fragColor = vec4(color, 1.0);
}
`

export class VideoRenderer {
  private canvas: HTMLCanvasElement | null = null
  private gl: WebGL2RenderingContext | null = null
  private ctx2d: CanvasRenderingContext2D | null = null

  private program: WebGLProgram | null = null
  private vao: WebGLVertexArrayObject | null = null
  private texture: WebGLTexture | null = null

  private uTextureLoc: WebGLUniformLocation | null = null
  private uTexelSizeLoc: WebGLUniformLocation | null = null
  private uSharpnessLoc: WebGLUniformLocation | null = null
  private uToneMapLoc: WebGLUniformLocation | null = null

  private _sharpness: SharpnessLevel = 'off'
  private _toneMap = false
  private texWidth = 0
  private texHeight = 0
  private videoTexWidth = 0
  private videoTexHeight = 0
  private hasTexture = false
  private pendingWidth = 0
  private pendingHeight = 0

  get isWebGL(): boolean {
    return this.gl !== null
  }

  get sharpness(): SharpnessLevel {
    return this._sharpness
  }

  get toneMap(): boolean {
    return this._toneMap
  }

  attach(canvas: HTMLCanvasElement): void {
    if (this.canvas === canvas && (this.gl || this.ctx2d)) return
    this.detach()
    this.canvas = canvas

    if (this.pendingWidth > 0 && this.pendingHeight > 0) {
      if (canvas.width !== this.pendingWidth || canvas.height !== this.pendingHeight) {
        canvas.width = this.pendingWidth
        canvas.height = this.pendingHeight
      }
    }

    if (!this.initWebGL2(canvas)) {
      this.ctx2d = canvas.getContext('2d')
      if (!this.ctx2d) {
        console.warn('[Renderer] neither WebGL2 nor 2D canvas context available')
      } else {
        console.warn('[Renderer] WebGL2 unavailable, falling back to 2D canvas')
      }
    }
  }

  setSharpness(level: SharpnessLevel): void {
    if (this._sharpness === level) return
    this._sharpness = level
    if (this.hasTexture && this.gl) {
      this.drawGL()
    }
  }

  setToneMap(enabled: boolean): void {
    if (this._toneMap === enabled) return
    this._toneMap = enabled
    if (this.hasTexture && this.gl) {
      this.drawGL()
    }
  }

  renderFrame(frame: VideoFrame): void {
    try {
      const canvas = this.canvas
      if (!canvas) return

      const srcW = frame.displayWidth || frame.codedWidth
      const srcH = frame.displayHeight || frame.codedHeight
      if (srcW <= 0 || srcH <= 0) return

      if (this.gl && !this.gl.isContextLost()) {
        this.uploadAndDraw(frame, srcW, srcH)
      } else if (this.ctx2d) {
        this.ctx2d.drawImage(frame, 0, 0, canvas.width, canvas.height)
      }
    } finally {
      frame.close()
    }
  }

  renderVideo(video: HTMLVideoElement): void {
    const canvas = this.canvas
    if (!canvas) return
    if (video.readyState < 2 || video.videoWidth <= 0 || video.videoHeight <= 0) return

    const srcW = video.videoWidth
    const srcH = video.videoHeight

    if (canvas.width === 0 || canvas.height === 0) {
      this.resize(srcW, srcH)
    }

    if (this.gl && !this.gl.isContextLost()) {
      this.uploadAndDraw(video, srcW, srcH)
    } else if (this.ctx2d) {
      this.ctx2d.drawImage(video, 0, 0, canvas.width, canvas.height)
    }
  }

  resize(width: number, height: number): void {
    if (width <= 0 || height <= 0) return
    this.pendingWidth = width
    this.pendingHeight = height

    if (!this.canvas) return
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width
      this.canvas.height = height
    }
    if (this.gl && !this.gl.isContextLost()) {
      this.gl.viewport(0, 0, width, height)
      if (this.hasTexture) {
        this.drawGL()
      }
    }
  }

  detach(): void {
    if (this.gl && !this.gl.isContextLost()) {
      if (this.texture) this.gl.deleteTexture(this.texture)
      if (this.vao) this.gl.deleteVertexArray(this.vao)
      if (this.program) this.gl.deleteProgram(this.program)
    }
    this.texture = null
    this.vao = null
    this.program = null
    this.uTextureLoc = null
    this.uTexelSizeLoc = null
    this.uSharpnessLoc = null
    this.uToneMapLoc = null
    this.gl = null
    this.ctx2d = null
    this.canvas = null
    this.hasTexture = false
    this.texWidth = 0
    this.texHeight = 0
    this.videoTexWidth = 0
    this.videoTexHeight = 0
  }

  // MARK: - WebGL2 Internals

  private initWebGL2(canvas: HTMLCanvasElement): boolean {
    const attrs: WebGLContextAttributes = {
      alpha: false,
      antialias: false,
      depth: false,
      stencil: false,
      preserveDrawingBuffer: false,
      powerPreference: 'high-performance',
      desynchronized: true,
    }
    let gl = canvas.getContext('webgl2', attrs)
    if (!gl) {
      gl = canvas.getContext('webgl2', { ...attrs, desynchronized: false })
    }
    if (!gl) return false

    const vs = this.compileShader(gl, gl.VERTEX_SHADER, VERTEX_SHADER_SRC)
    const fs = this.compileShader(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER_SRC)
    if (!vs || !fs) {
      if (vs) gl.deleteShader(vs)
      if (fs) gl.deleteShader(fs)
      return false
    }

    const program = gl.createProgram()
    if (!program) {
      gl.deleteShader(vs)
      gl.deleteShader(fs)
      return false
    }

    gl.attachShader(program, vs)
    gl.attachShader(program, fs)
    gl.linkProgram(program)
    gl.deleteShader(vs)
    gl.deleteShader(fs)

    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      console.error('[Renderer] WebGL2 program link error:', gl.getProgramInfoLog(program))
      gl.deleteProgram(program)
      return false
    }

    const vao = gl.createVertexArray()
    const texture = gl.createTexture()
    if (!vao || !texture) {
      if (vao) gl.deleteVertexArray(vao)
      if (texture) gl.deleteTexture(texture)
      gl.deleteProgram(program)
      return false
    }

    gl.bindTexture(gl.TEXTURE_2D, texture)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, 0)

    this.gl = gl
    this.program = program
    this.vao = vao
    this.texture = texture
    this.uTextureLoc = gl.getUniformLocation(program, 'uTexture')
    this.uTexelSizeLoc = gl.getUniformLocation(program, 'uTexelSize')
    this.uSharpnessLoc = gl.getUniformLocation(program, 'uSharpness')
    this.uToneMapLoc = gl.getUniformLocation(program, 'uToneMap')

    gl.viewport(0, 0, canvas.width, canvas.height)
    return true
  }

  private compileShader(gl: WebGL2RenderingContext, type: number, source: string): WebGLShader | null {
    const shader = gl.createShader(type)
    if (!shader) return null
    gl.shaderSource(shader, source)
    gl.compileShader(shader)
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      console.error('[Renderer] WebGL2 shader compile error:', gl.getShaderInfoLog(shader))
      gl.deleteShader(shader)
      return null
    }
    return shader
  }

  private uploadAndDraw(source: VideoFrame | HTMLVideoElement, srcW: number, srcH: number): void {
    const gl = this.gl
    const canvas = this.canvas
    if (!gl || !canvas || !this.texture) return

    gl.activeTexture(gl.TEXTURE0)
    gl.bindTexture(gl.TEXTURE_2D, this.texture)
    if (!this.hasTexture || this.videoTexWidth !== srcW || this.videoTexHeight !== srcH) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source)
      this.videoTexWidth = srcW
      this.videoTexHeight = srcH
    } else {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, source)
    }

    this.texWidth = srcW
    this.texHeight = srcH
    this.hasTexture = true

    this.drawGL()
  }

  private drawGL(): void {
    const gl = this.gl
    const canvas = this.canvas
    if (!gl || !canvas || !this.program || !this.vao || !this.texture || gl.isContextLost()) return

    gl.viewport(0, 0, canvas.width, canvas.height)
    gl.useProgram(this.program)
    gl.bindVertexArray(this.vao)

    gl.activeTexture(gl.TEXTURE0)
    gl.bindTexture(gl.TEXTURE_2D, this.texture)
    if (this.uTextureLoc) gl.uniform1i(this.uTextureLoc, 0)
    if (this.uTexelSizeLoc && this.texWidth > 0 && this.texHeight > 0) {
      gl.uniform2f(this.uTexelSizeLoc, 1.0 / this.texWidth, 1.0 / this.texHeight)
    }
    if (this.uSharpnessLoc) gl.uniform1f(this.uSharpnessLoc, SHARPNESS_VALUES[this._sharpness])
    if (this.uToneMapLoc) gl.uniform1i(this.uToneMapLoc, this._toneMap ? 1 : 0)

    gl.drawArrays(gl.TRIANGLES, 0, 3)
  }
}
