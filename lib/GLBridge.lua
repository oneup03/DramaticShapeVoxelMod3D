-- The raw OpenGL (and Win32) this mod is otherwise proud to never need.
--
-- One consumer, and it is the SR weaver: an autostereoscopic panel is
-- driven by handing a library the GL TEXTURE NAME of a side-by-side image
-- and a WINDOW HANDLE to align its lenticular pattern against, and LOVE
-- exposes neither. So a few calls a frame drop below LOVE -- discover the
-- name behind a Canvas, find the window behind the GL context -- and put
-- the pipeline back exactly as LOVE believes it to be.
--
-- Three rules keep this safe:
--
--   discovery over spelunking. A canvas's framebuffer and the texture
--   attached to it are read from the DRIVER with documented queries (bind
--   the canvas THROUGH LOVE, then ask GL what is bound and what is on it)
--   rather than from LOVE's internals, so a LOVE patch cannot move them out
--   from under us.
--
--   restore what LOVE caches. LOVE tracks the bound framebuffer and skips
--   redundant binds, so raw binds must end back at the exact binding LOVE
--   thinks is current -- the default framebuffer, 0, since every call here
--   runs between LOVE passes -- or LOVE's next draw lands in ours.
--
--   pcall at the rim, ffi inside. The FFI setup can fail (headless, a GL
--   context without the framebuffer entry points, anything that is not
--   Windows); it fails ONCE, at load(), and callers see `false, reason`
--   rather than an error mid-frame.

local GLBridge = {}

local ffi = nil
local gl = nil                -- opengl32 exports (GL 1.1 + wgl)
local user32 = nil            -- WindowFromDC, and the DPI awareness queries
local ext = {}                -- post-1.1 entry points via wglGetProcAddress
local ready = false
local reason = nil

local GL = {
  FRAMEBUFFER = 0x8D40,
  READ_FRAMEBUFFER = 0x8CA8,
  DRAW_FRAMEBUFFER = 0x8CA9,
  DRAW_FRAMEBUFFER_BINDING = 0x8CA6,
  COLOR_ATTACHMENT0 = 0x8CE0,
  FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE = 0x8CD0,
  FRAMEBUFFER_ATTACHMENT_OBJECT_NAME = 0x8CD1,
  COLOR_BUFFER_BIT = 0x4000,
  NEAREST = 0x2600,
  TEXTURE = 0x1702,
  TEXTURE_2D = 0x0DE1,
  BACK = 0x0405,
  RGBA8 = 0x8058,
  RGBA = 0x1908,
  UNSIGNED_BYTE = 0x1401,
  PIXEL_PACK_BUFFER = 0x88EB,
  STREAM_READ = 0x88E1,
  READ_ONLY = 0x88B8,
}
GLBridge.GL = GL

local CDEF = [[
typedef void (__stdcall *PROC)();
void* wglGetCurrentDC(void);
void* wglGetCurrentContext(void);
PROC wglGetProcAddress(const char*);
void glGetIntegerv(unsigned int pname, int* params);
void glReadBuffer(unsigned int mode);
void glReadPixels(int x, int y, int w, int h, unsigned int format,
                  unsigned int type, void* pixels);
void glFlush(void);
void glViewport(int x, int y, int w, int h);
typedef void (__stdcall *pfn_glBindFramebuffer)(unsigned int, unsigned int);
typedef void (__stdcall *pfn_glGetFramebufferAttachmentParameteriv)(
    unsigned int, unsigned int, unsigned int, int*);
typedef void (__stdcall *pfn_glBlitFramebuffer)(int, int, int, int,
    int, int, int, int, unsigned int, unsigned int);
typedef void (__stdcall *pfn_glGenBuffers)(int, unsigned int*);
typedef void (__stdcall *pfn_glDeleteBuffers)(int, const unsigned int*);
typedef void (__stdcall *pfn_glBindBuffer)(unsigned int, unsigned int);
typedef void (__stdcall *pfn_glBufferData)(unsigned int, intptr_t,
                                           const void*, unsigned int);
typedef void* (__stdcall *pfn_glMapBuffer)(unsigned int, unsigned int);
typedef unsigned char (__stdcall *pfn_glUnmapBuffer)(unsigned int);
]]

