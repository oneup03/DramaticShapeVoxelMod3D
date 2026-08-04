-- Stereoscopic 3D: packing two eyes into one picture the display can undo.
--
-- Three fullscreen passes and their shaders, in the idiom AntiAlias.resolve
-- and TiltShift.apply already use here: a per-slot cached target, replace
-- blending, one love.graphics.draw as the quad, and every piece of state put
-- back the way the rest of the frame expects to find it.
--
--   apply()     the compose. Six output layouts, one shader, one branch.
--   lift()      the UI recovery (see Stereo3D): the finished frame minus the
--               world it was drawn over, composited onto the second eye.
--   coverage()  how much of the frame that mask claims, read back to the CPU
--               so the answer can be a decision rather than a hope.
--
-- ------- one shader, six layouts
--
-- Every mode bottoms out in ONE function, SampleEye. That is not tidiness:
-- it is what makes the eye swap a single uniform. A swap applied per branch
-- gets applied twice in one of them and missed in another, and the symptom
-- -- side-by-side reads correctly, row-interlaced reads inside-out -- is
-- unattributable from the outside.
--
-- ------- and it runs at the OUTPUT resolution
--
-- The eye textures may be smaller than the window (a low render scale) or
-- larger (the AA rungs render big and fold back down). The compose does not
-- care, because the upscale is not a pass: it is the bilinear sample inside
-- SampleEye, and it happens at the moment the eye is read.
--
-- What that buys is the thing every line-select mode lives or dies by. ROW,
-- COL and CHECK pick their pattern from the OUTPUT pixel index -- one
-- display row, one display column -- and never from the eye texture's own
-- texel grid. Pack first and scale afterwards and the pattern's pitch drifts
-- with the render resolution, which reads as a moire that changes when you
-- touch a graphics setting and is exceptionally hard to diagnose.
--
-- The output pixel is taken from `tc`, the quad's own texture coordinate,
-- rather than from screen coordinates. The pass draws into a target the same
-- size as the quad, so the two agree -- and `tc` is the coordinate the
-- sampling already uses, which sidesteps the canvas-versus-backbuffer
-- Y-origin question entirely rather than settling it by experiment.
--
-- ------- dialect
--
-- LOVE's default GLSL, not glsl3. There are no integer bit operators here,
-- so parity is mod(floor(x), 2) -- which is EXACT: an output pixel index is
-- an integer well under a float's 24 bits of mantissa, and floor and mod on
-- exact integers are exact. The alternative would be a second compiled
-- variant behind a getSupported().glsl3 probe, on a mod that ships to
-- Android where glsl3 means GLES 3.0 and is not a given.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local PixelCanvas = V.require("PixelCanvas")
local GLBridge = V.require("GLBridge")
local Perf = V.require("Perf")

local StereoCompose = {}

StereoCompose.MODE_SBS = 0
StereoCompose.MODE_TAB = 1
StereoCompose.MODE_ROW = 2
StereoCompose.MODE_COL = 3
StereoCompose.MODE_CHECKER = 4
StereoCompose.MODE_ANAGLYPH = 5

