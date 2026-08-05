-- Scratch driver: exercise the stereo 3D stack against the real machine --
-- the two eyes actually render, the depth budget holds through a rung tween
-- and a first-person blend, the engine really does offer a present stage,
-- the UI lift finds an interface and not the whole frame, and the LeiaSR
-- ladder either reaches a weaver or says exactly which rung it stopped on.
--
-- Nothing here can be judged headless, which is the whole reason it is a
-- driver rather than a suite assertion: the numbers below come off a live
-- GL context, a live window and (with luck) a live SR panel.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/stereo_probe.lua \
--   lovec.exe .
--
-- knobs (env):
--   S3D_MODE   which output format to hold it in   (default "sbs")
--   S3D_MAP    map id                              (default PALLET_TOWN)
--   S3D_SPOT   "x,y[,facing]"                      (default 10,12,down)
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[3d] DRAMATIC_SHAPE mod not loaded")
    return love.event.quit()
  end
  local V = handle.lib
  local Stereo3D = V.require("Stereo3D")
  local StereoRig = V.require("StereoRig")
  local StereoCompose = V.require("StereoCompose")
  local LeiaSR = V.require("LeiaSR")
  local GLBridge = V.require("GLBridge")
  local Voxel = V.require("VoxelState")
  local Voxel3D = V.require("Voxel3D")

  local MODE = os.getenv("S3D_MODE") or "sbs"
  local MAP = os.getenv("S3D_MAP") or "PALLET_TOWN"
  local SPOT = os.getenv("S3D_SPOT") or "10,12,down"
  local sx, sy, sf = SPOT:match("^(%-?%d+),%s*(%-?%d+),?%s*(%a*)$")
  sx, sy = tonumber(sx) or 10, tonumber(sy) or 12
  if sf == "" then sf = "down" end

  U.teleport(game, MAP, sx, sy, sf)
  Pipelines.setLevel("voxel", 3)
  U.wait(60)

  -- ------- the raw-GL floor the SR path stands on
  --
  -- Three questions, and canvasTexture is the one to watch: it is a new
  -- discovery route (ask the framebuffer what is attached to it, and what
  -- KIND of thing that is) and the failure it guards against -- a canvas
  -- backed by a renderbuffer rather than a texture -- answers with a
  -- perfectly valid integer that is not a texture name.
  print("[3d] GL interop: " .. tostring(GLBridge.load())
        .. " -- " .. GLBridge.status())
  local hdc, hglrc = GLBridge.contexts()
  print("[3d] wgl contexts: " .. tostring(hdc) .. " / " .. tostring(hglrc))
  print("[3d] hwnd: " .. tostring(GLBridge.hwnd()))
  local okC, c = pcall(love.graphics.newCanvas, 64, 64)
  if okC then
    print("[3d] canvas FBO:     " .. tostring(GLBridge.canvasFBO(c)))
    print("[3d] canvas texture: " .. tostring(GLBridge.canvasTexture(c)))
  end

  -- The one thing the mod cannot fix and therefore has to report. Process
  -- DPI awareness is declared once and SDL declares it while LOVE starts;
  -- an interlace pattern or a lenticular weave the OS then stretches is not
  -- slightly wrong, it is 3D that has stopped working with no visible cause.
  local aware = GLBridge.dpiAwareness()
  local okS, scale = pcall(love.window.getDPIScale)
  print(("[3d] dpi awareness=%s scale=%s%s")
    :format(tostring(aware), okS and tostring(scale) or "?",
            (aware and aware < 2 and okS and math.abs(scale - 1) > 0.01)
              and "   <-- the weave and every interlace will be stretched"
              or ""))

  -- ------- switch it on
  Stereo3D.mode:sync(MODE)
  U.wait(90)
  print("[3d] mode=" .. tostring(Stereo3D.mode:get())
        .. " engaged=" .. tostring(Stereo3D.engaged())
        .. " fade=" .. tostring(Stereo3D.fade())
        .. " coverage=" .. tostring(Stereo3D.coverage())
        .. " status=" .. Stereo3D.status())

  local L, R, w, h = Stereo3D.debugEyes()
  if L and R then
    print(("[3d] a pair arrived: %dx%d"):format(w or 0, h or 0))
  else
    print("[3d] NO PAIR -- the eye list never produced two canvases")
  end

  -- ------- Mode A or Mode B, and why
  --
  -- The single most load-bearing unknown in the whole feature: whether this
  -- engine offers a stage that runs AFTER its own UI composites. The mod
  -- discovers it rather than assuming, and this is where the verdict is
  -- readable.
  print("[3d] compose path: "
        .. (Stereo3D.status():find("screen plane") and "MODE B (before the UI)"
            or "MODE A (after the UI, with the interface lifted)"))

  -- ------- what the UI mask actually claims
  --
  -- Near zero on an empty overworld, a modest fraction with a menu up. A
  -- number near 1 means something post-processed the world between the two
  -- stages and there is no interface to lift -- which is the other way the
  -- mod falls back to Mode B, and the reason this is measured rather than
  -- hoped for.
  local function coverage(what)
    local eL, eR, cw, ch = Stereo3D.debugEyes()
    if not eL then print("[3d] coverage " .. what .. ": no pair") return end
    local cov = StereoCompose.coverage(eL, eL, cw, ch)
    print(("[3d] coverage %-12s %s"):format(what, tostring(cov)))
  end
  coverage("(self-test)")   -- a frame against itself must be ~0

  -- ------- the depth budget, live
  --
  -- The numbers that say auto scaling is working: sep/conv is the whole of
  -- the perceived depth, and it must hold constant through a rung tween and
  -- through the first-person blend -- two moments where the field of view
  -- and the subject distance both change hard.
  local function trace(tag, frames)
    for i = 1, (frames or 1) do
      U.wait(6)
      local mono = Voxel3D.monoCamera(0, 0, 320, 288)
      if mono then
        local sep, conv = StereoRig.budget(mono, 320, 288,
                                           Stereo3D.depth:get(),
                                           Stereo3D.focus:get())
        print(("[3d] %-10s fov=%.4f dist=%8.2f conv=%8.2f sep=%7.3f "
            .. "sep/conv=%.6f")
          :format(tag, mono.fov, mono.dist, conv, sep, sep / conv))
      else
        print(("[3d] %-10s (raw-matrix camera -- mono this frame)"):format(tag))
      end
    end
  end

  trace("orbit-35", 3)
  Pipelines.setLevel("voxel", 5)          -- the 75-degree rung
  U.wait(90)
  trace("orbit-75", 3)
  Pipelines.setLevel("voxel", Voxel.FP_LEVEL)
  U.wait(30)
  trace("blending", 6)                    -- mid-blend, which is where a
  U.wait(120)                             -- badly eased screen plane shows
  trace("first-person", 3)
  Pipelines.setLevel("voxel", 3)
  U.wait(120)
  trace("back-to-35", 3)

  -- ------- the LeiaSR ladder
  --
  -- Every rung of it, named, every launch -- because "it did not work" on an
  -- autostereo panel has half a dozen causes and they are indistinguishable
  -- from the picture.
  print("[3d] leia: platform=" .. tostring(LeiaSR.platformOK())
        .. " ready=" .. tostring(LeiaSR.ready())
        .. " status=" .. LeiaSR.status())
  local warn = LeiaSR.dpiWarning()
  if warn then print("[3d] leia: " .. warn) end
  if LeiaSR.platformOK() then
    Stereo3D.mode:sync("leiasr")
    U.wait(120)
    print("[3d] leia after 2s: ready=" .. tostring(LeiaSR.ready())
          .. " status=" .. LeiaSR.status())
    print("[3d] (if the picture is side by side, the ladder stopped where "
          .. "the status says. If it is 3D but does not TRACK YOUR HEAD, the "
          .. "weaver came up in the wrong order -- see leiasr_shim.)")
    U.wait(300)

    -- The switchable lens, on the panels that have one. False here is three
    -- different things -- no shim, a shim built before the export, or a panel
    -- whose lens does not move -- and only the first two are worth chasing.
    print("[3d] leia lens: asked down=" .. tostring(LeiaSR.lens(true)))
    U.wait(60)
    print("[3d] leia lens: asked up=" .. tostring(LeiaSR.lens(false))
          .. " (the desktop should be sharp 2D again; if it never was "
          .. "lenticular, this panel has a fixed lens and false is correct)")
    U.wait(60)

    -- And the round trip, which is the interesting one: the weaver comes up
    -- ONCE and every later selection of the rung short-circuits past it, so
    -- anything hung off first-time setup is off by one trip out and back.
    -- Leave LEIA, come back to it, and the picture must weave again with the
    -- lens back down -- not side by side, and not autostereo through a lens
    -- that stayed up.
    Stereo3D.mode:sync("sbs")
    U.wait(60)
    print("[3d] leia round trip: away, ready=" .. tostring(LeiaSR.ready()))
    Stereo3D.mode:sync("leiasr")
    U.wait(60)
    print("[3d] leia round trip: back, ready=" .. tostring(LeiaSR.ready())
          .. " status=" .. LeiaSR.status()
          .. " (this must be weaving again, lens and all)")
    U.wait(300)
  end

  -- ------- what it cost
  --
  -- DS_PERF=1 in the environment turns lib/Perf on; without it every label
  -- below is a boolean test and nothing else. The one to watch is
  -- Stereo.watch: it is the coverage measurement, and it is the one thing
  -- in this feature that USED to stop the frame dead. If the report shows
  -- Stereo.watchBlocking instead, this GL context had no pixel-buffer
  -- objects and the measurement is falling back to the blocking readback --
  -- which is the stutter it exists to avoid.
  local Perf = V.require("Perf")
  if Perf.enabled then
    print("[3d] --- with 3D on ---")
    Perf.reset()
    Stereo3D.mode:sync(MODE)
    U.wait(240)
    Perf.printReport("stereo on")
    local onStats = Perf.frameStats()

    print("[3d] --- with 3D off ---")
    Stereo3D.mode:sync("off")
    U.wait(60)
    Perf.reset()
    U.wait(240)
    Perf.printReport("stereo off")
    local offStats = Perf.frameStats()
    if onStats and offStats and onStats.n > 0 and offStats.n > 0 then
      print(("[3d] frame time  avg %.2f -> %.2f ms  (%.2fx)")
        :format(offStats.avg, onStats.avg,
                onStats.avg / math.max(1e-9, offStats.avg)))
      print(("[3d] frame time  p95 %.2f -> %.2f ms")
        :format(offStats.p95, onStats.p95))
      -- the stutter number. An average can double and still feel smooth; a
      -- worst case and a count of frames over the vsync budget are what a
      -- hitch actually is
      print(("[3d] worst frame %.2f -> %.2f ms")
        :format(offStats.worst, onStats.worst))
      print(("[3d] frames over 16.7ms: %d/%d flat, %d/%d in 3D")
        :format(offStats.over16, offStats.n, onStats.over16, onStats.n))
    end
    Stereo3D.mode:sync(MODE)
  else
    print("[3d] (set DS_PERF=1 for the cost breakdown)")
  end

  -- ------- and back, cleanly
  --
  -- The hardest test in the file and the one to read last: after all of the
  -- above -- two eyes, a compose, possibly a weaver's whole renderer running
  -- inside our frame -- do ORDINARY FLAT frames still come out right?
  Stereo3D.mode:sync("off")
  U.wait(180)
  print("[3d] back to flat: engaged=" .. tostring(Stereo3D.engaged())
        .. " status=" .. Stereo3D.status())
  print("[3d] look at the window now. Anything wrong with THIS picture is "
        .. "GL state the compose or the weaver left behind.")
  U.wait(240)
  love.event.quit()
end
