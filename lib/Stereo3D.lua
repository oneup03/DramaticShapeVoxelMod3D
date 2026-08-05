-- Stereoscopic 3D: the conductor -- the rows that switch it on, the pair of
-- eyes it asks the scene for, and the seam it hands them back through.
--
-- ------- the shape of a 3D frame
--
-- Unlike the headset path this replaced, nothing here owns a clock. Every
-- pixel happens on the engine's own frame, which is most of the reason this
-- file is a third the size of the one before it:
--
--   drawWorld     the scene, twice, into two cached canvases -- one shadow
--                 map, one pose capture, one glint, two viewpoints. The
--                 LEFT one is handed back, so the engine composites its own
--                 2D UI over it exactly as it always has.
--   worldPresent  nothing, normally. In MODE B (below) the compose happens
--                 here instead.
--   present       the finished picture arrives -- world AND UI. The left
--                 eye IS that picture, pixel for pixel. The right one is
--                 rebuilt from it, and the two are packed for the display.
--   endFrame      everything the three stages above never see, and the
--                 weave. See below; it is more than it sounds.
--
-- Those first three are RENDER PIPELINE stages, and a pipeline stage only
-- runs on a frame where a pipeline drew the world. Plenty of frames do not:
-- the title screen, the main menu, the mod manager, a save being loaded, the
-- flat 2D overworld with the diorama off -- and a STAGED BATTLE, which
-- reaches the screen through the engine's world-override rather than through
-- a world pass at all.
--
-- So endFrame is the general case and the three stages are the fast path for
-- the frames that have one. It reads the finished picture back off the back
-- buffer and lays it out, using whatever pair was left here for this frame
-- (Stereo3D.hold) as the second eye, or the picture itself where there is
-- none -- which is zero disparity, and so the screen plane, and so exactly
-- where a menu belongs.
--
-- A battle is the interesting case: BattleScene renders its arena twice, the
-- mons are geometry inside it, and the pair arrives here through hold() from
-- the update tick. So a fight comes out in real depth with its text box and
-- its HUDs on the glass in front of it.
--
-- ------- the UI, and the two modes
--
-- The engine draws its dialogs, menus and battle screen AFTER this mod's
-- world canvas and never shows them to it. That is fine for the left eye,
-- which is the frame the engine composited. It is not fine for the right,
-- which has a world and no words on it.
--
-- MODE A lifts the UI back out. The finished frame is compared against a
-- private copy of the left eye taken before the engine touched it; wherever
-- the two differ, something was drawn there, and that something is
-- composited onto the right eye as well. The left eye stays exact -- it is
-- the frame -- and the right gains the UI at zero parallax, on the screen
-- plane, which is where a dialog box belongs.
--
-- MODE B is what happens when that is not available: when the engine offers
-- no present stage at all, or when the lift finds the whole frame changed
-- (something post-processed the world between the two stages, and the mask
-- is meaningless). The compose moves up into worldPresent and the engine's
-- own UI lands on top of the packed image. For ROW, COL, CHECK, ANAGL and
-- LEIA that is EXACTLY RIGHT and costs nothing: those modes pack into one
-- full-resolution picture, so a pixel drawn once is a pixel both eyes see,
-- which is the definition of the screen plane. Only SBS and T/B suffer,
-- because there a full-width dialog straddles two half-width eyes. The
-- status line says so.
--
-- Which mode is in force is DISCOVERED, never assumed: the engine's source
-- is not in this repository and the registry may or may not have a present
-- stage to give. See the watchdog and the coverage probe below.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local FirstPerson = V.require("FirstPerson")
local StereoRig = V.require("StereoRig")
local StereoCompose = V.require("StereoCompose")
local LeiaSR = V.require("LeiaSR")
local GLBridge = V.require("GLBridge")
local PixelCanvas = V.require("PixelCanvas")
local Perf = V.require("Perf")

local Stereo3D = {}

-- ------- the rows

