-- Minimal 4x4 matrix math for voxel world mode.
--
-- Row-major, and sent to the shader with shader:send("mvp", "row", m).
-- LOVE 11.5's matrix uniform defaults to column-major, so the "row" layout
-- argument is what lets these tables read the same way they are written
-- here -- translation in the fourth column, m[4]/m[8]/m[12].
--
-- Only what the renderer actually needs: a perspective projection (the
-- camera), an orthographic one (the sun's shadow pass), an OFF-CENTRE one
-- (a stereo eye's frustum, which is the symmetric one sheared sideways),
-- a look-based view, a quaternion rotation, and the translate/rotateY/scale
-- a model matrix is built from. No general inverse -- nothing here needs
-- to invert anything that is not already rigid.

local Mat4 = {}

function Mat4.identity()
  return { 1, 0, 0, 0,
           0, 1, 0, 0,
           0, 0, 1, 0,
           0, 0, 0, 1 }
end

-- a * b, both row-major
function Mat4.mul(a, b)
  local o = {}
  for r = 0, 3 do
    local a0, a1 = a[r * 4 + 1], a[r * 4 + 2]
    local a2, a3 = a[r * 4 + 3], a[r * 4 + 4]
    for c = 1, 4 do
      o[r * 4 + c] = a0 * b[c] + a1 * b[4 + c] + a2 * b[8 + c] + a3 * b[12 + c]
    end
  end
  return o
end

function Mat4.translate(x, y, z)
  return { 1, 0, 0, x,
           0, 1, 0, y,
           0, 0, 1, z,
           0, 0, 0, 1 }
end

function Mat4.scale(x, y, z)
  return { x, 0, 0, 0,
           0, y, 0, 0,
           0, 0, z, 0,
           0, 0, 0, 1 }
end

function Mat4.rotateY(a)
  local c, s = math.cos(a), math.sin(a)
  return { c, 0, s, 0,
           0, 1, 0, 0,
          -s, 0, c, 0,
           0, 0, 0, 1 }
end

function Mat4.rotateX(a)
  local c, s = math.cos(a), math.sin(a)
  return { 1, 0, 0, 0,
           0, c, -s, 0,
           0, s, c, 0,
           0, 0, 0, 1 }
end

-- The rotation a unit quaternion describes, row-major. Kept for callers
-- that receive an orientation rather than a look direction; a pure rotation
-- is its own inverse under transpose, so both a transform and its view can
-- be built from one of these without a general inverse.
function Mat4.fromQuat(x, y, z, w)
  local xx, yy, zz = x * x, y * y, z * z
  local xy, xz, yz = x * y, x * z, y * z
  local wx, wy, wz = w * x, w * y, w * z
  return { 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy), 0,
           2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx), 0,
           2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy), 0,
           0, 0, 0, 1 }
end

-- Transpose. For a pure rotation this IS the inverse, which is how a view
-- matrix can be assembled without a general 4x4 inverse.
function Mat4.transpose(m)
  return { m[1], m[5], m[9], m[13],
           m[2], m[6], m[10], m[14],
           m[3], m[7], m[11], m[15],
           m[4], m[8], m[12], m[16] }
end

-- Right-handed perspective from an OFF-CENTRE frustum given as the TANGENTS
-- of its four edges off the view axis (left and down negative), onto GL clip
-- space (z in [-1, 1]).
--
-- Tangents rather than angles because that is the unit every caller already
-- has one of. A stereo eye's frustum is the symmetric one with both vertical
-- edges slid sideways by the same amount (StereoRig), and the amount is a
-- ratio of two lengths -- an offset over a convergence distance -- which is a
-- tangent and never was an angle. Taking the atan of it just to take the tan
-- again inside would be arithmetic that only loses precision.
--
-- The (r + l) / w term is the whole of the off-centredness: it is zero for a
-- symmetric frustum, and it SHEARS clip x with depth rather than translating
-- it, which is exactly the difference between two eyes that converge on a
-- plane and two eyes that have simply been slid apart.
function Mat4.frustumTan(l, r, u, d, near, far)
  local w, h, dz = r - l, u - d, near - far
  return { 2 / w, 0, (r + l) / w, 0,
           0, 2 / h, (u + d) / h, 0,
           0, 0, (far + near) / dz, (2 * far * near) / dz,
           0, 0, -1, 0 }
end

-- The same frustum from four signed HALF-ANGLES off the view axis, which is
-- the shape a runtime that tracks a head quotes a field of view in.
function Mat4.fovProjection(angleLeft, angleRight, angleUp, angleDown,
                            near, far)
  return Mat4.frustumTan(math.tan(angleLeft), math.tan(angleRight),
                         math.tan(angleUp), math.tan(angleDown), near, far)
end

-- Right-handed perspective onto GL clip space (z in [-1, 1]).
function Mat4.perspective(fovY, aspect, near, far)
  local f = 1 / math.tan(fovY / 2)
  local d = near - far
  return { f / aspect, 0, 0, 0,
           0, f, 0, 0,
           0, 0, (far + near) / d, (2 * far * near) / d,
           0, 0, -1, 0 }
end

-- Right-handed orthographic projection onto GL clip space (z in [-1, 1]).
-- The view-space box is x in [l, r], y in [b, t], z in [-f, -n] -- near and
-- far are DISTANCES down the view's -z, exactly as in perspective() above.
-- Parallel, so a sun is a direction and nothing else: no eye point, no
-- foreshortening, and clip z stays linear in world units, which is what
-- lets the shadow pass store depth as a plain number.
function Mat4.ortho(l, r, b, t, n, f)
  return { 2 / (r - l), 0, 0, -(r + l) / (r - l),
           0, 2 / (t - b), 0, -(t + b) / (t - b),
           0, 0, -2 / (f - n), -(f + n) / (f - n),
           0, 0, 0, 1 }
end

-- Right-handed look-at. eye/target/up are {x, y, z}.
function Mat4.lookAt(eye, target, up)
  local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
  local function norm(v)
    local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if l == 0 then return { 0, 0, 0 } end
    return { v[1] / l, v[2] / l, v[3] / l }
  end
  local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2],
             a[3] * b[1] - a[1] * b[3],
             a[1] * b[2] - a[2] * b[1] }
  end
  local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end

  local f = norm(sub(target, eye))     -- forward
  local s = norm(cross(f, up))         -- right
  local u = cross(s, f)                -- true up
  return { s[1], s[2], s[3], -dot(s, eye),
           u[1], u[2], u[3], -dot(u, eye),
          -f[1], -f[2], -f[3], dot(f, eye),
           0, 0, 0, 1 }
end

return Mat4