local CDEF_USER32 = [[
void* __stdcall WindowFromDC(void* hdc);
void* __stdcall GetThreadDpiAwarenessContext(void);
int __stdcall GetAwarenessFromDpiAwarenessContext(void* value);
void* __stdcall FindWindowW(const wchar_t* cls, const wchar_t* name);
]]

-- One-time FFI setup. Idempotent, and every path out records why it
-- stopped, so the 3D row's status line can say something better than "no".
function GLBridge.load()
  if ready then return true end
  if reason then return false, reason end
  local ok, err = pcall(function()
    ffi = require("ffi")
    -- cdef survives a reload; redefinition is the only error worth eating
    pcall(ffi.cdef, CDEF)
    gl = ffi.load("opengl32")
    local function proc(name, typ)
      local p = gl.wglGetProcAddress(name)
      if p == nil then error(name .. " not exposed by this GL context", 0) end
      return ffi.cast(typ, p)
    end
    ext.glBindFramebuffer = proc("glBindFramebuffer", "pfn_glBindFramebuffer")
    ext.glGetFramebufferAttachmentParameteriv =
      proc("glGetFramebufferAttachmentParameteriv",
           "pfn_glGetFramebufferAttachmentParameteriv")
    ext.glBlitFramebuffer = proc("glBlitFramebuffer", "pfn_glBlitFramebuffer")
  end)
  -- The pixel-buffer entry points are asked for SEPARATELY and softly: they
  -- are an optimisation (see readMeanAsync) rather than a capability, and a
  -- context without them should lose the optimisation and nothing else.
  if ok then
    pcall(function()
      local function proc(name, typ)
        local p = gl.wglGetProcAddress(name)
        if p == nil then error(name .. " missing", 0) end
        return ffi.cast(typ, p)
      end
      ext.glGenBuffers = proc("glGenBuffers", "pfn_glGenBuffers")
      ext.glDeleteBuffers = proc("glDeleteBuffers", "pfn_glDeleteBuffers")
      ext.glBindBuffer = proc("glBindBuffer", "pfn_glBindBuffer")
      ext.glBufferData = proc("glBufferData", "pfn_glBufferData")
      ext.glMapBuffer = proc("glMapBuffer", "pfn_glMapBuffer")
      ext.glUnmapBuffer = proc("glUnmapBuffer", "pfn_glUnmapBuffer")
    end)
  end
  if not ok then
    reason = "GL interop unavailable: " .. tostring(err)
    return false, reason
  end
  ready = true
  return true
end

-- user32 is loaded separately from GL: a machine can perfectly well have
-- one and not the other (a headless run has neither, a non-Windows one has
-- no user32 at all), and the weaver needs both but for different reasons.
local function loadUser32()
  if user32 then return user32 end
  local ok = pcall(function()
    ffi = ffi or require("ffi")
    pcall(ffi.cdef, CDEF_USER32)
    user32 = ffi.load("user32")
  end)
  return ok and user32 or nil
end

function GLBridge.status()
  if ready then return "ok" end
  return reason or "not loaded"
end

-- The window's device and GL contexts.
function GLBridge.contexts()
  if not GLBridge.load() then return nil, nil end
  return gl.wglGetCurrentDC(), gl.wglGetCurrentContext()
end

-- The GL framebuffer behind a LOVE canvas. Bound through LOVE (so LOVE's
-- own cache stays truthful), read from the driver, then released.
function GLBridge.canvasFBO(canvas)
  if not GLBridge.load() then return nil end
  local id = nil
  local ok = pcall(function()
    love.graphics.setCanvas(canvas)
    local out = ffi.new("int[1]")
    gl.glGetIntegerv(GL.DRAW_FRAMEBUFFER_BINDING, out)
    id = out[0]
    love.graphics.setCanvas()
  end)
  pcall(love.graphics.setCanvas)
  return ok and id or nil