-- The ladder, in the order a player steps through it. LEIA is appended
-- rather than declared, because a rung for hardware that cannot exist on
-- this platform is worse than no rung: it is a rung that always fails.
local MODES = { "off", "sbs", "tab", "row", "col", "checker", "anaglyph" }
local LABELS = { "OFF", "SBS", "T/B", "ROW", "COL", "CHECK", "ANAGL" }
if LeiaSR.platformOK() then
  MODES[#MODES + 1], LABELS[#LABELS + 1] = "leiasr", "LEIA"
end

-- What StereoCompose's shader calls each of them. LeiaSR composes as
-- side-by-side and then hands that to the weaver, so it shares SBS's branch
-- and is not a mode of the shader at all.
local COMPOSE_MODE = {
  sbs = 0, tab = 1, row = 2, col = 3, checker = 4, anaglyph = 5, leiasr = 0,
}

Stereo3D.mode = ModSetting.new("stereo", "3D", MODES, LABELS)

-- How much of the depth budget to spend. 100% puts the far horizon
-- StereoRig.K/2 -- two and a half per cent -- of the screen width apart,
-- which is a conservative seated figure; the rungs above it are for people
-- who know what their own eyes will take, and the ones below for a small
-- window or a long day.
Stereo3D.depth = ModSetting.new("stereodepth", "3D DEPTH",
                                { 0.5, 0.75, 1, 1.5, 2, 3 },
                                { "50%", "75%", "100%", "150%", "200%", "300%" },
                                1)

-- Where the screen plane sits, as a multiple of whatever the camera is
-- actually looking at. Everything nearer than it comes out of the screen
-- and everything beyond goes into it, so NEAR pushes the whole diorama out
-- at you and FAR sinks it into the desk.
Stereo3D.focus = ModSetting.new("stereofocus", "3D FOCUS",
                                { 0.5, 0.75, 1, 1.5, 2 },
                                { "NEAR", "NEARISH", "MID", "FARISH", "FAR" },
                                1)

-- Swap the eyes. A row rather than a constant because no software can ask
-- a passive filter which way its polarisation runs, a shutter driver what
-- phase it is on, or a lenticular panel which column it starts with -- and
-- getting it wrong still looks like 3D, just inside-out. See the sign note
-- at the end of StereoRig.
Stereo3D.swap = ModSetting.new("stereoswap", "3D SWAP",
                               { false, true }, { "OFF", "ON" })

-- Manager-page only, all three: things that should not be decided on a
-- menu, but that a bug in them should not need a rebuild to isolate.

-- Give the orbit rungs a real skybox while 3D is on. The classic look
-- hangs the sky off the FRAME, which makes it identical in both eyes --
-- i.e. pinned to the screen -- with ground receding BEHIND it. The eye
-- notices, at the horizon, and cannot fuse it.
Stereo3D.sky = ModSetting.new("stereosky", "3D SKY",
                              { false, true }, { "OFF", "ON" }, true)

-- The interlace PHASE: whether display row (or column) zero wants the left
-- eye or the right. A third convention again, and distinguishable from the
-- other two by its symptom -- depth that is inverted is the eyes, depth
-- that is simply absent under a shimmer is this.
Stereo3D.parity = ModSetting.new("stereoparity", "3D PARITY",
                                 { false, true }, { "OFF", "ON" })

-- ------- state

local held = nil          -- this frame's eyes: { L, R, refL, w, h }
local refCanvas = nil     -- the private pre-UI copy of the left eye
local packed = false      -- this frame has already been laid out for the
                          -- display, and must not be laid out twice
local fresh = false       -- ...and the held pair belongs to this frame
local shotCanvas = nil    -- the finished frame, for the screens with no world
local shotFBO = nil
local saidNoCapture = false
local invConv = nil       -- the eased convergence, in reciprocal space
local cutPending = true   -- snap the ease rather than run it
local depthFade = 1       -- 1 in depth, 0 flat; see the fade below
local fadeHold = 0        -- seconds still to hold at flat
local lastLevel = nil
local lastStaged = nil
local status = "off"

-- Mode A until proven otherwise, and the two ways it is disproved.
local presentStage = true     -- the registry accepted a present stage
local sawPresent = false      -- and it has actually fired
local engagedFrames = 0
local WATCHDOG_FRAMES = 10

-- ------- how much of the frame the interface lift is being handed
--
-- One number, measured every frame off the previous frame's mask (see
-- StereoCompose.watch, which is why it is nearly free), and it answers two
-- quite different questions depending on how long it stays high.
--
-- HIGH FOR A FEW FRAMES is a full-screen effect: the flash that announces
-- an encounter, a whiteout, a wipe. There is no interface to lift out of a
-- frame like that -- the whole picture changed -- so it comes out flat. One
-- flat frame would not matter; a run of them ALTERNATING with the frames
-- either side is a picture that snaps in and out of depth several times a
-- second, and the eyes re-converge on every switch. So the depth is faded
-- out from under it and eased back when it stops.
--
-- This is measured rather than predicted on purpose. The first attempt
-- hung the fade off the events the mod already knew about -- a rung change,
-- a battle starting -- and the flash that actually causes it happens BEFORE
-- any of them, out in the overworld, from engine code this mod never sees.
-- Whatever covers the screen, and whoever draws it, this notices.
--
-- HIGH FOREVER means something is post-processing the world between the
-- world pass and the finished frame, and the mask is meaningless rather
-- than eventful: there is no interface in it to find. That is Mode B, and
-- it is latched only after the reading has stayed high for SECONDS, which
-- no flash does. (An earlier cut sampled five times in the first five
-- seconds and latched on any one of them -- so an encounter in the first
-- few seconds of play could turn the interface lift off for the session.)
local COVERAGE_LIMIT = 0.6
local FLASH_LIMIT = 0.75
local MODE_B_SECONDS = 2.5
local highFor = 0
local lastCoverage = nil