local COMPOSE = [[
  extern Image eyeR;
  extern vec2 outSize;      // the output's own pixel dimensions
  extern float mode;        // 0 SBS  1 TAB  2 ROW  3 COL  4 CHECKER  5 ANAGL
  extern float swapEyes;    // the compositor's convention (see StereoRig)
  extern float parityFlip;  // the interlace PHASE, which is not the same thing
  extern float flipY;       // hand the result to GL rather than to LOVE

  // The single point of truth for eye order. `idx` is a HALF of the output
  // layout, not an eye, and this is the one place the two are related.
  vec4 SampleEye(float idx, vec2 uv, Image left) {
    float i = mix(idx, 1.0 - idx, swapEyes);
    // clamped, so a half-pixel of bilinear reach at the seam cannot fetch
    // the other eye's edge and hang a bright line down the middle
    vec2 c = clamp(uv, vec2(0.0), vec2(1.0));
    if (i < 0.5) return Texel(left, c);
    return Texel(eyeR, c);
  }

  // Red-cyan, by the Dubois least-squares matrix: the one that solves for
  // what the two filters actually pass rather than simply throwing away two
  // channels, which is why it keeps colour where the naive version leaves
  // grey and why its ghosting is as low as anaglyph gets.
  //
  // Colour only. The alpha is CARRIED, never forced to one: the scene canvas
  // clears to transparent (see AntiAlias's header) and a matrix run over
  // nothing returns black, so an opaque result would paint every empty
  // pixel of the diorama's void solid.
  vec3 Dubois(vec3 L, vec3 R) {
    return vec3(
      dot(L, vec3( 0.437,  0.449,  0.164)) + dot(R, vec3(-0.011, -0.032, -0.007)),
      dot(L, vec3(-0.062, -0.062, -0.024)) + dot(R, vec3( 0.377,  0.761,  0.009)),
      dot(L, vec3(-0.048, -0.050, -0.017)) + dot(R, vec3(-0.026, -0.093,  1.234)));
  }

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // The whole pass in ONE coordinate, flipped or not. LOVE stores a canvas
    // with row zero at the TOP; GL reads a texture with v = 0 at the BOTTOM.
    // Every consumer inside LOVE agrees with LOVE, so this is identity for
    // all of them -- and the SR weaver is not inside LOVE, which is the one
    // case that has to be handed the other convention. See LeiaSR.
    vec2 uv = vec2(tc.x, mix(tc.y, 1.0 - tc.y, flipY));
    vec2 px = floor(uv * outSize);
    float m = floor(mode + 0.5);

    if (m < 0.5) {                                    // SIDE BY SIDE
      float half_ = step(0.5, uv.x);                  // left of centre is L
      return SampleEye(half_, vec2(fract(uv.x * 2.0), uv.y), tex) * color;
    }
    if (m < 1.5) {                                    // TOP AND BOTTOM
      float half_ = step(0.5, uv.y);                  // no gap: this is not
      return SampleEye(half_, vec2(uv.x, fract(uv.y * 2.0)), tex) * color;
    }                                                 // HDMI frame packing
    if (m < 2.5)                                      // ROW INTERLACED
      return SampleEye(step(0.5, mod(px.y + parityFlip, 2.0)), uv, tex) * color;
    if (m < 3.5)                                      // COLUMN INTERLACED
      return SampleEye(step(0.5, mod(px.x + parityFlip, 2.0)), uv, tex) * color;
    if (m < 4.5)                                      // CHECKERBOARD
      return SampleEye(step(0.5, mod(px.x + px.y + parityFlip, 2.0)), uv, tex)
             * color;

    vec4 L = SampleEye(0.0, uv, tex);                 // RED-CYAN DUBOIS
    vec4 R = SampleEye(1.0, uv, tex);
    return vec4(clamp(Dubois(L.rgb, R.rgb), 0.0, 1.0), max(L.a, R.a)) * color;
  }
]]

-- The UI lift. `tex` is the finished frame -- world AND the engine's own 2D
-- over it -- and `worldL` the private copy of the left eye taken before the
-- engine touched it. Where the two differ, something was drawn there.
--
-- A threshold rather than an exact compare, because the frame has been
-- through the backbuffer's own precision on the way here and a bit of the
-- bottom channel is not an interface. And the alpha is compared too: a
-- dialog drawn over the void at the shallow rungs changes nothing but the
-- coverage, and a colour-only test would miss it entirely.
local LIFT = [[
  extern Image worldL;
  extern Image worldR;
  extern float eps;

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 F = Texel(tex, tc);
    vec4 L = Texel(worldL, tc);
    vec3 d = abs(F.rgb - L.rgb);
    float ui = step(eps, max(d.r, max(d.g, d.b)));
    ui = max(ui, step(eps, abs(F.a - L.a)));
    return mix(Texel(worldR, tc), F, ui) * color;
  }
]]

-- The same mask, as a picture, for counting. Rendered small: the question is
-- what FRACTION of the frame the mask claims, and a 64x36 average answers it
-- as well as a full-resolution one for a hundredth of the readback.
local MASK = [[
  extern Image worldL;
  extern float eps;

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 F = Texel(tex, tc);
    vec4 L = Texel(worldL, tc);
    vec3 d = abs(F.rgb - L.rgb);
    float ui = step(eps, max(d.r, max(d.g, d.b)));
    ui = max(ui, step(eps, abs(F.a - L.a)));
    return vec4(ui, ui, ui, 1.0);
  }
]]

-- one channel step of an 8-bit backbuffer, and a half for the rounding
StereoCompose.EPS = 1.5 / 255

local shaders = {}            -- src -> shader, or false where it would not build

local function shaderFor(src)
  local got = shaders[src]
  if got ~= nil then return got or nil end
  local ok, sh = pcall(love.graphics.newShader, src)
  shaders[src] = (ok and sh) or false
  return shaders[src] or nil
end

-- ------- targets
--
-- One per named slot, reallocated only when its size changes -- a window
-- resize, or the LEIA rung's double-wide intermediate arriving.

local targets = {}

