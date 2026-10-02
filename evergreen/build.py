#!/usr/bin/env python3
"""Build the Evergreen KPM package and a KPM repository to host it.

Evergreen is KOReader with its own Lua front end on top. Native code is not
rebuilt: the official KOReader release named in evergreen/BASE is downloaded
and this checkout's Lua tree (frontend/, plugins/, top-level *.lua) is laid
over it.

    evergreen/build.py            # -> evergreen/dist/

Outputs (evergreen/dist/):
    evergreen_<version>_kindlehf.kpkg   manifest v2, tar.gz (what KPM 0.2.x installs)
    repo/manifest.v2.json               KPM repository index
    repo/packages/evergreen/artifacts/  the .kpkg, at the path the index names

Install from the hosted repo on the Kindle:
    ;kpm add-repo https://nolanvo5894.github.io/evergreen/manifest.v2.json
    ;kpm update
    ;kpm install evergreen
"""

import json
import os
import shutil
import tarfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(HERE, ".cache")
DIST = os.path.join(HERE, "dist")
PLATFORM = "kindlehf"

PACKAGE = {
    "id": "evergreen",
    "name": "Evergreen",
    "author": "nolanvo5894",
    "description": "A reader and home screen for jailbroken Kindles, built on KOReader.",
}
REPO = {
    "id": "evergreen",
    "name": "Evergreen",
    "description": "Evergreen for Kindle (https://github.com/nolanvo5894/evergreen)",
}

# Lua that is taken from this checkout instead of the release.
OVERLAY_DIRS = ["frontend", "plugins"]
OVERLAY_FILES = ["reader.lua", "datastorage.lua", "defaults.lua", "setupkoenv.lua"]


def read(name):
    with open(os.path.join(HERE, name)) as f:
        return f.read().strip()


def fetch_base(tag):
    """Download (once) the official release zip for `tag`."""
    os.makedirs(CACHE, exist_ok=True)
    name = f"koreader-{PLATFORM}-{tag}.zip"
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        url = f"https://github.com/koreader/koreader/releases/download/{tag}/{name}"
        print(f"downloading {url}")
        with urllib.request.urlopen(url) as r, open(path + ".part", "wb") as out:
            shutil.copyfileobj(r, out)
        os.rename(path + ".part", path)
    return path


def stage_app(zip_path, app_dir):
    """Unpack the release's koreader/ folder into app_dir, then overlay our Lua."""
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if not info.filename.startswith("koreader/") or info.is_dir():
                continue
            rel = info.filename[len("koreader/"):]
            dest = os.path.join(app_dir, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with z.open(info) as src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out)
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                os.chmod(dest, mode)

    for d in OVERLAY_DIRS:
        src_root = os.path.join(ROOT, d)
        for dirpath, dirnames, filenames in os.walk(src_root):
            dirnames[:] = [n for n in dirnames if n not in ("spec", "test")]
            for fn in filenames:
                if not fn.endswith(".lua"):
                    continue
                src = os.path.join(dirpath, fn)
                dest = os.path.join(app_dir, os.path.relpath(src, ROOT))
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copy2(src, dest)
    for fn in OVERLAY_FILES:
        shutil.copy2(os.path.join(ROOT, fn), os.path.join(app_dir, fn))


def patch_sftp_path(app_dir):
    """Point dropbear at Evergreen's sftp server.

    KOReader's Kindle dropbear has "/mnt/us/koreader/sftp-server" compiled in,
    which breaks scp/sftp when only Evergreen is installed. Rewrite it in place
    to a path of no greater length (NUL-padded) and ship the server there too.
    """
    old = b"/mnt/us/koreader/sftp-server"
    new = b"/mnt/us/evergreen/sftpd"
    path = os.path.join(app_dir, "dropbear")
    with open(path, "rb") as f:
        data = f.read()
    if data.count(old) != 1:
        raise SystemExit(f"dropbear: expected one {old!r}, found {data.count(old)}")
    data = data.replace(old, new + b"\0" * (len(old) - len(new)))
    with open(path, "wb") as f:
        f.write(data)
    shutil.copy2(os.path.join(app_dir, "sftp-server"), os.path.join(app_dir, "sftpd"))


def build():
    version = read("VERSION")
    base = read("BASE")
    vparts = [int(x) for x in version.split(".")]
    kpkg_name = f"{PACKAGE['id']}_{version}_{PLATFORM}.kpkg"

    stage = os.path.join(DIST, "stage")
    shutil.rmtree(stage, ignore_errors=True)
    app_dir = os.path.join(stage, "evergreen")
    os.makedirs(app_dir)

    stage_app(fetch_base(base), app_dir)
    patch_sftp_path(app_dir)
    with open(os.path.join(app_dir, "evergreen-version"), "w") as f:
        f.write(f"Evergreen {version} (KOReader {base})\n")

    kpm_src = os.path.join(HERE, "kpm")
    for item in os.listdir(kpm_src):
        src = os.path.join(kpm_src, item)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(stage, item))
        else:
            shutil.copy2(src, os.path.join(stage, item))

    manifest = {
        "manifest_version": 2,
        **PACKAGE,
        "version": vparts,
        "dependencies": [],
        "supported_platforms": [PLATFORM],
    }
    with open(os.path.join(stage, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    kpkg_path = os.path.join(DIST, kpkg_name)
    with tarfile.open(kpkg_path, "w:gz", compresslevel=6) as tar:
        for item in sorted(os.listdir(stage)):
            tar.add(os.path.join(stage, item), arcname=item)
    shutil.rmtree(stage)

    # repository: keep earlier artifacts already published under repo/
    repo_dir = os.path.join(DIST, "repo")
    art_rel = f"packages/{PACKAGE['id']}/artifacts/{kpkg_name}"
    os.makedirs(os.path.join(repo_dir, os.path.dirname(art_rel)), exist_ok=True)
    shutil.copy2(kpkg_path, os.path.join(repo_dir, art_rel))
    index_path = os.path.join(repo_dir, "manifest.v2.json")
    index = {"manifest_version": 2, **REPO, "packages": {}}
    if os.path.exists(index_path):
        with open(index_path) as f:
            index = json.load(f)
    pkg = index["packages"].setdefault(PACKAGE["id"], {
        "name": PACKAGE["name"], "author": PACKAGE["author"],
        "description": PACKAGE["description"], "artifacts": [],
    })
    pkg["artifacts"] = [a for a in pkg["artifacts"] if a["version"] != vparts]
    pkg["artifacts"].append({
        "url": art_rel,
        "version": vparts,
        "dependencies": [],
        "supported_platforms": [PLATFORM],
    })
    pkg["artifacts"].sort(key=lambda a: a["version"])
    with open(index_path, "w") as f:
        json.dump(index, f, indent=1)

    size = os.path.getsize(kpkg_path) / 1e6
    print(f"built {kpkg_path} ({size:.1f} MB)")
    print(f"repo  {index_path}")


if __name__ == "__main__":
    build()