local eyes = nil          -- the record list handed to VoxelScene.render
local eyeCtx, eyeScale = nil, nil   -- this frame's, for the hooks below

-- ------- gates

-- Whether the platform can pack a stereo frame at all. Everything here is
-- one fullscreen shader over two canvases, so the answer is simply whether
-- there is a GPU to run it on -- unlike the headset path this replaced,
-- there is nothing Windows-only about the picture itself. Only the LEIA
-- rung is, and that gates itself.
function Stereo3D.supported()
  return Voxel3D.available()
end

function Stereo3D.enabled()
  return Stereo3D.mode:get() ~= "off"
end

-- Switched on AND with a diorama to be switched on over. With voxel mode
-- off the engine draws the flat 2D world and there is nothing to have a
-- second viewpoint of.
function Stereo3D.engaged()
  return Stereo3D.enabled() and Voxel.active() and Voxel3D.available()
end

-- Whether this frame's compose owns the tilt-shift blur. It has to: the
-- engine's worldPresent runs on the canvas drawWorld returned, which is one
-- eye of two, and a pair blurred on one side will not fuse. See TiltShift.
function Stereo3D.ownsBlur()
  return Stereo3D.engaged()
end

function Stereo3D.status()
  return status
end

-- How much depth is in force right now, 0 to 1: the fade above, which is 1
-- for all but the half-second either side of a cut.
function Stereo3D.fade()
  return depthFade
end

-- ------- cuts, and why the depth FADES through one
--
-- A CUT is a change of shot rather than a move: the rung ladder stepping,
-- a fight opening or closing, a warp. Two things happen at one.
--
-- The screen plane SNAPS, because easing it would be a slow swell of depth
-- after a hard change of picture (see StereoRig.ease).
--
-- And the depth itself FADES OUT AND BACK, which is about comfort rather
-- than correctness. The engine announces a battle with a run of full-screen
-- flashes, and a flash is a frame this mod cannot give depth to: it covers
-- the world, so the interface lift finds the WHOLE picture changed and has
-- nothing to lift -- the frame comes out flat. On its own that would be
-- fine. What it does instead is ALTERNATE with the unflashed frames either
-- side of it, and a picture that snaps between depth and no depth several
-- times a second is genuinely unpleasant to look at: the eyes re-converge
-- on every switch.
--
-- So the depth is taken out from under it. It eases to nothing faster than
-- the eye follows, sits there for the length of the flash, and eases back --
-- one dissolve instead of ten snaps. Below the floor the second eye is not
-- rendered at all, so the flash costs one scene pass rather than two.
Stereo3D.FADE_OUT = 0.07      -- seconds down; quick, but not a snap of its own
Stereo3D.FADE_IN = 0.35       -- and slow enough back that it is not noticed
Stereo3D.FADE_HOLD = 0.30     -- flat for at least this long once one lands

