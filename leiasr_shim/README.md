# `leiasr_shim.dll`

The only compiled thing in this repository, and it exists for one reason: the
Simulated Reality OpenGL **weaver** is a C++ class with virtual inheritance,
compiled by MSVC, and LuaJIT's FFI calls C and only C. There is no mangled
name, no vtable layout and no `this` adjustment the FFI could get right, and
neither `extern "C"` nor a `.def` file papers over that at link time.

So the mod's dependency is four flat C functions:

```c
int  srk_init(void *hwnd);                    /* 1 = ready, 0 = unavailable */
void srk_weave(unsigned tex, int w, int h);   /* w is the COMBINED width */
int  srk_lens(int enable);                    /* switchable-lens preference */
void srk_shutdown(void);
```

Everything version-specific — the SDK headers, the import libraries, the
delay-load list, the structured-exception guards — stays on this side of that
boundary. [`lib/LeiaSR.lua`](../lib/LeiaSR.lua) is the whole of the other
side.

`srk_lens` is newer than the other three, and the Lua side treats a shim
without it as a shim that cannot express the preference — which is also how a
panel with a fixed lens behaves. So an old DLL beside a new mod degrades
rather than breaking.

## Building it

The SR SDK is vendored through **bo3b/SR-lib**, which is a *private*
repository — you need read access on your GitHub account, and CI needs a PAT
(see the `shim` job in [`../.github/workflows/release.yml`](../.github/workflows/release.yml)).

The submodule tracks its **`api_expansion`** branch, which is where SR-lib's
CMake package lives. `CMakeLists.txt` here is three meaningful lines —
`add_subdirectory`, link `SRLib::SR`, `srlib_apply_delayload` — because the
package owns the SDK paths, the import libraries and the delay-load list.
Those used to be written out by hand here, and the hand-written version is now
known not to build the current SR.cpp at all (it predates
`SimulatedRealityFaceTrackers`).

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
runtime — which is most machines. A current build reads:

```
Section contains the following imports:
    OPENGL32.dll
    KERNEL32.dll

Section contains the following delay load imports:
    SimulatedRealityCore.dll
    SimulatedRealityFaceTrackers.dll
    SimulatedRealityDisplays.dll
    SimulatedRealityOpenGL.dll
```

Two DLLs are on the delay-load *list* without appearing here, and that is
correct rather than a gap: `srlib_apply_delayload` names the complete SR set
rather than tailoring it per consumer, and `/DELAYLOAD` on a DLL you do not
import is a no-op. (`/ignore:4199` is what stops the linker warning about each
one and training everybody to skim link warnings.)

Two exports left of KERNEL32 is also the `/MT` check: the host ships no MSVC
runtime, so a `/MD` build would put `VCRUNTIME140.dll` in that top section and
silently cost LeiaSR support on every machine without the Visual C++
redistributable.

```
dumpbin /exports leiasr_shim.dll
```

should list exactly `srk_init`, `srk_lens`, `srk_shutdown` and `srk_weave`.
