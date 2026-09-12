#!/usr/bin/env python3
"""Remove only this build's staging directory, after its disk images detach."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def mounted_images(stage):
    data = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"]))
    matches = []
    for image in data.get("images", []):
        path = image.get("image-path")
        if not path:
            continue
        try:
            Path(path).resolve().relative_to(stage)
        except ValueError:
            continue
        matches.append(image)
    return matches


def main():
    stage = Path(sys.argv[1]).resolve()
    artifacts = Path(__file__).resolve().parent.parent / "artifacts"
    if stage.parent != artifacts or not stage.name.startswith(".dmg-build."):
        raise ValueError("Refusing to clean an unrecognized staging directory")
    for image in mounted_images(stage):
        devices = [item["dev-entry"] for item in image.get("system-entities", []) if "dev-entry" in item]
        if not devices:
            raise RuntimeError("Staging image has no detachable device; preserving " + str(stage))
        subprocess.run(["/usr/bin/hdiutil", "detach", devices[0]], check=True)
    if mounted_images(stage):
        raise RuntimeError("A staging image is still attached; preserving " + str(stage))
    shutil.rmtree(stage)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("DMG staging cleanup incomplete: " + str(error), file=sys.stderr)
        sys.exit(1)
