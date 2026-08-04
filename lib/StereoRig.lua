-- Stereo 3D: the arithmetic that turns one camera into two eyes.
--
-- Pure math on purpose: no FFI, no love.graphics, nothing a headless test
-- cannot hold still. Everything device-shaped lives in Stereo3D and
-- StereoCompose; everything world-shaped is here.
--
-- ------- what an eye IS
--
-- Two eyes, slid apart along the camera's own right by `sep`, both looking
-- exactly the same way -- PARALLEL, never toed in. A toed-in pair rotates
-- each frustum toward a point, which puts vertical parallax at the corners
-- of the frame; two retinas can be made to fuse horizontal disparity and
-- cannot be made to fuse vertical, so a toed-in pair is a headache with a
-- geometric explanation. What makes them agree at a distance instead is a
-- SHEAR: both frustums keep their axes and slide their vertical edges
-- sideways by the same amount, so the two images coincide exactly on one
-- plane -- the CONVERGENCE distance, which is the screen -- and separate
-- linearly in 1/depth on either side of it.
--
--   o        = sep / (2 * conv)            the shear, a pure ratio
--   eye_i    = eye + right * (dir * sep/2)
--   tl, tr   = -tanX - dir*o, tanX - dir*o
--
-- and that is the whole of it. Run a world point through both and the
-- disparity comes out
--
--   NDC.x_L - NDC.x_R = (sep / tanX) * (1/depth - 1/conv)
--
-- which is zero at `conv`, POSITIVE nearer than it (the left eye's image
-- lies to the RIGHT of the right eye's -- crossed disparity, the thing you
-- cross your eyes to fuse, and what "in front of the screen" looks like),
-- and negative behind it. The test suite asserts all three; see the sign
-- note at the bottom of this file, which is the one part of stereo that
-- cannot be reasoned about from first principles alone.
--
-- ------- how much separation
--
-- On a flat screen the thing that has to stay constant is the ANGLE a
-- disparity subtends at the player, which -- for a player who does not move
-- their chair -- is a FRACTION OF SCREEN WIDTH. Matching a real IPD is a
-- headset's problem: a headset has the player's eyes in it and knows where
-- they are. A monitor has neither.
--
-- So the separation is not a length anybody has to guess. It is solved from
-- the budget:
--
--   sep = K * tanX * conv
--
-- Feed that back through the disparity above and every length cancels:
--
--   disparity / screen width = (K/2) * (conv/depth - 1)
--
-- The far horizon lands at K/2 of the screen -- 2.5% at the default -- at
-- EVERY field of view, every rung of the VOXEL ladder, every zoom, every
-- window shape. That is the whole of "auto 3D scaling", in closed form and
-- with no state: `tanX` in the rule above IS the FoV compensation, so the
-- lens can open and shut mid-shot (the battle camera does exactly that as
-- it swings) and the depth budget does not move.
--
-- Which is also the trap. Multiplying by a tan(fov/2)/tan(fov_ref/2) term
-- ON TOP of this -- the shape the compensation takes in an injection mod,
-- which has to infer a camera it does not own -- applies it twice, makes
-- separation go as the SQUARE of the FoV ratio, and puts back exactly the
-- inflation it was added to remove. There is one `tanX` in this file and
-- there should stay one.
--
-- Convergence is a DISTANCE, not a disparity, and takes no FoV term at all.
-- It follows the camera's own subject distance, which is the one thing that
-- says where the player is looking: the orbit's table top, the first-person
-- rig's focus, the arena the battle camera is framing.
--
-- ------- units
--
-- World pixels, throughout, exactly like Voxel3D.monoCamera. `sep` and
-- `conv` are both lengths in it, and the ratio the shear is built from is
-- scale-free -- so nothing here has to know that a tile is 16 of them or
-- that first person calls ten of them a metre.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")

local StereoRig = {}

-- The RIG's per-eye sign. Left is index 1. See the sign note at the bottom.
StereoRig.DIR = { -1, 1 }

-- The depth budget at 100%: the far horizon sits K/2 = 2.5% of the screen
-- width apart. Comfortably inside every published guideline for a seated
-- viewer, and it is the number the 3D DEPTH row multiplies.
StereoRig.K = 0.05

