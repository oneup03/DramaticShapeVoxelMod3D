-- LeiaSR: the autostereoscopic weave, and the ladder of reasons it might
-- not happen.
--
-- A Simulated Reality panel is a lenticular display with a camera watching
-- your eyes. The runtime knows where they are; a WEAVER takes a side-by-side
-- image and interleaves it into the exact subpixel pattern that puts the
-- left half in front of your left eye at the position you are actually
-- sitting in. Every frame. That is the whole of the technique, and all this
-- mod has to do is hand over one texture and get out of the way.
--
-- ------- why there is a DLL in the middle
--
-- The weaver is a C++ class with virtual inheritance, compiled by MSVC.
-- LuaJIT's FFI can call C, and only C: there is no name, no vtable layout
-- and no `this` adjustment it could get right. So the mod ships a shim --
-- four flat C functions over the SR SDK, built by MSVC in this repository's
-- own CI (see leiasr_shim/):
--
--   int  srk_init(void *hwnd)             1 ready, 0 unavailable
--   void srk_weave(unsigned tex, int w, int h)
--   int  srk_lens(int enable)             the switchable lens, if there is one
--   void srk_shutdown(void)
--
-- srk_lens arrived after the other three, and an older shim next to a newer
-- mod is a thing that happens, so every call to it is guarded: a shim that
-- does not export it is a shim that cannot express the preference, which is
-- exactly how a panel with no switchable lens behaves anyway.
--
-- Everything version-specific, every delay-load, and the whole SR SDK stay
-- behind that boundary. This file's dependency is one DLL that may or may
-- not be there.
--
-- ------- the input contract
--
-- ONE texture, both eyes packed side by side, and `w` is the COMBINED width
-- -- not the per-eye one. Feeding it half of that is the classic mistake and
-- its symptom is a picture stretched to twice the panel with only the left
-- eye visible.
--
-- Fed at 2W x H rather than W x H: the weaver samples uv.x in [0, 0.5] for
-- the left eye and [0.5, 1] for the right, so a panel-width SbS gives it a
-- half-width eye to magnify before it can interleave. Twice the width means
-- it samples each eye at 1:1 and the interleave is the only resampling in
-- the chain.
--
-- ------- and where the weave lands
--
-- Into the DEFAULT FRAMEBUFFER, at the end of the frame, over the top of the
-- side-by-side image that was going to be presented anyway. Not into a
-- canvas: LOVE draws canvases with row zero at the top and GL writes them
-- with row zero at the bottom, and a woven image flipped vertically has its
-- lenticular slant mirrored, which is not 3D that is upside down -- it is no
-- 3D at all.
--
-- Which makes the fallback free rather than something to arrange. No shim,
-- no runtime, no panel, or a weave that threw: nothing overwrites the back
-- buffer and what stays on screen is plain side-by-side, exactly as the LEIA
-- rung degrades to on paper.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local GLBridge = V.require("GLBridge")
local StereoCompose = V.require("StereoCompose")
local Perf = V.require("Perf")

local LeiaSR = {}

local REL = "assets/leiasr/leiasr_shim.dll"

local ffi = nil
local shim = nil            -- the loaded DLL, or false once it has failed
local tried = false         -- srk_init has been attempted (success or not)
local live = false          -- ...and reported a weaver
local strikes = 0           -- consecutive weave failures; two and it is over
local lensOn = false        -- what we last asked the switchable lens to do
local status = "not started"
local wide = nil            -- the 2W x H side-by-side the weaver reads
local wideW, wideH = 0, 0
-- the caller's own parameters plus the flip, in a table that is refilled
-- rather than rebuilt: `p` belongs to the caller and the flat compose above
-- must not come out upside down with it
local wideParams = { mode = 0, swap = false, parity = false, flip = true }

local CDEF = [[
int  srk_init(void *hwnd);
void srk_weave(unsigned int tex, int width, int height);
int  srk_lens(int enable);
void srk_shutdown(void);
]]

