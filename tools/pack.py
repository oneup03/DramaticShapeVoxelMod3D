#!/usr/bin/env python3
"""Pack the mod into dist/ the way the release workflow does.

    python tools/pack.py                 # the WORKING TREE, for testing
    python tools/pack.py --head          # exactly what CI would ship
    python tools/pack.py --version 1.8.0 # stamp a version without editing the manifest

The archive that comes out is what MODS > Import mod .zip eats, so this is
the loop for "change something, see it in the game" without waiting on a
push. It is deliberately the same list of files, the same removals and the
same two checks as `.github/workflows/release.yml`, because a local build
that packs a slightly different archive is worse than no local build -- it
tests something nobody ships.

The default is the WORKING TREE, and that is the whole point of running it
locally: the edit you want to try is not committed yet. Pass --head when you
want to reproduce a CI artifact instead, e.g. to work out what a release
actually contained.

Either way the file list comes from git, never from walking the directory.
Untracked scratch files, build trees and dist/ itself are then excluded by
construction rather than by a list of patterns that drifts.

Standard library only, and no bash: this has to run from a VS Code task on
Windows, where the shell is PowerShell and neither zip(1) nor sha256sum(1)
exists.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

MOD_ID = "DRAMATIC_SHAPE"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Repository furniture, and the shim's SOURCE. A player installs a DLL, not
# the C++ it was built from. Kept identical to the `rm -rf` in the workflow's
# "Build the mod .zip" step -- if one list grows, so does the other.
#
# Note .modkitignore is NOT applied here and must not be: it ships inside the
# archive and is read by the mod loader at install time, not at pack time.
# That is why tests/ is in a release.
DROP_FILES = {
    ".gitattributes",
    ".gitignore",
    ".gitmodules",
    ".luarc.json",
}
DROP_TREES = (
    ".github",
    ".vscode",
    "leiasr_shim",
    "libs",
)

# Where a locally built shim might be, best first. CI downloads this from its
# Windows job; here it is whatever you last built (see leiasr_shim/README.md).
SHIM_SOURCES = (
    os.path.join("leiasr_shim", "build", "Release", "leiasr_shim.dll"),
    os.path.join("assets", "leiasr", "leiasr_shim.dll"),
)
SHIM_DEST = os.path.join("assets", "leiasr", "leiasr_shim.dll")


def git(*args):
    return subprocess.run(
        ["git", "-C", REPO, *args],
        check=True, stdout=subprocess.PIPE,
    ).stdout


def keep(path):
    # The DIRECTORY itself and not only what is under it. `git ls-files` never
    # names a directory, so the worktree path never noticed -- but a tar from
    # `git archive` carries a bare `.github` member, and matching only the
    # `.github/` prefix left three empty directories in the archive. An empty
    # directory is harmless; an archive that quietly differs from CI's is the
    # one thing this script exists not to be.
    path = path.rstrip("/")
    if path in DROP_FILES:
        return False
    return not any(path == d or path.startswith(d + "/") for d in DROP_TREES)


def stage_worktree(staging):
    """Copy every TRACKED file, as it currently is on disk."""
    count = 0
    # -s for the mode, -z so a path with a space or a quote cannot be
    # misparsed. Format per record: "<mode> <sha> <stage>\t<path>".
    for record in git("ls-files", "-s", "-z").split(b"\0"):
        if not record:
            continue
        meta, _, raw = record.partition(b"\t")
        mode = meta.split()[0].decode()
        path = raw.decode("utf-8")
        # 160000 is a gitlink. A submodule has no content in this repository
        # to copy, and libs/ is dropped below in any case.
        if mode == "160000" or not keep(path):
            continue
        src = os.path.join(REPO, path)
        if not os.path.exists(src):
            sys.exit("tracked but missing from the working tree: %s" % path)
        dst = os.path.join(staging, path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        count += 1
    return count


def stage_head(staging):
    """Extract HEAD, which is precisely what `git archive HEAD` gives CI."""
    with tempfile.TemporaryDirectory() as tmp:
        tar_path = os.path.join(tmp, "head.tar")
        with open(tar_path, "wb") as fh:
            fh.write(git("archive", "HEAD"))
        with tarfile.open(tar_path) as tar:
            members = [m for m in tar.getmembers() if keep(m.name)]
            # filter="data" is the 3.12+ default-to-be and silences the
            # deprecation warning; it also refuses absolute and ../ paths,
            # which is the right posture for anything we then zip up.
            try:
                tar.extractall(staging, members=members, filter="data")
            except TypeError:      # Python < 3.12
                tar.extractall(staging, members=members)
            return sum(1 for m in members if m.isfile())


def stage_shim(staging):
    for rel in SHIM_SOURCES:
        src = os.path.join(REPO, rel)
        if os.path.isfile(src):
            dst = os.path.join(staging, SHIM_DEST)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            return rel, os.path.getsize(src)
    return None, 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--head", action="store_true",
                    help="pack HEAD rather than the working tree")
    ap.add_argument("--version",
                    help="stamp this version instead of manifest.json's")
    args = ap.parse_args()

    out = os.path.join(REPO, "dist")
    staging = tempfile.mkdtemp(prefix="dsvm-pack-")
    try:
        n = stage_head(staging) if args.head else stage_worktree(staging)
        print("staged %d files from %s"
              % (n, "HEAD" if args.head else "the working tree"))

        manifest_path = os.path.join(staging, "manifest.json")
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        version = args.version or manifest["version"]
        if version != manifest["version"]:
            manifest["version"] = version
            with open(manifest_path, "w", encoding="utf-8") as fh:
                json.dump(manifest, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            print("stamped version %s (manifest.json on disk is untouched)"
                  % version)

        rel, size = stage_shim(staging)
        if rel:
            print("staged leiasr_shim.dll from %s (%d bytes)" % (rel, size))
        else:
            print("WARNING: no leiasr_shim.dll, so this build has no LEIA "
                  "rung. Every other 3D mode is unaffected. To build it:\n"
                  "         cmake -S leiasr_shim -B leiasr_shim/build -A x64\n"
                  "         cmake --build leiasr_shim/build --config Release")

        os.makedirs(out, exist_ok=True)
        zip_path = os.path.join(out, "%s-%s.zip" % (MOD_ID, version))
        if os.path.exists(zip_path):
            os.remove(zip_path)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            for dirpath, dirs, files in os.walk(staging):
                # Explicit directory entries, which zipfile omits and zip(1)
                # writes. Optional in the format and implied by every member
                # path, so nothing sane needs them -- but the workflow's
                # archive has them, this one is meant to be the same archive,
                # and "the installer might care" is not a thing to find out
                # from a bug report.
                for name in sorted(dirs):
                    full = os.path.join(dirpath, name)
                    arc = os.path.relpath(full, staging).replace("\\", "/")
                    z.writestr(arc + "/", b"")
                for name in sorted(files):
                    full = os.path.join(dirpath, name)
                    arc = os.path.relpath(full, staging).replace("\\", "/")
                    z.write(full, arc)

        # The workflow's own two checks, because an archive whose manifest is
        # not at the root installs as nothing at all and the error the game
        # gives for it does not say so.
        with zipfile.ZipFile(zip_path) as z:
            names = z.namelist()
            if "manifest.json" not in names:
                sys.exit("no manifest.json at the archive root")
            packed = json.loads(z.read("manifest.json").decode("utf-8"))
            if packed["version"] != version:
                sys.exit("packed manifest says %s, expected %s"
                         % (packed["version"], version))
            shim = [x for x in names if x.endswith("leiasr_shim.dll")]
            files_only = [x for x in names if not x.endswith("/")]

        digest = hashlib.sha256()
        with open(zip_path, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                digest.update(block)
        with open(os.path.join(out, "sha256sums.txt"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("%s  %s\n" % (digest.hexdigest(),
                                   os.path.basename(zip_path)))

        print()
        print("dist/%s" % os.path.basename(zip_path))
        print("  %d files, %.1f KiB"
              % (len(files_only), os.path.getsize(zip_path) / 1024))
        print("  manifest.json at the root, reporting %s" % version)
        print("  shim: %s" % (shim[0] if shim else "ABSENT"))
        print("  sha256 %s" % digest.hexdigest())
        print()
        print("Install it from the game: MODS > Import mod .zip")
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    main()