-- Floor on convergence, in world pixels: half a tile. Below this the shear
-- grows without bound and the near plane starts eating the frame. The
-- first-person rig's own focus distance (FirstPerson.FOCUS_DIST, 24 -- a
-- tile and a half) passes through untouched, and so does every orbit rung.
StereoRig.CONV_MIN = 8

local function norm(v)
  local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
  if l < 1e-12 then return nil end
  return { v[1] / l, v[2] / l, v[3] / l }
end

local function cross(a, b)
  return { a[2] * b[3] - a[3] * b[2],
           a[3] * b[1] - a[1] * b[3],
           a[1] * b[2] - a[2] * b[1] }
end

-- The camera's own basis: forward, right, and the true up (which is NOT the
-- up that was handed in -- that one only has to be non-parallel). Exactly
-- the basis Mat4.lookAt builds, because the eyes have to slide along the
-- same right the view matrix will measure them in.
--
-- nil where the up vector is parallel to the view direction, which is the
-- one case that has no right at all.
function StereoRig.basis(mono)
  local eye, focus = mono.eye, mono.focus
  local fwd = norm({ focus[1] - eye[1], focus[2] - eye[2], focus[3] - eye[3] })
  if not fwd then return nil end
  local right = norm(cross(fwd, mono.up))
  if not right then return nil end
  return fwd, right, cross(right, fwd)
end

-- The half-width of the symmetric frustum, as a tangent. `vw`/`vh` are the
-- WORLD-pixel view size the projection is built for -- the same pair
-- Voxel3D.viewProjection is handed -- and not the canvas size, so nothing
-- here moves when the anti-aliasing rung does.
function StereoRig.tanX(mono, vw, vh)
  return math.tan(mono.fov / 2) * (vw / vh)
end

-- The separation and convergence this frame wants, in world pixels.
--
--   depthMul   the 3D DEPTH row: how much of the budget to spend
--   focusMul   the 3D FOCUS row: where the screen plane sits, as a multiple
--              of the camera's own subject distance
function StereoRig.budget(mono, vw, vh, depthMul, focusMul)
  local floor = math.max(StereoRig.CONV_MIN, 1.5 * (mono.near or 1))
  local ceil = math.max(floor, 4 * vh)
  local conv = math.max(floor,
                        math.min(ceil, mono.dist * (focusMul or 1)))
  local sep = StereoRig.K * (depthMul or 1) * StereoRig.tanX(mono, vw, vh) * conv
  return sep, conv
end

-- One eye. `dir` is StereoRig.DIR[i]; `fan` asks for the ray fan (see below).
local function eyeCamera(mono, fwd, right, tUp, tanX, tanY, sep, conv, dir, fan)
  local half = dir * sep * 0.5
  local eye = { mono.eye[1] + right[1] * half,
                mono.eye[2] + right[2] * half,
                mono.eye[3] + right[3] * half }
  -- the focus slides with the eye rather than staying put: sliding it would
  -- be toeing in, which is the thing the shear exists to avoid
  local d = mono.dist
  local focus = { eye[1] + fwd[1] * d, eye[2] + fwd[2] * d, eye[3] + fwd[3] * d }

  local o = sep / (2 * conv)
  local tl, tr = -tanX - dir * o, tanX - dir * o

  local skyRay = nil
  if fan then
    -- The eye's ray fan, from the very tangents its projection is built
    -- from -- which is why the sky cannot disagree with the geometry about
    -- where infinity is. The two eyes' fans differ ONLY in `base`, by
    -- right * -2o, and that is precisely the shear: a direction has no
    -- position for the eye offset to act on, so what is left is the frustum
    -- lean, and the horizon lands at exactly the budget the rule above set.
    skyRay = {
      base = { fwd[1] + right[1] * tl + tUp[1] * tanY,
               fwd[2] + right[2] * tl + tUp[2] * tanY,
               fwd[3] + right[3] * tl + tUp[3] * tanY },
      du = { right[1] * (tr - tl), right[2] * (tr - tl), right[3] * (tr - tl) },
      dv = { tUp[1] * -2 * tanY, tUp[2] * -2 * tanY, tUp[3] * -2 * tanY },
    }
  end

  return {
    view = Mat4.lookAt(eye, focus, mono.up),
    proj = Mat4.frustumTan(tl, tr, tanY, -tanY, mono.near, mono.far),
    eye = eye,
    focus = focus,
    -- billboards yaw at the MONO eye, so both images show the same sprite
    -- frame of the same card; see Voxel3D.eyeCenter
    eyeCenter = mono.eye,
    fov = mono.fov,
    -- the world bend is a function of world position and a shared centre,
    -- so it lands identically in both eyes and is simply carried through
    curve = mono.curve,
    skyRay = skyRay,
  }
