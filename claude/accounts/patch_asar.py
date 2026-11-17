#!/usr/bin/env python3
"""Make an account app use the main app's scratch-workspaces folder.

Claude shows a chat under "No folder" only when its cwd is inside
<own profile>/scratch-workspaces. Main's no-folder chats live in
~/Library/Application Support/Claude/scratch-workspaces, so the other apps
listed them as separate folders. This patch points the copy's scratch folder
at main's, so all apps show the same "No folder" list.

Usage: patch_asar.py "/Applications/Claude Account 2.app"   (then re-sign the app)
Patches Resources/app.asar, Info.plist ElectronAsarIntegrity and the integrity digest
embedded in Electron Framework (Electron 45+). Safe to re-run.
"""
import hashlib, json, plistlib, struct, sys

OLD = b'function UX(){return(0,n.join)(u.app.getPath("userData"),Waa)}'
NEW = b'function UX(){return(0,n.join)(u.app.getPath("home"),"Library/Application Support/Claude",Waa)}'


def walk(node):
    for entry in node["files"].values():
        if "files" in entry:
            yield from walk(entry)
        else:
            yield entry


def main(app):
    asar = f"{app}/Contents/Resources/app.asar"
    raw = open(asar, "rb").read()
    _, pickle_size, _, header_len = struct.unpack("<4I", raw[:16])
    header = json.loads(raw[16:16 + header_len])
    data = raw[8 + pickle_size:]

    target = None
    for entry in walk(header):
        if "unpacked" in entry or not entry.get("size"):
            continue
        start = int(entry["offset"])
        content = data[start:start + entry["size"]]
        if NEW in content:
            print("already patched"); return
        if OLD in content:
            if target or content.count(OLD) != 1:
                sys.exit("patch target not unique; app version changed, update patch_asar.py")
            target = (entry, start, content)
    if not target:
        sys.exit("patch target not found; app version changed, update patch_asar.py")

    entry, start, content = target
    patched = content.replace(OLD, NEW)
    delta = len(patched) - len(content)
    for other in walk(header):
        if "unpacked" not in other and "offset" in other and int(other["offset"]) > start:
            other["offset"] = str(int(other["offset"]) + delta)
    entry["size"] = len(patched)
    block = entry["integrity"]["blockSize"]
    entry["integrity"]["hash"] = hashlib.sha256(patched).hexdigest()
    entry["integrity"]["blocks"] = [hashlib.sha256(patched[i:i + block]).hexdigest()
                                    for i in range(0, len(patched), block)]
    data = data[:start] + patched + data[start + len(content):]

    header_bytes = json.dumps(header, separators=(",", ":")).encode()
    padded = header_bytes + b"\0" * (-len(header_bytes) % 4)
    pickle = struct.pack("<2I", 4 + len(padded), len(header_bytes)) + padded
    with open(asar, "wb") as out:
        out.write(struct.pack("<2I", 4, len(pickle)) + pickle + data)

    plist_path = f"{app}/Contents/Info.plist"
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)
    plist["ElectronAsarIntegrity"]["Resources/app.asar"]["hash"] = hashlib.sha256(header_bytes).hexdigest()
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f)
    update_framework_digest(app, plist["ElectronAsarIntegrity"])
    print("patched", asar)


SENTINEL = b"AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A"


def update_framework_digest(app, integrity):
    # Electron 45+ embeds a SHA-256 of the ElectronAsarIntegrity dict in the framework
    # (section __asar_integrity: sentinel[32] used[1] version[1] digest[32]); keep it in sync.
    framework = f"{app}/Contents/Frameworks/Electron Framework.framework/Electron Framework"
    with open(framework, "r+b") as f:
        data = f.read()
        if data.count(SENTINEL) != 1:
            sys.exit("integrity slot not found once in Electron Framework; update patch_asar.py")
        at = data.find(SENTINEL)
        if data[at + 32] == 0:
            return  # validation off in this build
        digest = hashlib.sha256()
        for key in sorted(integrity):  # ASCII keys: same order as Electron's NSLiteralSearch sort
            for part in (key, integrity[key]["algorithm"], integrity[key]["hash"]):
                digest.update(part.encode())
        f.seek(at + 34)
        f.write(digest.digest())


if __name__ == "__main__":
    main(sys.argv[1])
