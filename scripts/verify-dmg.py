#!/usr/bin/env python3
"""Verify DroidDock's installer without opening Finder or launching the app.

Run with .build/dmg-tools/bin/python after packaging. The only nonstandard
dependencies are ds_store and mac_alias, shared with the packaging tools.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile

from ds_store import DSStore
from mac_alias import Alias


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        detail = (result.stderr or result.stdout).decode("utf-8", errors="replace").strip()
        raise RuntimeError("{} failed ({}): {}".format(arguments[0], result.returncode, detail))
    return result.stdout


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest(root):
    """Use lstat throughout: preserve symlink targets without following them."""
    result = {}

    def visit(path):
        info = path.lstat()
        entry = {"mode": oct(stat.S_IMODE(info.st_mode))}
        if stat.S_ISLNK(info.st_mode):
            entry.update(type="symlink", target=os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            entry.update(type="file", bytes=info.st_size, sha256=sha256(path))
        elif stat.S_ISDIR(info.st_mode):
            entry["type"] = "directory"
        else:
            raise ValueError("Unsupported application entry: {}".format(path))
        result[str(path.relative_to(root))] = entry
        if entry["type"] == "directory":
            for child in sorted(path.iterdir()):
                visit(child)

    visit(root)
    return result


def tiff_dimensions(path):
    """Read classic TIFF image sizes and density tags, including Retina IFDs."""
    data = path.read_bytes()
    require(data[:2] in (b"II", b"MM"), "Installer background is not a TIFF")
    endian = "<" if data[:2] == b"II" else ">"

    def unpack(fmt, offset):
        return struct.unpack_from(endian + fmt, data, offset)

    require(unpack("H", 2)[0] == 42, "Unsupported TIFF variant; expected classic TIFF")
    offset = unpack("I", 4)[0]
    visited = set()
    images = []
    sizes = {3: 2, 4: 4, 5: 8}
    while offset:
        require(offset not in visited and len(visited) < 32, "Invalid TIFF IFD chain")
        visited.add(offset)
        count = unpack("H", offset)[0]
        tags = {}
        for index in range(count):
            field = offset + 2 + index * 12
            tag, kind, length = unpack("HHI", field)
            if tag not in (256, 257, 282, 283, 296):
                continue
            require(kind in sizes and length == 1, "Unsupported TIFF dimension tag")
            value_offset = field + 8 if sizes[kind] <= 4 else unpack("I", field + 8)[0]
            if kind == 5:
                numerator, denominator = unpack("II", value_offset)
                require(denominator != 0, "Invalid TIFF resolution")
                value = numerator / denominator
            else:
                value = unpack("H" if kind == 3 else "I", value_offset)[0]
            tags[tag] = value
        image = {
            "width": tags.get(256),
            "height": tags.get(257),
            "xResolution": tags.get(282),
            "yResolution": tags.get(283),
            "resolutionUnit": tags.get(296),
        }
        require(image["width"] and image["height"], "TIFF is missing image dimensions")
        images.append(image)
        offset = unpack("I", offset + 2 + count * 12)[0]
    require(any(image["width"] == 1440 and image["height"] == 920 for image in images),
            "Installer background must include a 1440×920 Retina representation")
    for image in images:
        require((image["width"], image["height"]) in ((720, 460), (1440, 920)),
                "Background dimensions do not match the 720×460 installer canvas")
        if image["xResolution"] and image["yResolution"] and image["resolutionUnit"] == 2:
            require(abs(image["width"] * 72 / image["xResolution"] - 720) < 0.01
                    and abs(image["height"] * 72 / image["yResolution"] - 460) < 0.01,
                    "Background density does not produce a 720×460 point canvas")
    return images


def verify_layout(mount):
    background = mount / ".background.tiff"
    require(background.is_file() and not background.is_symlink(), "Missing local installer background")
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        browser = store["."]["bwsp"]
        icons = store["."]["icvp"]
        positions = {name: list(store[name]["Iloc"]) for name in ("DroidDock.app", "Applications")}
        require(next(store.find(".", b"pBBk"), None) is None,
                "Installer must omit the background bookmark for macOS Tahoe compatibility")
        view = store["."]["icvl"]
    require(view == (b"type", b"icnv"), "Installer must open in icon view")
    bounds = [int(value) for value in re.findall(r"-?\d+", browser["WindowBounds"])]
    require(len(bounds) == 4 and bounds[2:] == [720, 492], "Installer window frame is not 720×492")
    for key in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
        require(browser.get(key) is False, "Installer window must hide {}".format(key))
    require(positions == {"DroidDock.app": [190, 246], "Applications": [530, 246]},
            "Installer icons are not at the designed drag-and-drop positions")
    require(icons.get("iconSize") == 112 and icons.get("textSize") == 14,
            "Installer icon or label size differs from the design")
    require(icons.get("arrangeBy") == "none", "Installer icons must retain manual positions")
    require(icons.get("gridSpacing") == 80, "Installer grid spacing must be 80 for Finder compatibility")
    require(icons.get("backgroundType") == 2, "Installer must use its picture background")
    require(icons.get("labelOnBottom") is True, "Installer labels must appear below their icons")
    stored_alias = Alias.from_bytes(icons["backgroundImageAlias"])
    # for_file keeps some text as bytes; decoding the serialized form gives the
    # same representation as the alias read from Finder's property list.
    local_alias = Alias.from_bytes(Alias.for_file(str(background)).to_bytes())
    require(stored_alias.volume.name == local_alias.volume.name == "DroidDock",
            "Background alias references a different volume")
    require(stored_alias.volume.creation_date == local_alias.volume.creation_date,
            "Background alias does not identify this disk image")
    require(stored_alias.target.cnid == local_alias.target.cnid
            and stored_alias.target.folder_cnid == local_alias.target.folder_cnid,
            "Background alias does not identify the image-local background")
    require(stored_alias.target.filename == ".background.tiff"
            and stored_alias.target.posix_path == "/.background.tiff",
            "Background alias must target the file at this volume's root")
    return {
        "windowBounds": bounds,
        "hiddenWindowControls": [key for key in browser if key.startswith("Show") and browser[key] is False],
        "iconPositions": positions,
        "iconSize": icons["iconSize"],
        "textSize": icons["textSize"],
        "arrangeBy": icons["arrangeBy"],
        "gridSpacing": icons["gridSpacing"],
        "backgroundType": icons["backgroundType"],
        "defaultView": "icon-view",
        "background": {
            "file": ".background.tiff",
            "sha256": sha256(background),
            "representations": tiff_dimensions(background),
            "aliasIdentifiesMountedFile": True,
            "backgroundBookmarkOmittedForTahoe": True,
            "volumeName": stored_alias.volume.name,
            "relativePath": stored_alias.target.posix_path,
            "fileID": stored_alias.target.cnid,
            "recordedBuildMountPoint": stored_alias.volume.posix_path,
        },
    }


def verify(args, report):
    dmg = args.dmg.resolve(strict=True)
    source = args.source_app.resolve(strict=True)
    require(dmg.is_file(), "Disk image must be a regular file")
    require(source.is_dir() and source.name == "DroidDock.app", "Source must be DroidDock.app")
    report.update(artifact=dmg.name, bytes=dmg.stat().st_size, sha256=sha256(dmg))
    command(["/usr/bin/hdiutil", "verify", str(dmg)])
    report["imageChecksum"] = "passed"
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)])
    source_manifest = manifest(source)
    report["sourceApplicationManifest"] = source_manifest
    work = Path(tempfile.mkdtemp(prefix="droiddock-dmg-verify-")).resolve()
    mount = work / "volume"
    mount.mkdir()
    report["mountPoint"] = str(mount)
    report["detachedAfterVerification"] = False
    report["temporaryDirectoryRemoved"] = False
    detach_target = str(mount)
    try:
        attached = plistlib.loads(command([
            "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", str(mount), "-plist", str(dmg),
        ]))
        entities = attached["system-entities"]
        mounted_entities = [entity for entity in entities
                            if entity.get("mount-point")
                            and Path(entity["mount-point"]).resolve() == mount]
        require(len(mounted_entities) == 1, "Disk image did not mount at the verification path")
        devices = [entity["dev-entry"] for entity in entities if "dev-entry" in entity]
        require(devices, "Disk image attachment did not return its device")
        detach_target = devices[0]
        report["attachedDevices"] = devices
        require(os.statvfs(mount).f_flag & os.ST_RDONLY, "Verification mount is not read-only")
        report["readOnlyMount"] = "passed"
        visible = sorted(path.name for path in mount.iterdir() if not path.name.startswith("."))
        require(visible == ["Applications", "DroidDock.app"], "Unexpected visible installer contents: {}".format(visible))
        report["visibleRootItems"] = visible
        applications = mount / "Applications"
        require(applications.is_symlink() and os.readlink(applications) == "/Applications",
                "Applications shortcut must link to /Applications")
        report["applicationsShortcut"] = "/Applications"
        guide = mount / ".support" / "Read Me.txt"
        require(guide.is_file() and not guide.is_symlink() and guide.stat().st_size > 0,
                "The hidden installation guide is missing")
        report["installationGuide"] = ".support/Read Me.txt"
        app = mount / "DroidDock.app"
        require(app.is_dir() and not app.is_symlink(), "Mounted application is not a directory")
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        report["mountedApplicationCodesign"] = "passed"
        command(["/usr/bin/plutil", "-lint", str(app / "Contents/Info.plist")])
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        require(info["CFBundleName"] == "DroidDock" and info["CFBundleDisplayName"] == "DroidDock",
                "Application bundle does not display the DroidDock name")
        report.update(appVersion=info["CFBundleShortVersionString"], appBuild=info["CFBundleVersion"],
                      bundleIdentifier=info["CFBundleIdentifier"], mountedApplicationPlist="passed")
        mounted_manifest = manifest(app)
        differences = sorted(key for key in source_manifest.keys() | mounted_manifest.keys()
                             if source_manifest.get(key) != mounted_manifest.get(key))
        require(not differences, "Packaged application differs from source: {}".format(", ".join(differences)))
        report["appMatchesValidatedSource"] = True
        report["appRegularFiles"] = sum(entry["type"] == "file" for entry in mounted_manifest.values())
        report["layout"] = verify_layout(mount)
        report["payloadManifest"] = {
            path.name: ({"type": "symlink", "target": os.readlink(path)} if path.is_symlink()
                        else {"type": "directory"} if path.is_dir()
                        else {"type": "file", "bytes": path.stat().st_size, "sha256": sha256(path)})
            for path in sorted(mount.iterdir())
        }
    finally:
        # This unique mount belongs to this invocation. Never force-detach an
        # existing user image, and never recursively remove a failed mount.
        try:
            if os.path.ismount(mount):
                command(["/usr/bin/hdiutil", "detach", detach_target])
            require(not os.path.ismount(mount), "Verification image remains mounted at {}".format(mount))
            report["detachedAfterVerification"] = True
            if mount.exists():
                mount.rmdir()
            work.rmdir()
            report["temporaryDirectoryRemoved"] = True
        except Exception as error:
            report["cleanupError"] = str(error)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("source_app", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = {"verifiedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "passed": False}
    try:
        verify(args, report)
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    if report["passed"]:
        print("Verified DroidDock installer: {}".format(args.report))
        return 0
    print("Installer verification failed: {}".format(report.get("error", "interrupted")), file=sys.stderr)
    print("Verification report: {}".format(args.report), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