end

-- The pair, left first, shaped for Voxel3D.camera's raw-matrix branch.
--
-- `fan` is the sky: true gives each eye a real skybox at its own frustum
-- lean, nil leaves Voxel3D.skyRayLive empty and the sky stays frame-hung --
-- identical in both eyes, i.e. pinned to the screen plane, which is the
-- classic orbit look and also a fusion conflict with ground that recedes
-- behind it. Stereo3D decides; this only builds what it is asked for.
--
-- nil where the camera has no usable basis (an up parallel to the view),
-- which the caller reads as "render mono this frame".
function StereoRig.pair(mono, sep, conv, vw, vh, fan)
  if not mono then return nil end
  local fwd, right, tUp = StereoRig.basis(mono)
  if not fwd then return nil end
  local tanY = math.tan(mono.fov / 2)
  local tanX = tanY * (vw / vh)
  return eyeCamera(mono, fwd, right, tUp, tanX, tanY, sep, conv,
                   StereoRig.DIR[1], fan),
         eyeCamera(mono, fwd, right, tUp, tanX, tanY, sep, conv,
                   StereoRig.DIR[2], fan)
end

-- ------- easing the screen plane
--
-- Convergence moves when the camera's subject distance does, and that can be
-- a cliff: stepping onto the 1ST rung takes it from the orbit's whole table
-- (288 world pixels) to arm's length (24) in one frame, and a battle opens
-- and closes on a placed camera with a distance of its own.
--
-- Eased in RECIPROCAL space, because disparity is linear in 1/conv and not
-- in conv: a plain lerp of the distance covers most of the perceived travel
-- in the last few frames, which reads as the picture lunging the last bit of
-- the way rather than settling into it.
--
-- And SNAPPED across a cut. A rung change, a battle boundary and a warp are
-- all edits, not moves; easing through one shows as a slow depth swell after
-- a hard change of shot, which is a strictly worse artefact than the change
-- itself. `snap` is how the caller says which it was.
StereoRig.EASE = 0.08

function StereoRig.ease(state, target, snap, alpha)
  local inv = 1 / math.max(1e-6, target)
  if snap or not state or state <= 0 then return inv end
  return state + (inv - state) * (alpha or StereoRig.EASE)
end

function StereoRig.eased(state)
  if not state or state <= 0 then return nil end
  return 1 / state
end

-- ------- the sign note
--
-- There are TWO per-eye sign conventions in a stereo build and they answer
-- different questions, so there is no reason for them to agree and no way to
-- settle either by reading:
--
--   THE RIG'S (StereoRig.DIR, above) -- which way this eye's frustum leans.
--   Settled by the arithmetic, and asserted rather than eyeballed: a point
--   nearer than convergence must come out with the LEFT eye's image to the
--   RIGHT of the right eye's. If that inverts, this file is wrong.
--
--   THE COMPOSITOR'S -- which physical eye the display routes a given half,
--   row, column or subpixel to. Settled by a passive filter's polarisation,
--   a shutter driver's phase or a lenticular panel's alignment, none of
--   which software can ask about. That is what the 3D SWAP row is for, and
--   why it is a row rather than a constant.
--
-- Which is why the symptoms are worth telling apart. Depth INVERTED -- near
-- things reading as far -- is the compositor: swap the eyes. Depth ABSENT,
-- with a shimmer over the picture, is neither of these: it is the interlace
-- PHASE, a third convention again, and StereoCompose's parityFlip.

return StereoRig