end

-- The GL TEXTURE NAME behind a LOVE canvas -- what the weaver wants, and
-- the one thing LOVE has no accessor for at all.
--
-- Two documented queries rather than one: ask what KIND of object is on the
-- framebuffer's first colour attachment, and only then for its name. A
-- canvas backed by a renderbuffer (which LOVE will do for some formats)
-- answers RENDERBUFFER to the first, and its name would be a perfectly
-- valid integer that is not a texture -- handing that to a weaver is a
-- driver crash with no explanation attached to it.
--
-- Cached weakly by canvas: the name is stable for the canvas's lifetime,
-- and the entry goes away with it.
local texCache = setmetatable({}, { __mode = "k" })

function GLBridge.canvasTexture(canvas)
  if not canvas then return nil end
  local hit = texCache[canvas]
  if hit ~= nil then return hit or nil end
  if not GLBridge.load() then return nil end
  local id = nil
  local ok = pcall(function()
    love.graphics.setCanvas(canvas)
    local out = ffi.new("int[1]")
    ext.glGetFramebufferAttachmentParameteriv(
      GL.DRAW_FRAMEBUFFER, GL.COLOR_ATTACHMENT0,
      GL.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, out)
    if out[0] == GL.TEXTURE then
      ext.glGetFramebufferAttachmentParameteriv(
        GL.DRAW_FRAMEBUFFER, GL.COLOR_ATTACHMENT0,
        GL.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, out)
      if out[0] > 0 then id = out[0] end
    end
    love.graphics.setCanvas()
  end)
  pcall(love.graphics.setCanvas)
  texCache[canvas] = (ok and id) or false
  return texCache[canvas] or nil
end

