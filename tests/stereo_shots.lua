-- Driver: one scene, once per output format -- plus the two raw eyes.
--
-- Stereo is the one feature in this mod that cannot be judged from the
-- window it is running in: half of these formats are meant to be looked at
-- through glasses, one through a lenticular panel, and two are not meant to
-- be looked at directly at all. So this writes the frames out instead, and
-- the interesting one is not any of the packed formats -- it is the SPLIT
-- pair, because two PNGs of the same instant from two viewpoints answer
-- every question anyone can have about a stereo build:
--
--   is the depth the right way round?   Find something NEARER than the
--     screen plane. Its left-eye image must be to the RIGHT of its
--     right-eye image (crossed disparity). If it is the other way, the
--     picture is inside out -- and it still LOOKS like 3D, which is why
--     this is a measurement and not an impression.
--
--   is the horizon inside the budget?   The sky's disparity is the whole
--     depth budget (StereoRig.K/2 of the frame's width at 100%). More than
--     that and no pair of eyes will fuse it comfortably.
--
--   is anything moving that should not be?   Anything with VERTICAL
--     disparity between the two dumps is a bug, full stop: two retinas can
--     be made to fuse a horizontal offset and cannot be made to fuse a
--     vertical one.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/stereo_shots.lua \
--   SHOT_DIR=<dir> lovec.exe .
--
-- knobs (env):
--   SHOT_DIR     output directory (created if missing)  (default "shots/3d")
--   S3D_MAP      map id                                 (default VIRIDIAN_CITY)
--   S3D_SPOT     "x,y[,facing]"                         (default 20,26,up)
--   S3D_RUNG     the voxel camera rung                  (default 5, the 75 one)
--   S3D_SPLIT=1  also dump the two eyes, unpacked
--   S3D_SWEEP=1  also sweep the depth row at one format
--
-- The determinism harness is aa_shots' own, for aa_shots' own reason: these
-- frames differ ONLY by the row under test or comparing them means nothing.
-- The clock is pinned, animated tiles frozen, townsfolk stopped, the camera
-- tween and the mesh queue drained, and nothing is persisted -- every row is
-- moved with ModSetting:sync, which moves a cached index and writes no save.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")
  local OverworldState = require("src.world.OverworldController")

  local ROOT = os.getenv("SHOT_DIR") or "shots/3d"

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[3d] DRAMATIC_SHAPE mod not loaded -- nothing to shoot")
    return
  end
  local V = handle.lib
  local DayNight = V.require("DayNight")
  local ChunkMesher = V.require("ChunkMesher")
  local Voxel = V.require("VoxelState")
  local ShadowMap = V.require("ShadowMap")
  local Stereo3D = V.require("Stereo3D")

  local MAP = os.getenv("S3D_MAP") or "VIRIDIAN_CITY"
  local SPOT = os.getenv("S3D_SPOT") or "20,26,up"
  local RUNG = math.floor(tonumber(os.getenv("S3D_RUNG")) or 5)
  local sx, sy, sf = SPOT:match("^(%-?%d+),%s*(%-?%d+),?%s*(%a*)$")
  sx, sy = tonumber(sx) or 20, tonumber(sy) or 26
  if sf == "" then sf = "up" end

  OverworldState.rollEncounter = function() return nil end

  local NPC = require("src.world.NPC")
  if not NPC.dramaticShape3dFreeze then
    local inner = NPC.update
    function NPC:update(...)
      self.frozen = true
      return inner(self, ...)
    end
    NPC.dramaticShape3dFreeze = true
  end
  pcall(love.math.setRandomSeed, 20260801)

  local TileRenderer = require("src.render.TileRenderer")
  TileRenderer.tick = function() end
  TileRenderer.animFrame = function() return 0 end

  pcall(os.execute, 'mkdir -p "' .. ROOT .. '" 2>/dev/null')
  pcall(os.execute, 'mkdir "' .. ROOT:gsub("/", "\\") .. '" 2>nul')

  local Zoom = require("src.render.Zoom")
  pcall(function()
    game.save.options.zoom = 1
    Zoom.applyOptions(game.save.options)
  end)

  local function cameraStill()
    local o = game.overworld
    local c = o and o.camera
    if not c then return true end
    local lx, ly, held = nil, nil, 0
    for _ = 1, 300 do
      if c.x == lx and c.y == ly then
        held = held + 1
        if held >= 10 then return true end
      else
        held = 0
        lx, ly = c.x, c.y
      end
      U.wait(1)
    end
    return false
  end

  local function angleStill()
    local last, held = nil, 0
    for _ = 1, 600 do
      if Voxel.angle == last then
        held = held + 1
        if held >= 10 then return true end
      else
        held = 0
        last = Voxel.angle
      end
      U.wait(1)
    end
    return false
  end

  local function settle()
    for _ = 1, 900 do
      if ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    for _ = 1, 300 do
      if Voxel.t >= 1 and Voxel.ready and ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    angleStill()
    cameraStill()
    if ShadowMap.forget then ShadowMap.forget() end
    -- and the SCREEN PLANE: convergence is eased in reciprocal space and
    -- settles over about half a second, so a shot taken too soon after a
    -- rung change is at a depth budget that is still on its way somewhere
    U.wait(40)
  end

  local shots, missed = 0, 0
  local function shoot(name)
    local path = ("%s/%s.png"):format(ROOT, name)
    game.capturePath = path
    U.wait(6)
    local f = io.open(path, "rb")
    if f then
      f:close()
      shots = shots + 1
      print(("[3d] %s"):format(path))
    else
      missed = missed + 1
      print("[3d] capture did not reach disk: " .. path)
    end
  end

  DayNight.setting:sync("day")
  U.teleport(game, MAP, sx, sy, sf)
  Pipelines.setLevel("voxel", RUNG)
  Pipelines.setLevel("tiltshift", 0)

  -- twice, for aa_shots' reason: neighbour maps are requested from inside
  -- the render, so an empty queue right after a teleport means "nothing has
  -- been asked for yet" rather than "everything is here"
  settle()
  settle()

  -- OFF first, as the reference. Every format below is this frame packed;
  -- anything that differs by more than the packing is not the packing.
  Stereo3D.mode:sync("off")
  settle()
  shoot("00_off")

  for _, mode in ipairs({ "sbs", "tab", "row", "col", "checker", "anaglyph" }) do
    Stereo3D.mode:sync(mode)
    settle()
    shoot("mode_" .. mode)
    print("[3d]   status: " .. Stereo3D.status())
  end

  -- ------- the two eyes, unpacked
  --
  -- The only output here that answers a question directly rather than by
  -- being looked at through something. See the header.
  if os.getenv("S3D_SPLIT") == "1" then
    Stereo3D.mode:sync("sbs")
    settle()
    local L, R, w, h = Stereo3D.debugEyes()
    if L and R then
      for name, canvas in pairs({ eye_left = L, eye_right = R }) do
        local path = ("%s/%s.png"):format(ROOT, name)
        local okD, data = pcall(canvas.newImageData, canvas)
        if okD and data then
          local okE = pcall(function() data:encode("png", path) end)
          print(("[3d] %s %s (%dx%d)"):format(okE and "" or "FAILED ",
                                              path, w or 0, h or 0))
          if okE then shots = shots + 1 else missed = missed + 1 end
        else
          missed = missed + 1
          print("[3d] could not read back " .. name)
        end
      end
      print("[3d] diff those two: something NEARER than the screen plane must "
            .. "have its LEFT image to the RIGHT of its right one.")
    else
      print("[3d] no pair to split")
    end
  end

  -- ------- the depth row, swept
  --
  -- Three points on the budget at one format, so the row can be seen to be
  -- doing what it says: the disparity of a fixed feature should scale
  -- linearly with it and nothing else about the frame should move.
  if os.getenv("S3D_SWEEP") == "1" then
    Stereo3D.mode:sync("anaglyph")
    for _, d in ipairs({ 0.5, 1, 3 }) do
      Stereo3D.depth:sync(d)
      settle()
      shoot(("depth_%d"):format(math.floor(d * 100 + 0.5)))
    end
    Stereo3D.depth:sync(1)
  end

  -- left where it was found, so a run cannot leak a mode into the next one
  Stereo3D.mode:sync("off")

  print(("[3d] %d shots into %s (%d failed to reach disk)")
    :format(shots, ROOT, missed))
  print("[3d] for ROW / COL / CHECK, magnify a 16x16 crop 4x: the pattern "
        .. "must be exactly ONE display pixel wide, and must STAY one pixel "
        .. "with the AA row at 4X. That is the whole of the upscale rule.")
end