-- The fade bottoms out HERE rather than at nothing, and the three per cent
-- is load-bearing. At three per cent of the budget the disparity is a
-- fraction of a pixel -- flat, to look at. But the pair still EXISTS, and
-- the pair is what the flash detector measures against: fade the second eye
-- out of existence and the mod goes blind to the very thing it faded for,
-- the hold expires, the depth comes back into the middle of the flash, and
-- the strobe is back at the length of the hold instead of the frame.
Stereo3D.FADE_MIN = 0.03

function Stereo3D.cut()
  cutPending = true
  fadeHold = math.max(fadeHold, Stereo3D.FADE_HOLD)
end

-- ------- the tick

local function staged()
  local ok, stage = pcall(function()
    return V.require("OverworldBattle").stage()
  end)
  return ok and stage ~= nil
end

function Stereo3D.update(dt)
  if not Stereo3D.enabled() then
    status = "off"
    cutPending = true
    return
  end

  -- the two boundaries that are cuts and announce themselves to nobody
  local level = Voxel.level
  local nowStaged = staged()
  if level ~= lastLevel or nowStaged ~= lastStaged then Stereo3D.cut() end
  lastLevel, lastStaged = level, nowStaged

  -- the fade, on the frame's own clock rather than on a frame count, so it
  -- lasts the same fraction of a second whatever the machine is managing
  dt = tonumber(dt) or 0
  if fadeHold > 0 then
    fadeHold = fadeHold - dt
    depthFade = math.max(Stereo3D.FADE_MIN,
                         depthFade - dt / math.max(1e-3, Stereo3D.FADE_OUT))
  else
    depthFade = math.min(1, depthFade + dt / math.max(1e-3, Stereo3D.FADE_IN))
  end

  if not Stereo3D.engaged() then
    status = "waiting for the diorama"
    return
  end

  engagedFrames = engagedFrames + 1
  if presentStage and not sawPresent and engagedFrames > WATCHDOG_FRAMES then
    Stereo3D.noPresentStage("the present stage never fired")
  end

  if Stereo3D.mode:get() == "leiasr" then
    status = LeiaSR.status()
  elseif presentStage then
    status = "on"
  else
    status = "on (UI on the screen plane)"
  end
end

-- Mode B, latched for the session, with the reason on the console once.
function Stereo3D.noPresentStage(why)
  if not presentStage then return end
  presentStage = false
  print("[DRAMATIC_SHAPE] 3D: composing before the UI -- " .. tostring(why)
        .. ". SBS and T/B will show the interface across both halves; every "
        .. "other mode is unaffected.")
end

function Stereo3D.sawPresentStage()
  sawPresent = true
end

-- ------- the eyes

-- Two eye cameras from one camera DESCRIPTION (Voxel3D.monoCamera), with
-- this frame's rows and this frame's eased screen plane applied.
--
-- The one place a pair is made, because there are two callers and they must
-- not disagree about the depth budget: the free-roam pass below, and the
-- staged battle's own placed rig (BattleScene.render). A battle is a cut
-- away from the world and back again, and the easing state that makes those
-- two cuts land properly is per-frame and single -- it lives here rather
-- than in either caller.
--
-- nil where there is no pair to be had: a camera that brought raw matrices
-- and cannot be decomposed, or one with no basis to slide along. Both
-- callers read that as "render mono this frame".
function Stereo3D.eyesFor(mono, vw, vh)
  if not mono then return nil end
  local depthMul = (tonumber(Stereo3D.depth:get()) or 1) * depthFade
  local focusMul = tonumber(Stereo3D.focus:get()) or 1

  -- the budget answers with the convergence this frame WANTS; what it gets
  -- is that eased (see StereoRig.ease), and the separation is then re-solved
  -- against the eased value so the depth budget stays exact at whatever the
  -- screen plane actually is right now
  local _, want = StereoRig.budget(mono, vw, vh, depthMul, focusMul)
  invConv = StereoRig.ease(invConv, want, cutPending)
  cutPending = false
  local conv = StereoRig.eased(invConv) or want
  local sep = StereoRig.K * depthMul * StereoRig.tanX(mono, vw, vh) * conv

  return StereoRig.pair(mono, sep, conv, vw, vh,
                        Stereo3D.sky:get() ~= false)
