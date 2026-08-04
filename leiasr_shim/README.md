# `leiasr_shim.dll`

The only compiled thing in this repository, and it exists for one reason: the
Simulated Reality OpenGL **weaver** is a C++ class with virtual inheritance,
compiled by MSVC, and LuaJIT's FFI calls C and only C. There is no mangled
name, no vtable layout and no `this` adjustment the FFI could get right, and
neither `extern "C"` nor a `.def` file papers over that at link time.

So the mod's dependency is three flat C functions:

```c
int  srk_init(void *hwnd);                    /* 1 = ready, 0 = unavailable */
void srk_weave(unsigned tex, int w, int h);   /* w is the COMBINED width */
void srk_shutdown(void);
```

Everything version-specific — the SDK headers, the import libraries, the
delay-load list, the structured-exception guards — stays on this side of that
boundary. [`lib/LeiaSR.lua`](../lib/LeiaSR.lua) is the whole of the other
side.

## Building it

The SR SDK is vendored through **bo3b/SR-lib**, which is a *private*
repository — you need read access on your GitHub account, and CI needs a PAT
(see the `shim` job in [`../.github/workflows/release.yml`](../.github/workflows/release.yml)).

```sh
git submodule update --init libs/SR-lib
cmake -S leiasr_shim -B leiasr_shim/build -A x64
cmake --build leiasr_shim/build --config Release
```

The DLL lands at `leiasr_shim/build/Release/leiasr_shim.dll`. To test against
a live install, copy it to `assets/leiasr/leiasr_shim.dll` — that is the path
`lib/LeiaSR.lua` looks in first, and the path the release workflow drops the
CI-built artifact at.

Neither `leiasr_shim/` nor `libs/` is shipped inside the mod archive. The DLL
is; the source it was built from is not.

## What is *not* shipped

The SR runtime DLLs — `SimulatedRealityCore.dll`, `SimulatedRealityOpenGL.dll`,
`DimencoWeaving.dll`, the OpenCV libraries and the rest — come from the user's
own system-wide Simulated Reality installation and are deliberately **not**
redistributed. They are shared between every SR application on the machine,
and shipping a second copy is how version conflicts start.

Which is exactly why every one of them is `/DELAYLOAD`ed and why `srk_init`
probes with `LoadLibraryW` before it touches an SR symbol: on a machine with
no SR runtime at all, this DLL must still *load* and must still be able to
answer "no". Without the delay-load the Windows loader refuses the module
before any of our code runs, and the failure a user sees is a dialog naming
`opencv_world343.dll` — a library the mod does not use, has never heard of,
and cannot mention in its own error message.

## Verifying a build before shipping it

```
dumpbin /imports leiasr_shim.dll | findstr ".dll"
```

Every SR, Dimenco and OpenCV DLL must appear **only** under *"Section contains
the following delay load imports"*. Anything in the ordinary import section is
a hard dependency and will stop the DLL loading on a machine without the SR
runtime — which is most machines.

```
dumpbin /dependents leiasr_shim.dll
```

should show nothing but `KERNEL32.dll`, `OPENGL32.dll` and the delay-loaded
set. `/MT` is what keeps `VCRUNTIME140.dll` out of that list: the host ships
no MSVC runtime, so a `/MD` build would silently cost LeiaSR support on every
machine without the Visual C++ redistributable.