-- Whether an SR panel could exist here at all. The shim is a Win32 DLL and
-- the weaver is a Windows runtime, so everywhere else the LEIA rung is not
-- hidden -- it is never built (see Stereo3D's ladder). A headless run has no
-- love.system and answers true, which costs nothing: the ladder below stops
-- at the first missing piece either way.
function LeiaSR.platformOK()
  local ok, os = pcall(function() return love.system.getOS() end)
  if not ok or not os then return true end
  return os == "Windows"
end

-- ------- finding the shim
--
-- Two paths, and the second is the interesting one. `mod.path` is where the
-- mod's files are as the LOADER sees them, which is not always a directory
-- an operating system can open a DLL from -- a mod installed from a .zip may
-- be mounted inside an archive. So: try the real path first, and if that
-- fails, read the bytes out through the loader and write them once into the
-- save directory, which is always a genuine folder.

local function extract()
  local mod = V.mod
  if not (mod and mod.read) then return nil end
  local okRead, bytes = pcall(mod.read, mod, REL)
  if not (okRead and bytes and #bytes > 0) then return nil end
  local okWrite = pcall(love.filesystem.write, "leiasr_shim.dll", bytes)
  if not okWrite then return nil end
  local okDir, dir = pcall(love.filesystem.getSaveDirectory)
  if not (okDir and dir) then return nil end
  return dir .. "/leiasr_shim.dll"
end

local function loadShim()
  if shim ~= nil then return shim or nil end
  shim = false
  if not LeiaSR.platformOK() then
    status = "not a Windows machine"
    return nil
  end
  local okFFI = pcall(function()
    ffi = require("ffi")
    pcall(ffi.cdef, CDEF)
  end)
  if not okFFI then
    status = "no FFI in this Lua"
    return nil
  end

  local paths = {}
  if V.mod and V.mod.path then paths[#paths + 1] = V.mod.path .. "/" .. REL end
  for _, p in ipairs(paths) do
    local ok, lib = pcall(ffi.load, p)
    if ok and lib then shim = lib return shim end
  end
  local unpacked = extract()
  if unpacked then
    local ok, lib = pcall(ffi.load, unpacked)
    if ok and lib then shim = lib return shim end
  end
  status = "leiasr_shim.dll not found -- side by side instead"
  return nil
end

-- ------- bringing the weaver up
--
-- Deferred to the first weave rather than done when the row is switched on.
-- Some builds of the SR service briefly re-parent and resize the host window
-- while the context comes up, and doing that behind a title screen is a
-- black flash and a minimise-restore cycle for no reason. By the first weave
-- there is already a 3D picture on screen to be interrupted, which is a much
-- better moment to interrupt.

local function bringUp()
  if tried then return live end
  tried = true
  local lib = loadShim()
  if not lib then return false end
  if not GLBridge.load() then
    status = "no GL interop: " .. GLBridge.status()
    return false
  end
  local hwnd = GLBridge.hwnd()
  if hwnd == nil then
    status = "could not find the game window"
    return false
  end
  local ok, rc = pcall(function() return lib.srk_init(hwnd) end)
  if not ok or rc == 0 then
    status = "no SR runtime or no SR display -- side by side instead"
    return false
  end
  live = true
  status = LeiaSR.dpiWarning() or "weaving"
  return true
end

-- ------- the switchable lens
--
-- Some SR panels put the lenticular layer on a switch: lens down and it is an
-- autostereoscopic display, lens up and it is an ordinary sharp 2D monitor.
-- The hint is a PREFERENCE and the SR service arbitrates it across every
-- application that has an opinion, so this is asking rather than setting, and
-- the honest answer to "did it work" is often "somebody else still wants it
-- on".
--
-- Worth wiring even so, because the failure it prevents is one the player
-- cannot diagnose: leave the lens down after the 3D row is switched off, or
-- after the game exits, and the whole desktop is soft and faintly doubled
-- with nothing on screen to connect it to.
--
-- Guarded twice over. The shim may predate the export (an older
-- leiasr_shim.dll beside a newer mod), in which case indexing the symbol is
-- itself the error, and the SDK answers E_NOINTERFACE on a panel whose lens
-- does not move -- which is not a failure, just a panel with one lens state.
function LeiaSR.lens(on)
  on = on and true or false
  if not (shim and live) then
    lensOn = false
    return false
  end
  if on == lensOn then return true end
  local ok, rc = pcall(function() return shim.srk_lens(on and 1 or 0) end)
  if not ok then return false end
  lensOn = on
  return rc ~= 0
end

-- The DPI trap, which nothing on this side can fix and must therefore say
-- out loud.
--
-- The weave reads as 3D only when its output lands one shader pixel on one
-- physical panel pixel. On a display scaled past 100% by a process that is
-- not per-monitor DPI aware, Windows renders the window small and stretches
-- it afterwards -- after every shader in the frame -- and the lenticular
-- pattern no longer lines up with the lenses. It does not look broken. It
-- looks soft, and slightly double, and like the panel is faulty.
--
-- Not fixable from inside the process, and it is worth being exact about
-- why: DPI awareness is declared ONCE, first declaration wins, and SDL
-- makes that declaration while LOVE starts up -- long before a mod exists,
-- let alone this file. A shim loaded later cannot reach it either; that was
-- tried, and setting the awareness of the SR thread alone does not help,
-- because what is being stretched is the whole window.
--
-- What DOES fix it is outside the process entirely: mark the executable
-- itself per-monitor DPI aware, which the message below says how to do.
function LeiaSR.dpiWarning()
  local aware = GLBridge.dpiAwareness()
  local okScale, scale = pcall(love.window.getDPIScale)
  if not okScale or not scale then return nil end
  if aware == nil or aware >= 2 or math.abs(scale - 1) < 0.01 then return nil end
  return ("display scaling is %d%% and this process is not per-monitor DPI "
       .. "aware, so Windows will stretch the finished frame and the weave "
       .. "will land soft. Fix it on the EXECUTABLE rather than in here: "
       .. "right-click the game's .exe, Properties, Compatibility, Change "
       .. "high DPI settings, and tick Override high DPI scaling behaviour, "
       .. "scaling performed by Application.")
       :format(math.floor(scale * 100 + 0.5))
end

function LeiaSR.ready()
  return live and shim and true or false
end

function LeiaSR.status()
  return status
end

function LeiaSR.disable(why)
  -- lens first: once `live` is false there is nothing left to ask with
  LeiaSR.lens(false)
  live = false
  status = why or "the weaver stopped -- side by side instead"
end

-- ------- the two composes
--
-- One at the window's own size, which is what gets presented and what stays
-- on screen if anything below goes wrong; one at twice the width, UPSIDE
-- DOWN, which is what the weaver reads. They are the same picture at two
-- scales, and the second exists for two reasons.
--
-- THE WIDTH is so the weaver never has to magnify an eye. It samples
-- uv.x in [0, 0.5] for the left and [0.5, 1] for the right, so a
-- panel-width side-by-side gives it a half-width eye to stretch before it
-- can interleave; twice the width means it samples 1:1 and the interleave
-- is the only resampling in the chain.
--
-- THE FLIP is a convention mismatch, and it is the one thing in this file
-- that is guaranteed to be wrong if it is left out. LOVE stores a canvas
-- with row zero at the TOP; GL reads a texture with v = 0 at the BOTTOM.
-- Every consumer inside LOVE shares LOVE's convention so the question never
-- arises -- and the weaver is not inside LOVE. Handed a LOVE canvas as it
-- stands, it reads our top row as its bottom one and the woven output comes
-- out vertically mirrored.
--
-- Flipping the INPUT rather than the output, and this matters: the weave's
-- lenticular pattern is a function of the OUTPUT pixel and the window's
-- position on the panel. Flip what it writes and the pattern goes with it,
-- one row out of phase with the lenses, and the 3D does not come back
-- upside down -- it stops existing. Flip what it reads and the pattern
-- stays exactly where the panel wants it.
--
-- Returns the screen-sized one, or nil to let the caller compose it the
-- ordinary way.
function LeiaSR.prepare(left, right, w, h, p)
  local flat = StereoCompose.apply(left, right, w, h, p, "leiaflat")
  if not flat then return nil end

  wide, wideW, wideH = nil, 0, 0
  -- Half a 4K panel's worth of extra width is past the texture limit on
  -- plenty of hardware and every phone. A refused canvas is not a broken
  -- weave, it is simply no weave: the screen keeps the side-by-side image
  -- and says so.
  local limit = nil
  if love.graphics and love.graphics.getSystemLimits then
    local okL, limits = pcall(love.graphics.getSystemLimits)
    limit = okL and limits and limits.texturesize or nil
  end
  if limit and limit > 0 and 2 * w > limit then
    if live then status = "the panel is too wide for a full-width weave" end
    return flat
  end

  -- the same parameters as the on-screen one, and the flip on top of them --
  -- copied rather than mutated, because `p` belongs to the caller and the
  -- flat compose above must not come out upside down with it
  wideParams.mode, wideParams.swap = p.mode, p.swap
  wideParams.parity, wideParams.flip = p.parity, true
  local packed = StereoCompose.apply(left, right, w, h, wideParams,
                                     "leiawide", 2 * w, h)
  if packed then wide, wideW, wideH = packed, 2 * w, h end
  return flat
end

-- Interleave, into the default framebuffer, over everything.
function LeiaSR.weave()
  if not wide then return end
  if strikes >= 2 then return end
  if not bringUp() then return end

  -- Here rather than in bringUp, and the difference is one the player can
  -- reach: bringUp runs ONCE and then short-circuits forever, so a lens
  -- lowered there would stay up after the first trip out to another mode and
  -- back. Asked for on every weave instead, which is an early return on all
  -- but the first frame after the rung is selected.
  LeiaSR.lens(true)

  local t0 = Perf.now()

  -- LOVE's own state first, so the binding the weaver inherits is the one
  -- LOVE also believes in and nothing has to be guessed about afterwards
  love.graphics.setCanvas()
  love.graphics.setShader()
  love.graphics.setScissor()

  -- LINEAR is not an optimisation here. The weaver magnifies whatever it is
  -- given up to the panel, and a nearest-filtered source comes out visibly
  -- blocky through the lenses.
  local hadMin, hadMag
  local okF, a, b = pcall(wide.getFilter, wide)
  if okF then hadMin, hadMag = a, b end
  pcall(wide.setFilter, wide, "linear", "linear")

  local tex = GLBridge.canvasTexture(wide)
  if not tex then
    LeiaSR.disable("the side-by-side canvas has no GL texture behind it")
    return
  end

  -- everything LOVE queued has to have actually happened before another
  -- library reads the texture it was drawing into
  GLBridge.flush()
  GLBridge.bindDefaultFramebuffer()

  -- Binding the window does NOT restore the window's viewport -- the viewport
  -- is whatever was last set, and the last thing set here was a canvas twice
  -- the width of the screen. LOVE's setCanvas() above does put it back, so
  -- this is normally writing a value that is already there; it is written
  -- anyway because the symptom of getting it wrong is the same symptom as
  -- feeding the weaver a half-width side-by-side (a picture at double width
  -- with only the left eye on screen), and two causes behind one symptom is
  -- how an afternoon disappears.
  local okDims, dw, dh = pcall(love.graphics.getPixelDimensions)
  if okDims and dw then GLBridge.viewport(dw, dh) end

  local ok = pcall(function() shim.srk_weave(tex, wideW, wideH) end)

  if hadMin then pcall(wide.setFilter, wide, hadMin, hadMag) end

  if not ok then
    strikes = strikes + 1
    if strikes >= 2 then
      LeiaSR.disable("the weaver failed twice -- side by side from here")
    end
    return
  end
  strikes = 0

  -- Put LOVE back on its feet. The weaver is a whole renderer of its own and
  -- leaves its program, its buffers and its attribute bindings behind it;
  -- LOVE caches what it thinks is bound and will happily skip re-binding
  -- something the weaver changed. A single throwaway draw off-screen makes
  -- it re-establish the lot.
  love.graphics.setBlendMode("alpha", "alphamultiply")
  love.graphics.setDepthMode()
  love.graphics.setShader()
  love.graphics.setColor(1, 1, 1, 1)
  pcall(love.graphics.rectangle, "fill", -8, -8, 1, 1)
  Perf.add("Stereo.weave", t0)
end

-- Called before the GL context goes away. The SR runtime holds GL resources
-- keyed to that context, and dropping it out from under them is a crash on
-- the NEXT launch rather than this one, which is a miserable thing to debug.
function LeiaSR.shutdown()
  if shim and live then
    LeiaSR.lens(false)
    pcall(function() shim.srk_shutdown() end)
  end
  live = false
  lensOn = false
end

function LeiaSR.invalidate()
  wide, wideW, wideH = nil, 0, 0
end

return LeiaSR