-- The window the GL context is drawing into.
--
-- Straight from the driver: SDL makes its GL device context with GetDC on
-- its own window, and WindowFromDC is documented to hand that window back.
-- The alternative -- SDL_GetWindowWMInfo -- needs an SDL_Window pointer
-- LOVE does not expose and a version-tagged struct whose layout moves
-- between SDL minors, so this is both shorter and steadier.
--
-- The title search is a genuine last resort and reads like one: it picks
-- the wrong window if two share a title. It is here because a window handle
-- is the difference between an SR panel working and not.
function GLBridge.hwnd()
  local u = loadUser32()
  if not u then return nil end
  local hdc = GLBridge.contexts()
  if hdc ~= nil then
    local ok, h = pcall(function() return u.WindowFromDC(hdc) end)
    if ok and h ~= nil then return h end
  end
  local okT, title = pcall(love.window.getTitle)
  if not (okT and title and #title > 0) then return nil end
  local okF, h = pcall(function()
    -- FindWindowW wants UTF-16; LOVE hands out UTF-8, and the titles this
    -- mod's host uses are ASCII, so a widening copy is enough
    local wide = ffi.new("wchar_t[?]", #title + 1)
    for i = 1, #title do wide[i - 1] = title:byte(i) end
    wide[#title] = 0
    return u.FindWindowW(nil, wide)
  end)
  if okF and h ~= nil then return h end
  return nil
end

-- This process's DPI awareness: 0 unaware, 1 system-aware, 2 per-monitor,
-- or nil where the question cannot be asked (before Windows 10 1607, or
-- anywhere that is not Windows).
--
-- Read, never set. Process DPI awareness is declared ONCE and the first
-- declaration wins; SDL makes that declaration while LOVE starts up, long
-- before a mod exists. So all this can do is tell the truth about it -- and
-- it has to, because an interlace pattern or a lenticular weave that the OS
-- then stretches is not slightly wrong, it is 3D that has stopped working
-- with no visible cause.
function GLBridge.dpiAwareness()
  local u = loadUser32()
  if not u then return nil end
  local ok, value = pcall(function()
    local ctx = u.GetThreadDpiAwarenessContext()
    if ctx == nil then return nil end
    return u.GetAwarenessFromDpiAwarenessContext(ctx)
  end)
  if not ok or not value or value < 0 then return nil end
  return value
end

-- The frame LOVE has just finished drawing, copied into a canvas.
--
-- There is no LOVE call for this. captureScreenshot is asynchronous -- it
-- answers next frame, which is a frame too late to do anything to the one
-- being asked about -- and there is no other route to the back buffer's
-- pixels at all. So: blit framebuffer 0 into the canvas's own, which is one
-- driver call and no readback to the CPU.
--
-- Called between the last draw of a frame and the swap, where the BACK
-- buffer is the finished picture and is well-defined to read. (The FRONT
-- buffer would be last frame's, which is a different and much worse answer.)
--
-- Flipped on the way, because framebuffer 0 has row zero at the BOTTOM and a
-- LOVE canvas has it at the top: what comes back reads top-down like every
-- other canvas in the mod, and can be drawn straight back out again.
function GLBridge.captureBackbuffer(dstFBO, w, h)
  if not ready or not dstFBO then return false end
  local ok = pcall(function()
    ext.glBindFramebuffer(GL.READ_FRAMEBUFFER, 0)
    gl.glReadBuffer(GL.BACK)
    ext.glBindFramebuffer(GL.DRAW_FRAMEBUFFER, dstFBO)
    ext.glBlitFramebuffer(0, 0, w, h, 0, h, w, 0,
                          GL.COLOR_BUFFER_BIT, GL.NEAREST)
    ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
  end)
  if not ok then
    pcall(function() ext.glBindFramebuffer(GL.FRAMEBUFFER, 0) end)
  end
  return ok
end

-- ------- reading pixels back WITHOUT stopping the frame
--
-- The mod asks one question of the finished picture every frame: how much
-- of it the interface mask claims (StereoCompose.watch, which is how a
-- full-screen flash is noticed). One number, off a canvas smaller than an
-- icon -- and the obvious way to get it is the most expensive thing in the
-- whole feature.
--
-- glReadPixels is SYNCHRONOUS with every GL command issued before it. Ask
-- for a pixel and the driver drains the queue and waits for the GPU to
-- catch up -- which, in a mod that renders the scene twice, is most of a
-- frame. It does not matter that the canvas is tiny or that it was drawn
-- last frame: the stall is the pipeline, not the bytes. Done once a frame
-- it serialises the CPU and the GPU, which is not a slow frame so much as
-- the end of frames overlapping at all, and it reads as stutter.
--
-- A PIXEL PACK BUFFER turns the same call inside out. With one bound,
-- glReadPixels no longer returns pixels -- it QUEUES a copy into the buffer
-- and returns at once, and the answer is collected on a later frame, by
-- which time the GPU has long finished. Two buffers, alternating, so the
-- one being read from was filled two frames ago.
--
-- Every entry point here is GL 2.1 / ARB_pixel_buffer_object, which is
-- older than anything that can run this mod's shaders. If one is missing
-- anyway, `pbo` stays nil and StereoCompose falls back to LOVE's own
-- readback -- correct, and the thing this exists to avoid.

local pbo = nil          -- { id[2], buf[2], pending[2], w, h, cur }

local function pboSetup(w, h)
  if pbo and pbo.w == w and pbo.h == h then return pbo end
  if not (ext.glGenBuffers and ext.glMapBuffer) then return nil end
  local ok = pcall(function()
    if pbo then
      local dead = ffi.new("unsigned int[2]", pbo.id[0], pbo.id[1])
      ext.glDeleteBuffers(2, dead)
    end
    local ids = ffi.new("unsigned int[2]")
    ext.glGenBuffers(2, ids)
    local bytes = w * h * 4
    for i = 0, 1 do
      ext.glBindBuffer(GL.PIXEL_PACK_BUFFER, ids[i])
      ext.glBufferData(GL.PIXEL_PACK_BUFFER, bytes, nil, GL.STREAM_READ)
    end
    ext.glBindBuffer(GL.PIXEL_PACK_BUFFER, 0)
    pbo = { id = ids, pending = { false, false }, w = w, h = h, cur = 0 }
  end)
  return ok and pbo or nil
end

-- Queue a read of `fbo`'s first colour attachment, and return the MEAN of
-- the red channel from the read queued two frames ago -- 0 to 1, or nil
-- until there is one to collect.
--
-- Red alone because that is what the caller measures: the mask writes its
-- verdict into every channel, and one of them is the whole answer.
function GLBridge.readMeanAsync(fbo, w, h)
  if not ready or not fbo then return nil end
  if not pboSetup(w, h) then return nil end

  local mean = nil
  local other = 1 - pbo.cur
  local ok = pcall(function()
    -- collect first, so the buffer about to be reused is the one we just
    -- finished with rather than the one still in flight
    if pbo.pending[other + 1] then
      ext.glBindBuffer(GL.PIXEL_PACK_BUFFER, pbo.id[other])
      local p = ext.glMapBuffer(GL.PIXEL_PACK_BUFFER, GL.READ_ONLY)
      if p ~= nil then
        local bytes = ffi.cast("unsigned char*", p)
        local sum, n = 0, w * h
        for i = 0, n - 1 do sum = sum + bytes[i * 4] end
        mean = sum / (n * 255)
        ext.glUnmapBuffer(GL.PIXEL_PACK_BUFFER)
      end
      pbo.pending[other + 1] = false
    end

    ext.glBindFramebuffer(GL.READ_FRAMEBUFFER, fbo)
    gl.glReadBuffer(GL.COLOR_ATTACHMENT0)
    ext.glBindBuffer(GL.PIXEL_PACK_BUFFER, pbo.id[pbo.cur])
    -- the null pointer is what makes this a queue rather than a wait: with
    -- a pack buffer bound it is an OFFSET into that buffer, not an address
    gl.glReadPixels(0, 0, w, h, GL.RGBA, GL.UNSIGNED_BYTE, nil)
    pbo.pending[pbo.cur + 1] = true

    ext.glBindBuffer(GL.PIXEL_PACK_BUFFER, 0)
    ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
    gl.glReadBuffer(GL.BACK)
  end)
  if not ok then
    pcall(function()
      ext.glBindBuffer(GL.PIXEL_PACK_BUFFER, 0)
      ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
      gl.glReadBuffer(GL.BACK)
    end)
    pbo = nil
    return nil
  end
  pbo.cur = other
  return mean
end

function GLBridge.asyncReadAvailable()
  return ready and ext.glMapBuffer ~= nil
end

-- Rebind the default framebuffer, which is the binding LOVE believes in
-- between its passes. The weave writes into whatever is bound, so this is
-- what points it at the window rather than at a canvas.
function GLBridge.bindDefaultFramebuffer()
  if not ready then return false end
  return pcall(function() ext.glBindFramebuffer(GL.FRAMEBUFFER, 0) end)
end

-- Set the viewport explicitly, in physical pixels.
--
-- Only one caller needs this, and it needs it for a reason that is not
-- obvious: a foreign renderer handed the default framebuffer draws into
-- whatever viewport is currently set, and that viewport is the LAST thing
-- anybody set -- not something the framebuffer binding restores. LOVE does
-- set it back to the window on setCanvas(), so this is normally a no-op that
-- writes the value already there. It is here so that the one place it matters
-- does not depend on that continuing to be true: get it wrong and the weave
-- lands at the size of the last canvas that was bound, which for the LeiaSR
-- path is the double-width side-by-side, and the panel shows the left half of
-- a picture stretched to twice its width.
function GLBridge.viewport(w, h)
  if not ready then return false end
  return pcall(function() gl.glViewport(0, 0, w, h) end)
end

function GLBridge.flush()
  if not ready then return end
  pcall(function() gl.glFlush() end)
end

return GLBridge
