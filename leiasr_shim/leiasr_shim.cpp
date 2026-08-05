// LeiaSR shim DLL — MSVC-built bridge between a LuaJIT host and the
// Simulated Reality OpenGL weaver.
//
// Why this exists: the SR weaver is a C++ class using virtual inheritance,
// and LuaJIT's FFI calls C and only C — there is no mangled name, vtable
// layout or `this` adjustment it could get right, and no .def file or
// extern "C" declaration papers over that. The mod therefore never
// references SR at all — it ffi.load's this DLL at runtime and calls three
// flat C entry points (see lib/LeiaSR.lua):
//
//     int  srk_init(void *hwnd);            // 1 = ready, 0 = unavailable
//     void srk_weave(unsigned tex, int w, int h);   // w is the COMBINED width
//     int  srk_lens(int enable);            // switchable-lens preference
//     void srk_shutdown(void);
//
// srk_lens is newer than the other three, and the mod treats a shim without
// it as a shim that simply cannot express the preference — see LeiaSR.lua.
//
// Everything here is failure-tolerant: a missing DLL, a missing SR runtime,
// or absent SR hardware all end up as "srk_init returned 0", which the mod
// treats as "LeiaSR unavailable" and falls back to plain side-by-side.
//
// We go through bo3b/SR-lib's wrapper (SR.hpp / SR.cpp, compiled into this
// DLL) rather than the raw SDK: CreateSRInterfaceOGL already does the context
// setup, weaver creation, latency and late-latching configuration, and it
// derives the input texture's size and sRGB-ness from the GL texture object
// itself. It also gets the ORDER right - SRContext::create, then
// CreateGLWeaver, and only THEN context->initialize(). Reversed, every call
// still returns success and the weave still runs; it simply stops tracking
// the viewer's eyes, which on a still screenshot is invisible and on a real
// panel is the whole feature.

#include <windows.h>

#include "SR.hpp"

using SimulatedReality::SRInterfaceOGL;
using SimulatedReality::CreateSRInterfaceOGL;

namespace
{
	SRInterfaceOGL *g_iface = nullptr;
	bool g_init_attempted = false;
	bool g_disabled = false;

	// The last texture handed to SetInputTexture. Rebinding the weaver's
	// source is not free -- on some runtime versions it reinitialises
	// internal state -- and the host's side-by-side canvas is a stable
	// object that changes only when the window is resized or the mode is
	// switched. So bind on change, and weave alone on every other frame.
	SimulatedReality::GLuint g_bound_tex = 0;

	// Preflight before touching anything SR. Every SR DLL is delay-loaded
	// (see CMakeLists) so that this shim can *load* on a machine with no SR
	// runtime at all — but the first actual call into a missing delay-loaded
	// DLL raises SEH, which a C++ try/catch won't reliably intercept. Probing
	// with LoadLibraryW first turns "runtime absent" into a clean early
	// return instead of a crash.
	//
	// Three probes rather than one, and the middle one is the point: a machine
	// can have the core runtime installed while the OpenGL weaver DLL is
	// missing, which clears a core-only guard and then raises SEH from inside
	// weaver creation — precisely what the preflight exists to prevent.
	// DimencoWeaving is the deepest link in the chain and pulls OpenCV in
	// behind it, so it is what proves the whole runtime resolves.
	bool sr_runtime_available()
	{
		static const wchar_t *probes[] = {
			L"SimulatedRealityCore.dll",
			L"SimulatedRealityOpenGL.dll",
			L"DimencoWeaving.dll",
		};

		for (const wchar_t *name : probes)
		{
			HMODULE h = LoadLibraryW(name);
			if (h == nullptr)
				return false;
			FreeLibrary(h);
		}
		return true;
	}
}

extern "C" __declspec(dllexport)
int srk_init(void *hwnd)
{
	if (g_disabled)
		return 0;
	if (g_iface != nullptr)
		return 1; // already up; init is idempotent

	if (!g_init_attempted)
	{
		g_init_attempted = true;
		if (!sr_runtime_available())
		{
			g_disabled = true;
			return 0;
		}
	}

	if (hwnd == nullptr)
	{
		g_disabled = true;
		return 0;
	}

	// SR-lib probes availability internally too and reports E_NOINTERFACE
	// rather than throwing, but a bad SR install can still surface as a
	// structured exception from deeper in the runtime.
	__try
	{
		HRESULT hr = CreateSRInterfaceOGL(static_cast<HWND>(hwnd), &g_iface);
		if (FAILED(hr) || g_iface == nullptr)
		{
			g_iface = nullptr;
			g_disabled = true;
			return 0;
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		g_iface = nullptr;
		g_disabled = true;
		return 0;
	}

	return 1;
}

extern "C" __declspec(dllexport)
void srk_weave(unsigned int tex_id, int width, int height)
{
	// width/height are advisory here: SR-lib's SetInputTexture queries the
	// dimensions and internal format straight off the GL texture object. They
	// stay in the ABI so the caller does not have to care which SDK
	// generation is behind the shim — and `width` is the COMBINED left-plus-
	// right width in every generation that reads it, never the per-eye one.
	(void)width;
	(void)height;

	if (g_iface == nullptr || tex_id == 0)
		return;

	const SimulatedReality::GLuint tex =
		static_cast<SimulatedReality::GLuint>(tex_id);

	__try
	{
		if (tex != g_bound_tex)
		{
			g_iface->SetInputTexture(tex);
			g_bound_tex = tex;
		}
		g_iface->Weave();
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		// A weave failure mid-session shouldn't take the game down. Drop to
		// disabled and let the host keep presenting the side-by-side frame
		// it already rendered.
		g_iface = nullptr;
		g_bound_tex = 0;
		g_disabled = true;
	}
}

// The switchable lens, on the panels that have one.
//
// A preference, not a command: the SR service arbitrates across every
// connected application and the lens stays down while anybody still wants it.
// Which is why this is worth wiring at all — a panel left lenticular after the
// game gives up the foreground is a soft, faintly doubled desktop, and the
// user has no reason to connect that to a mod they turned off.
//
// Context-scoped rather than weaver-scoped, so it needs an SRContext to exist:
// before a successful srk_init, or on a panel with a fixed lens, the SDK
// answers E_NOINTERFACE and this returns 0. That is information, not failure.
extern "C" __declspec(dllexport)
int srk_lens(int enable)
{
	if (g_iface == nullptr)
		return 0;

	HRESULT hr = E_FAIL;
	__try
	{
		hr = enable ? SimulatedReality::SREnableLensHint()
		            : SimulatedReality::SRDisableLensHint();
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return 0;
	}
	return SUCCEEDED(hr) ? 1 : 0;
}

extern "C" __declspec(dllexport)
void srk_shutdown(void)
{
	if (g_iface == nullptr)
		return;

	__try
	{
		// Hand the lens back before the context goes, rather than relying on
		// teardown to do it: the hint object is owned by the SRContext and
		// released with it, but saying so explicitly is what makes the
		// desktop sharp again at the moment the player quits.
		SimulatedReality::SRDisableLensHint();
		g_iface->Delete(); // also tears down the SR context
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
	}

	g_iface = nullptr;
	g_bound_tex = 0;
}