end

-- The set FirstPerson is told to accept, refilled rather than rebuilt.
local accepted = {}

-- The projector the overworld's own FX closures are handed. A named local
-- rather than a closure made at the call site: it reads Voxel3D.vp, which is
-- whichever eye is drawing, so one of these serves both.
local function projectFx(wx, wy)
  return Voxel3D.project(wx, 0, wy)
end

local function buildEyes(cx, cy, vw, vh)
  local L, R = Stereo3D.eyesFor(Voxel3D.monoCamera(cx, cy, vw, vh), vw, vh)
  if not L then return false end
  eyes[1].camera, eyes[2].camera = L, R
  -- the eyes are this rig, slid apart: everything keyed to "the first-person
  -- rig is drawing" has to keep answering for them, and the rig itself has
  -- to stay the MONO camera so both eyes agree about which sprite frame a
  -- character is showing
  accepted[L], accepted[R] = true, true
  FirstPerson.acceptCameras(accepted)
  return true
end

local function overlayEyes(w, h)
  -- world-anchored FX go through this eye's own projection and so land at
  -- their own depth in it; the horde's readout is screen-space and is drawn
  -- identically into both, which puts it on the screen plane. One hook, two
  -- correct answers.
  if eyeCtx and eyeCtx.drawFx then eyeCtx.drawFx(projectFx, eyeScale) end
  V.require("HordeHud").drawFlat(w, h, eyeScale)
end

-- The record list VoxelScene.render draws through.
--
-- Made ONCE and refilled -- the list, its two eye records, the accept set
-- and both hooks. An earlier cut built the two hooks here, closing over this
-- frame's context, which is two closures and an accept table a frame for no
-- reason: the frame-varying part is two upvalues, and upvalues can be
-- assigned. `ctx` is the pipeline context drawWorld was handed; `scale` is
-- the overlay scale it would have used flat.
function Stereo3D.eyeList(rw, rh, ctx, scale)
  eyes = eyes or {
    { slot = "stereoL" },
    { slot = "stereoR" },
    deriveFlat = true,
    build = buildEyes,
    overlay = overlayEyes,
  }
  eyes[1].w, eyes[1].h = rw, rh
  eyes[2].w, eyes[2].h = rw, rh
  eyeCtx, eyeScale = ctx, scale
  return eyes
end

-- Put the camera back the way the flat path expects to find it. The rig
-- borrowed it for two passes and every later reader -- the orbit, the
-- battle, the next frame -- must not find an eye there.
function Stereo3D.release()
  Voxel3D.camera = nil
  Voxel3D.eyeCenter = nil
  FirstPerson.acceptCameras(nil)
  -- the two eye records are rebuilt every frame and the old ones must not
  -- be kept alive by the set that admitted them
  for k in pairs(accepted) do accepted[k] = nil end
end