local function targetFor(slot, w, h)
  local t = targets[slot]
  if not (t and t.w == w and t.h == h) then
    local ok, c = PixelCanvas.new(w, h)
    if not (ok and c) then return nil end
    -- nearest, because this canvas is composited one of its pixels to one
    -- display pixel and any filtering at all would smear a pattern whose
    -- whole meaning is which pixel it landed on
    pcall(c.setFilter, c, "nearest", "nearest")
    if t and t.canvas and t.canvas.release then pcall(t.canvas.release, t.canvas) end
    targets[slot] = { canvas = c, w = w, h = h }
    t = targets[slot]
  end
  return t.canvas
end

-- Run `body` as a fullscreen pass into `target`, with the graphics state
-- saved, set the way an image-processing copy needs it, and put back.
--
-- `linear` lists the textures the pass will magnify and so wants filtered.
-- Their old filters are READ and restored rather than assumed to have been
-- nearest: one of them is the engine's own finished frame, and handing that
-- back with a filter it did not have is the kind of change that shows up
-- three passes later somewhere else entirely.
local function pass(target, sh, linear, body)
  if not (target and sh) then return false end
  local prevBlend, prevAlpha = love.graphics.getBlendMode()
  local hadFilter = {}
  for i, tex in ipairs(linear) do
    if tex then
      local okF, minF, magF = pcall(tex.getFilter, tex)
      if okF then hadFilter[i] = { minF, magF } end
      pcall(tex.setFilter, tex, "linear", "linear")
    end
  end
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("replace", "premultiplied")
  local ok = pcall(function()
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 0)
    body()
  end)
  love.graphics.setCanvas()
  love.graphics.setShader()
  love.graphics.setBlendMode(prevBlend or "alpha", prevAlpha)
  for i, tex in ipairs(linear) do
    local was = hadFilter[i]
    if tex and was then pcall(tex.setFilter, tex, was[1], was[2]) end
  end
  return ok
end

-- ------- the passes

-- A straight copy of `src` into `dst`, which is how the left eye is kept
-- somewhere the engine's UI compositing cannot reach. Nearest and 1:1, so
-- this is a blit and not a resample.
function StereoCompose.copy(src, dst)
  if not (src and dst) then return nil end
  local t0 = Perf.now()
  local prevBlend, prevAlpha = love.graphics.getBlendMode()
  love.graphics.setShader()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("replace", "premultiplied")
  local ok = pcall(function()
    love.graphics.setCanvas(dst)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.draw(src, 0, 0)
  end)
  love.graphics.setCanvas()
  love.graphics.setBlendMode(prevBlend or "alpha", prevAlpha)
  Perf.add("Stereo.copy", t0)
  return ok and dst or nil
end

-- Pack `left` and `right` into one `w` x `h` picture. `p` is
-- { mode, swap, parity }; `slot` names the target, so the LEIA rung can ask
-- for a wider one without evicting the ordinary path's.
function StereoCompose.apply(left, right, w, h, p, slot, ow, oh)
  if not (left and right and w and h and w > 0 and h > 0) then return nil end
  local sh = shaderFor(COMPOSE)
  if not sh then return nil end
  ow, oh = ow or w, oh or h
  local target = targetFor(slot or "compose", ow, oh)
  if not target then return nil end

  pcall(sh.send, sh, "eyeR", right)
  pcall(sh.send, sh, "outSize", { ow, oh })
  pcall(sh.send, sh, "mode", p.mode or 0)
  pcall(sh.send, sh, "swapEyes", p.swap and 1 or 0)
  pcall(sh.send, sh, "parityFlip", p.parity and 1 or 0)
  pcall(sh.send, sh, "flipY", p.flip and 1 or 0)

  local t0 = Perf.now()
  local lw, lh = left:getDimensions()
  local ok = pass(target, sh, { left, right }, function()
    love.graphics.draw(left, 0, 0, 0, ow / lw, oh / lh)
  end)
  Perf.add("Stereo.compose", t0)
  return ok and target or nil
end

-- Rebuild the right eye from the finished frame: the world it disagrees
-- with `worldL` about is the interface, and that goes on `worldR` too.
function StereoCompose.lift(frame, worldL, worldR, w, h)
  if not (frame and worldL and worldR) then return nil end
  local sh = shaderFor(LIFT)
  if not sh then return nil end
  local target = targetFor("lift", w, h)
  if not target then return nil end

  pcall(sh.send, sh, "worldL", worldL)
  pcall(sh.send, sh, "worldR", worldR)
  pcall(sh.send, sh, "eps", StereoCompose.EPS)

  local t0 = Perf.now()
  local fw, fh = frame:getDimensions()
  local ok = pass(target, sh, {}, function()
    love.graphics.draw(frame, 0, 0, 0, w / fw, h / fh)
  end)
  Perf.add("Stereo.lift", t0)
  return ok and target or nil
end