-- ------- holding the pair between stages
--
-- drawWorld finishes long before present runs, and what it produced has to
-- survive the gap. The eye canvases do that by themselves (they are the
-- scene's own cached slots), but the LEFT one does not: it is the canvas
-- handed back to the engine, and an engine that composites its UI straight
-- into it would leave the lift with nothing to compare against. So the left
-- eye is COPIED, once, into a canvas nothing else can reach.

local function refFor(w, h)
  if refCanvas then
    local ok, cw, ch = pcall(refCanvas.getDimensions, refCanvas)
    if ok and cw == w and ch == h then return refCanvas end
    if refCanvas.release then pcall(refCanvas.release, refCanvas) end
    refCanvas = nil
  end
  -- PixelCanvas.new IS the pcall, so it answers (ok, canvas)
  local ok, c = PixelCanvas.new(w, h)
  if not (ok and c) then return nil end
  refCanvas = c
  pcall(refCanvas.setFilter, refCanvas, "nearest", "nearest")
  return refCanvas
end

function Stereo3D.hold(L, R, w, h)
  -- No pair is a STATEMENT, not an omission: a frame that could not be
  -- split must not leave last frame's eyes lying about for present() to
  -- pack with a picture they have nothing to do with.
  if not (L and R) then held = nil return end
  held = held or {}
  held.L, held.R, held.w, held.h = L, R, w, h
  held.refL = StereoCompose.copy(L, refFor(w, h))
  -- Good for THIS frame and no other. The pair is put here by whichever
  -- pass drew it -- the free-roam world pass, or the staged battle's own
  -- update -- and on a frame where neither ran (a wipe between the two, a
  -- screen that pushed over both) the last one must not be packed against a
  -- picture it has nothing to do with. Spent at the end of the frame.
  fresh = true
end

-- The pair, if one was drawn for THIS frame.
local function livePair()
  if not (fresh and held and held.R and held.refL) then return nil end
  return held
end

function Stereo3D.pair()
  if not held then return nil end
  return held.L, held.R
end

function Stereo3D.invalidate()
  if refCanvas and refCanvas.release then pcall(refCanvas.release, refCanvas) end
  refCanvas = nil
  if shotCanvas and shotCanvas.release then
    pcall(shotCanvas.release, shotCanvas)
  end
  shotCanvas, shotFBO = nil, nil
  held = nil
  packed, fresh = false, false
  invConv = nil
  cutPending = true
  depthFade, fadeHold = 1, 0
  highFor, lastCoverage = 0, nil
  StereoCompose.invalidate()
  LeiaSR.invalidate()
end

-- ------- the compose

-- Refilled rather than rebuilt. Three booleans a frame is not much garbage
-- on its own; the point is that nothing in the per-frame path should be
-- making any, because what the collector costs is not the bytes but the
-- pause, and a pause is exactly the artefact this whole file is about.
local params = { mode = 0, swap = false, parity = false, flip = false }

local function packParams()
  params.mode = COMPOSE_MODE[Stereo3D.mode:get()] or 0
  params.swap = Stereo3D.swap:get() == true
  params.parity = Stereo3D.parity:get() == true
  params.flip = false
  return params
end

-- ------- reading the finished frame back, and putting one there
--
-- The pair of operations the screens with no world in them are built out of.
-- Both go below LOVE, because LOVE has no way to hand over the back buffer
-- it is about to swap: captureScreenshot answers NEXT frame, which is a
-- frame too late to do anything about this one.
--
-- Windows only, like everything in GLBridge. Elsewhere the capture simply
-- fails, endFrame does nothing, and the menus stay flat while the world
-- stays in 3D -- which is a worse answer than the one above and a much
-- better one than a crash.

function Stereo3D.capture()
  if not GLBridge.load() then return nil end
  local w, h = love.graphics.getPixelDimensions()
  if not (w and h and w > 0 and h > 0) then return nil end

  if not (shotCanvas and shotCanvas:getWidth() == w
          and shotCanvas:getHeight() == h) then
    if shotCanvas and shotCanvas.release then
      pcall(shotCanvas.release, shotCanvas)
    end
    shotCanvas, shotFBO = nil, nil
    local ok, c = PixelCanvas.new(w, h)
    if not (ok and c) then return nil end
    pcall(c.setFilter, c, "nearest", "nearest")
    shotCanvas = c
    -- discovered once and kept: the id is stable for the canvas's lifetime,
    -- and discovering it costs a bind through LOVE
    shotFBO = GLBridge.canvasFBO(shotCanvas)
    if not shotFBO then shotCanvas = nil return nil end
  end

  -- everything LOVE has queued has to have actually reached the back buffer
  -- before it is read: setCanvas flushes the batch, and the flush makes sure
  -- the driver has run it
  local t0 = Perf.now()
  love.graphics.setCanvas()
  GLBridge.flush()
  local ok = GLBridge.captureBackbuffer(shotFBO, w, h)
  Perf.add("Stereo.capture", t0)
  if not ok then return nil end
  return shotCanvas, w, h
end

-- Put `canvas` on the screen, one of its pixels to one display pixel.
--
-- The DPI scale is the whole of the arithmetic and it is easy to get wrong
-- in both directions: the canvas is in PIXELS (PixelCanvas asks for
-- dpiscale 1) and love.graphics.draw measures in UNITS, so covering the
-- window means dividing by the scale exactly once. See the note on
-- sceneSize in main.lua, which is the same trap from the other side.
function Stereo3D.blitToScreen(canvas, w, h)
  if not canvas then return false end
  local t0 = Perf.now()
  local prevBlend, prevAlpha = love.graphics.getBlendMode()
  local okScale, dpi = pcall(love.graphics.getDPIScale)
  if not okScale or not dpi or dpi <= 0 then dpi = 1 end
  love.graphics.setCanvas()
  love.graphics.setShader()
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("replace", "premultiplied")
  local ok = pcall(function()
    love.graphics.push()
    love.graphics.origin()
    love.graphics.draw(canvas, 0, 0, 0, 1 / dpi, 1 / dpi)
    love.graphics.pop()
  end)
  love.graphics.setBlendMode(prevBlend or "alpha", prevAlpha)
  Perf.add("Stereo.blitToScreen", t0)
  return ok
end

-- Measure the mask, and react to what it says. Called from whichever stage
-- is doing the lift this frame; returns nothing, because both answers are
-- states rather than values.
local function watchFrame(frame, refL, w, h)
  local cov = StereoCompose.watch(frame, refL, w, h)
  if not cov then return end
  lastCoverage = cov
  if cov > FLASH_LIMIT then
    -- a full-screen effect: take the depth out from under it, and keep
    -- taking it for as long as the effect lasts
    fadeHold = math.max(fadeHold, Stereo3D.FADE_HOLD)
  end
  if cov > COVERAGE_LIMIT then
    highFor = highFor + 1
    if highFor > MODE_B_SECONDS * 60 then
      Stereo3D.noPresentStage(("the whole frame has been changing after the "
        .. "world pass for %d seconds (%d%% of it), so there is no interface "
        .. "to lift out"):format(MODE_B_SECONDS, math.floor(cov * 100 + 0.5)))
    end
  else
    highFor = 0
  end
end

-- What the last measurement said, 0 to 1, or nil before there has been one.
function Stereo3D.coverage()
  return lastCoverage
end

-- Lay a left and a right out for the display. `left == right` is a perfectly
-- good call and means zero disparity, which is the screen plane -- see
-- Stereo3D.endFrame, where most of them come from.
local function layOut(left, right, w, h)
  local p = packParams()
  local out
  if Stereo3D.mode:get() == "leiasr" then
    out = LeiaSR.prepare(left, right, w, h, p)
  end
  out = out or StereoCompose.apply(left, right, w, h, p)
  if out then packed = true end
  return out
end

-- MODE B: the world, packed, before the UI ever lands on it.
function Stereo3D.worldPresent(canvas)
  if presentStage or not Stereo3D.engaged() then return canvas end
  if not (held and held.R) then return canvas end
  return layOut(held.refL or canvas, held.R, held.w, held.h) or canvas
end

-- MODE A: the finished frame, with the UI lifted onto the second eye.
--
-- Or, where this frame had no world in it at all, the finished frame laid
-- out as BOTH eyes -- which is what a menu, a dialog, a battle screen or a
-- transition wipe gets, and is the right answer for all of them: identical
-- pixels in both eyes is zero disparity, which is the screen plane.
function Stereo3D.present(frame)
  -- ahead of every other test: a stage that fires is the fact this is
  -- watching for, whatever it fires WITH
  Stereo3D.sawPresentStage()
  if not frame or not Stereo3D.enabled() then return frame end
  -- MODE B already laid this frame out, one stage earlier, and the engine
  -- has drawn its UI over the result. Packing a packed picture would fold
  -- two eyes into one half of two eyes.
  if packed then return frame end
  if type(frame.getDimensions) ~= "function" then
    Stereo3D.noPresentStage("the present stage handed over something that is "
                            .. "not a canvas")
    return frame
  end
  local okDim, fw, fh = pcall(frame.getDimensions, frame)
  if not okDim then return frame end

  -- No pair: there is nothing to give this frame depth WITH, so give it the
  -- format instead. A side-by-side display is de-interleaving the whole
  -- window whatever is on it, and a menu drawn full width across both halves
  -- is not a menu.
  if not (presentStage and Stereo3D.engaged() and livePair()) then
    return layOut(frame, frame, fw, fh) or frame
  end

  if fw ~= held.w or fh ~= held.h then
    Stereo3D.noPresentStage("the present stage handed over something the "
                            .. "wrong size")
    return frame
  end

  watchFrame(frame, held.refL, held.w, held.h)

  local right = StereoCompose.lift(frame, held.refL, held.R, held.w, held.h)
  if not right then return layOut(frame, frame, fw, fh) or frame end
  return layOut(frame, right, held.w, held.h) or frame
end

-- ------- the last word on the frame
--
-- Two jobs, both of which have to happen after EVERY other pass in the frame
-- and so cannot live on a render pipeline's stages at all -- those only run
-- when a pipeline drew the world.
--
-- THE FRAMES NO PIPELINE STAGE SEES, which is more of them than it sounds.
-- The title screen, the main menu, the mod manager, a save being loaded, the
-- flat 2D overworld with the diorama off -- and, importantly, a STAGED
-- BATTLE, which draws its world through the engine's world-override rather
-- than through a pipeline's world pass. None of them reaches worldPresent or
-- present, and on a side-by-side display each one would be a full-width
-- picture across two half-width eyes. So the finished frame is read back off
-- the back buffer and laid out here.
--
-- With WHAT as the second eye depends on whether anything left a pair
-- behind. Nothing did, on a menu: the picture is laid out as both eyes,
-- which is zero disparity and so the screen plane, which is exactly where a
-- menu belongs. A battle DID (BattleScene renders its arena twice and
-- Stereo3D.hold takes the pair), so the interface is lifted out of the
-- finished frame onto that second eye exactly as present() would have done
-- it -- and the fight comes out in depth with its text box on the glass.
--
-- Which also makes this the whole of the fallback if the engine turns out to
-- have no present stage at all: a held pair still gets its UI lifted, one
-- stage later and off the back buffer instead of a canvas.
--
-- THE SR WEAVE, which has to be the very last thing written to the back
-- buffer and has to be written to the back buffer itself.
--
-- Both are skipped when the frame was already laid out upstream, which is
-- what `packed` is for: laying a packed frame out a second time would pack
-- an already-packed picture into half of itself.
function Stereo3D.endFrame()
  if not Stereo3D.enabled() then
    packed = false
    LeiaSR.lens(false)
    return
  end

  if not packed then
    local shot, w, h = Stereo3D.capture()
    if shot then
      local right = shot
      local pair = livePair()
      if pair and pair.w == w and pair.h == h then
        watchFrame(shot, pair.refL, w, h)
        right = StereoCompose.lift(shot, pair.refL, pair.R, w, h) or shot
      end
      local out = layOut(shot, right, w, h)
      if out then Stereo3D.blitToScreen(out, w, h) end
    elseif not saidNoCapture then
      saidNoCapture = true
      print("[DRAMATIC_SHAPE] 3D: cannot read the finished frame back on this "
            .. "platform (" .. GLBridge.status() .. "), so menus, dialogs, "
            .. "battles and the 2D screens stay full width while the "
            .. "free-roam world is in 3D.")
    end
  end
  packed = false
  fresh = false

  -- ...and the lens follows the rung. On a panel whose lenticular layer is on
  -- a switch, leaving it down after LEIA is switched off means an ordinary
  -- desktop rendered soft and faintly doubled, with nothing on screen to
  -- connect it back to a game setting. Both calls are cheap no-ops once the
  -- lens is already where it is being asked to be.
  if Stereo3D.mode:get() == "leiasr" then
    LeiaSR.weave()
  else
    LeiaSR.lens(false)
  end
end

-- The other end of it, from love.quit: hand the SR context back while the
-- GL context it is keyed to still exists.
function Stereo3D.shutdown()
  LeiaSR.shutdown()
end

-- For the shot tests: the two eyes as they were rendered, before packing.
function Stereo3D.debugEyes()
  if not held then return nil end
  return held.refL or held.L, held.R, held.w, held.h
end

return Stereo3D