-- ------- watching how much of the frame the mask claims
--
-- The number that says whether the interface lift is lifting an INTERFACE
-- or being handed a picture that changed all over. A dialog box claims a
-- few per cent. A full-screen flash claims all of it -- and a flash is a
-- frame with no depth to give, because there is nothing left to lift out
-- of it.
--
-- Measured EVERY frame, which means it has to be nearly free, and the
-- obvious way to get it is the most expensive thing in the mod.
--
-- Reading a pixel back the ordinary way -- Canvas:newImageData, which is
-- glReadPixels underneath -- is SYNCHRONOUS with every GL command issued
-- before it. The driver drains the queue and waits for the GPU, which in a
-- mod that renders the scene twice is most of a frame. The size of the
-- canvas is irrelevant; the stall is the pipeline. Once a frame, it stops
-- the CPU and the GPU overlapping at all, and that reads as stutter.
--
-- So it goes through GLBridge.readMeanAsync, which queues the copy into a
-- pixel-pack buffer and collects it two frames later. The answer is two
-- frames old, which for a decision that holds for twenty is not old at all.
-- Where those entry points are missing the blocking path is still here, one
-- frame in eight, which is slow enough to be survivable and often enough to
-- catch a flash.
--
-- 16 x 9 rather than the frame's own size: this is a FRACTION, and 144
-- samples spread over the picture answer it as well as two million would.
local WATCH_W, WATCH_H = 16, 9
local SLOW_EVERY = 8
local watchTick = 0

-- Render the mask small, and return the coverage measured off an earlier
-- one, 0 to 1 -- or nil on the frames there is no answer ready for.
function StereoCompose.watch(frame, worldL, w, h)
  if not (frame and worldL) then return nil end
  local sh = shaderFor(MASK)
  if not sh then return nil end
  local target = targetFor("watch", WATCH_W, WATCH_H)
  if not target then return nil end

  watchTick = watchTick + 1
  local async = GLBridge.asyncReadAvailable()
  if not async and (watchTick % SLOW_EVERY) ~= 0 then return nil end
  local t0 = Perf.now()

  pcall(sh.send, sh, "worldL", worldL)
  pcall(sh.send, sh, "eps", StereoCompose.EPS)
  local fw, fh = frame:getDimensions()
  -- linear on the way down, so a one-pixel-wide difference still registers
  -- as a fraction of a cell rather than being missed between samples
  local ok = pass(target, sh, { frame, worldL }, function()
    love.graphics.draw(frame, 0, 0, 0, WATCH_W / fw, WATCH_H / fh)
  end)
  if not ok then return nil end

  if async then
    local fbo = GLBridge.canvasFBO(target)
    if fbo then
      local mean = GLBridge.readMeanAsync(fbo, WATCH_W, WATCH_H)
      Perf.add("Stereo.watch", t0)
      return mean
    end
  end

  local okData, data = pcall(target.newImageData, target)
  if not (okData and data) then return nil end
  local sum = 0
  for y = 0, WATCH_H - 1 do
    for x = 0, WATCH_W - 1 do
      sum = sum + data:getPixel(x, y)
    end
  end
  if data.release then pcall(data.release, data) end
  -- named apart from the async one on purpose: the two are the same
  -- question asked at wildly different prices, and a report that lumped
  -- them together would hide which one this run paid
  Perf.add("Stereo.watchBlocking", t0)
  return sum / (WATCH_W * WATCH_H)
end

-- The same measurement, taken now and waited for. For the probes, which
-- want an answer this instant and do not care what it costs.
function StereoCompose.coverage(frame, worldL, w, h)
  if not (frame and worldL) then return nil end
  local sh = shaderFor(MASK)
  local target = targetFor("watch", WATCH_W, WATCH_H)
  if not (sh and target) then return nil end
  pcall(sh.send, sh, "worldL", worldL)
  pcall(sh.send, sh, "eps", StereoCompose.EPS)
  local fw, fh = frame:getDimensions()
  if not pass(target, sh, { frame, worldL }, function()
    love.graphics.draw(frame, 0, 0, 0, WATCH_W / fw, WATCH_H / fh)
  end) then return nil end
  local okData, data = pcall(target.newImageData, target)
  if not (okData and data) then return nil end
  local sum = 0
  for y = 0, WATCH_H - 1 do
    for x = 0, WATCH_W - 1 do
      sum = sum + data:getPixel(x, y)
    end
  end
  if data.release then pcall(data.release, data) end
  return sum / (WATCH_W * WATCH_H)
end

-- Drop the GPU objects (window resize, hot reload).
function StereoCompose.invalidate()
  for slot, t in pairs(targets) do
    if t.canvas and t.canvas.release then pcall(t.canvas.release, t.canvas) end
    targets[slot] = nil
  end
end

return StereoCompose
