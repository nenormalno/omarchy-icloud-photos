#!/usr/bin/env python3
"""The app's line to iCloud: sign in, and move one asset to the bin or back.

    icloud_helper.py login   --username APPLE_ID [--save-config]
    icloud_helper.py find    --file PATH --ts EPOCH [--shared]
    icloud_helper.py catalog --since EPOCH --until EPOCH --merge FILE [--zone ZONE ...]
    icloud_helper.py fetch   --record ID --dest DIR [--library ZONE] [--ts EPOCH]
    icloud_helper.py delete  --key KEY --file PATH --ts EPOCH [--companion PATH] [--shared] [--record ID] [--library ZONE]
    icloud_helper.py restore --key KEY

`--shared` looks in the iCloud Shared Library the account is in instead of
the personal one; the sync tool puts those files under LIBRARY/shared.

`login` reads the password as the first line on stdin and, when Apple asks
for two-factor confirmation, prints {"step": "2fa"} and waits for the code
on the next stdin line. The session then lands in icloudpd's cookie
directory, so the sync tool works without ever seeing the password.

`delete` is the only thing that writes to the library. It flips the asset's
isDeleted flag, exactly what the Photos app on the phone does when you tap
the bin: the item lands in "Recently Deleted" and stays recoverable there
for 30 days. Nothing here can empty that folder. Locally the files move into
<cache>/trash/<key>/ with a manifest, so `restore` can put both halves back.

Every command prints JSON objects on stdout, one per line, and exits
non-zero on failure.
"""

import argparse
import json
import logging
import os
import shutil
import sys
import time
import urllib.parse
from pathlib import Path

from pyicloud_ipd.base import PyiCloudService
from pyicloud_ipd.exceptions import (
    PyiCloudConnectionErrorException,
    PyiCloudException,
    PyiCloudFailedLoginException,
    PyiCloudServiceUnavailableException,
)
from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize

CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omarchy-icloud-photos" / "config"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "omarchy-icloud-photos"
WALK_LIMIT = 600  # newest assets to inspect when looking for a filename
TS_TOLERANCE = 180  # seconds between local mtime and iCloud capture time


def read_config(require_id=True):
    cfg = {"COOKIES": str(Path.home() / ".config" / "icloudpd")}
    if CONFIG.exists():
        for line in CONFIG.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    if require_id and "APPLE_ID" not in cfg:
        fail(f"APPLE_ID not set in {CONFIG}")
    return cfg


def save_apple_id(apple_id):
    """Set APPLE_ID in the config file, keeping every other line as it is."""
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    lines = CONFIG.read_text().splitlines() if CONFIG.exists() else [
        "# omarchy-icloud-photos configuration, sourced by omarchy-icloud-photos-sync",
        "LIBRARY=$HOME/Pictures/iCloud",
        "DAYS=7",
    ]
    out, done = [], False
    for line in lines:
        if line.strip().startswith("APPLE_ID="):
            out.append(f"APPLE_ID={apple_id}"); done = True
        else:
            out.append(line)
    if not done:
        out.insert(1, f"APPLE_ID={apple_id}")
    CONFIG.write_text("\n".join(out) + "\n")


def emit(obj):
    print(json.dumps(obj), flush=True)


def fail(message, **extra):
    logging.getLogger().error("fail: %s %s", message, extra if extra else "")
    print(json.dumps({"ok": False, "error": message, **extra}))
    sys.exit(1)


def connect(cfg):
    # The constructor signs in by itself (session token first, password if
    # needed). Calling authenticate() again would be a second sign-in in a
    # row, which Apple answers with a 503.
    api = PyiCloudService("com", cfg["APPLE_ID"], lambda: None, cookie_directory=cfg["COOKIES"])
    if api.requires_2fa:
        fail("iCloud session expired; run icloudpd --auth-only")
    return api


def find_asset(album, name, ts):
    """Newest-first walk until the asset with this filename and capture time."""
    seen = 0
    for asset in album:
        seen += 1
        if asset.filename == name and abs(asset.created.timestamp() - ts) <= TS_TOLERANCE:
            return asset
        if seen >= WALK_LIMIT:
            break
    return None


def libraries(api, shared):
    """(zone name, library) pairs to search: the personal library, or the
    Shared Library. Apple allows one per account, and where it turns up
    depends on who made it: the owner finds its SharedSync zone in the
    private database next to PrimarySync, a participant in the shared one."""
    if not shared:
        return [("PrimarySync", api.photos)]
    out = [(z, lib) for z, lib in api.photos.private_libraries.items() if z != "PrimarySync"]
    out += list(api.photos.shared_libraries.items())
    return out


def locate(api, name, ts, shared):
    """The asset with this name and time, and the library it lives in."""
    for zone, library in libraries(api, shared):
        asset = find_asset(library.all, name, ts)
        if asset is not None:
            return zone, library, asset
    fail("asset not found in the newest items of the " + ("shared" if shared else "personal") + " library")


def find_by_record(library, record, ts=None):
    """Newest-first walk until this master record. When ts is known, stop once
    capture time is more than a day older: the album is ordered newest first."""
    floor = (ts - 86400) if ts else None
    for asset in library.all:
        if asset.id == record:
            return asset
        if floor is not None and asset.created.timestamp() < floor:
            break
    return None


def locate_record(api, record, ts, library_name, shared):
    """The asset with this master record id."""
    if library_name:
        library = library_by_zone(api, library_name)
        asset = find_by_record(library, record, ts)
        if asset is None:
            fail("asset not found")
        return library_name, library, asset
    for zone, library in libraries(api, shared):
        asset = find_by_record(library, record, ts)
        if asset is not None:
            return zone, library, asset
    fail("asset not found")


def library_by_zone(api, zone):
    if not zone or zone == "PrimarySync":
        return api.photos
    library = api.photos.private_libraries.get(zone) or api.photos.shared_libraries.get(zone)
    if library is None:
        fail(f"the shared library {zone} is no longer available")
    return library


def describe(asset):
    rec = asset._asset_record
    return {
        "record": rec["recordName"],
        "changeTag": rec["recordChangeTag"],
        "filename": asset.filename,
        "created": asset.created.isoformat(),
        "size": asset.size,
    }


def set_deleted(library, record_name, change_tag, deleted):
    url = f"{library.service_endpoint}/records/modify?{urllib.parse.urlencode(library.params)}"
    body = {
        "atomic": True,
        "desiredKeys": ["isDeleted"],
        "operations": [{
            "operationType": "update",
            "record": {
                "fields": {"isDeleted": {"value": 1 if deleted else 0}},
                "recordChangeTag": change_tag,
                "recordName": record_name,
                "recordType": "CPLAsset",
            },
        }],
        "zoneID": library.zone_id,
    }
    r = library.session.post(url, data=json.dumps(body), headers={"Content-type": "application/json"})
    data = r.json()
    records = data.get("records") or []
    if not records or "serverErrorCode" in records[0]:
        fail("iCloud refused the change", response=data)
    return records[0].get("recordChangeTag", change_tag)


def demo(cfg):
    return cfg.get("DEMO") == "1"


def cmd_login(args, cfg):
    password = sys.stdin.readline().rstrip("\n")
    # Length and character class only, never the password: enough to tell a
    # typo from a transport problem when Apple answers 401.
    logging.getLogger().info("password: %d characters, non-ascii=%s, ends with space=%s",
                             len(password), any(ord(c) > 127 for c in password), password.endswith(" "))
    if demo(cfg):
        emit({"ok": True, "username": args.username})
        return
    cookies = cfg["COOKIES"]
    # Apple answers 503 on the sign-in front door when it has seen too many
    # sign-ins for the account in a short time, and every new attempt,
    # including an automatic retry, stretches that window. So: one attempt,
    # and on a 503 a clear request to leave it alone for a while.
    try:
        api = PyiCloudService("com", args.username, lambda: password or None, cookie_directory=cookies)
    except PyiCloudFailedLoginException:
        fail("Wrong Apple ID or password")
    except PyiCloudServiceUnavailableException:
        logging.getLogger().warning("503 during authenticate")
        fail("Apple is not taking sign-ins for this account right now, which happens after "
             "several sign-ins in a short time. Leave it for half an hour, then try once; "
             "every attempt before that extends the wait.")
    except PyiCloudConnectionErrorException:
        fail("Could not reach iCloud. Check the connection and try again.")
    except PyiCloudException as e:
        fail(f"Apple did not accept the login: {e}")
    if api.requires_2fa:
        # Ask Apple to push a code to the trusted devices. Apple usually pushes
        # one on the sign-in itself already, and this endpoint answers 503 at
        # times; pyicloud only swallows API errors, not that one, so guard it
        # here. Without the guard a working sign-in looked rate-limited.
        try:
            api.trigger_push_notification()
        except PyiCloudException as e:
            print(f"push notification not sent: {e}", file=sys.stderr)
        emit({"step": "2fa"})
        code = sys.stdin.readline().strip()
        if not (len(code) == 6 and code.isdigit()):
            fail("The code should be six digits")
        if not api.validate_2fa_code(code):
            fail("Apple did not accept that code")
        api.trust_session()
    if args.save_config:
        save_apple_id(args.username)
    emit({"ok": True, "username": args.username})


def cmd_find(args, cfg):
    api = connect(cfg)
    zone, _, asset = locate(api, os.path.basename(args.file), args.ts, args.shared)
    print(json.dumps({"ok": True, "library": zone, **describe(asset)}))


def cmd_delete(args, cfg):
    files = [args.file] + ([args.companion] if args.companion else [])
    for f in files:
        if not os.path.isfile(f):
            fail(f"not a file: {f}")
    if demo(cfg):
        info = {"record": "demo", "changeTag": "", "filename": os.path.basename(args.file), "created": "", "size": 0}
        zone, new_tag = ("demo-shared" if args.shared else "PrimarySync"), ""
    else:
        api = connect(cfg)
        if args.record:
            zone, library, asset = locate_record(api, args.record, args.ts, args.library, args.shared)
        else:
            zone, library, asset = locate(api, os.path.basename(args.file), args.ts, args.shared)
        info = describe(asset)
        new_tag = set_deleted(library, info["record"], info["changeTag"], True)

    trash_dir = CACHE / "trash" / args.key
    trash_dir.mkdir(parents=True, exist_ok=True)
    moved = []
    for f in files:
        dest = trash_dir / os.path.basename(f)
        shutil.move(f, dest)
        moved.append([f, str(dest)])
    manifest = {**info, "library": zone, "changeTag": new_tag, "files": moved}
    (CACHE / "trash" / f"{args.key}.json").write_text(json.dumps(manifest, indent=2))
    print(json.dumps({"ok": True, "key": args.key, **info}))


def cmd_restore(args, cfg):
    manifest_path = CACHE / "trash" / f"{args.key}.json"
    if not manifest_path.exists():
        fail("nothing to restore for this key")
    manifest = json.loads(manifest_path.read_text())
    if not demo(cfg):
        api = connect(cfg)
        library = library_by_zone(api, manifest.get("library"))
        # The change tag moves on every edit; look the record up in Recently
        # Deleted for a fresh one and fall back to the tag we saved.
        tag = manifest["changeTag"]
        seen = 0
        for asset in library.recently_deleted:
            seen += 1
            if asset._asset_record["recordName"] == manifest["record"]:
                tag = asset._asset_record["recordChangeTag"]
                break
            if seen >= WALK_LIMIT:
                break
        set_deleted(library, manifest["record"], tag, False)

    for src, dest in manifest["files"]:
        if os.path.isfile(dest):
            os.makedirs(os.path.dirname(src), exist_ok=True)
            shutil.move(dest, src)
    shutil.rmtree(manifest_path.with_suffix(""), ignore_errors=True)
    manifest_path.unlink()
    print(json.dumps({"ok": True, "key": args.key, "record": manifest["record"], "filename": manifest["filename"]}))


def cmd_catalog(args, cfg):
    """Remember master-record ids for assets captured in [since, until].

    Newest-first, and the walk stops once capture time is older than the
    window, so a recent month does not page the whole library. Merged into
    the existing map so a later jump does not forget the rolling window.
    """
    path = Path(args.merge)
    current = {}
    if path.exists():
        try:
            current = json.loads(path.read_text())
        except json.JSONDecodeError:
            current = {}
    if demo(cfg):
        emit({"ok": True, "count": 0})
        return
    api = connect(cfg)
    zones = args.zone or ["PrimarySync"]
    found = {}
    for zone in zones:
        library = library_by_zone(api, zone)
        side = "shared" if zone != "PrimarySync" else "personal"
        for asset in library.all:
            ts = asset.created.timestamp()
            if ts > args.until + 86400:
                continue
            if ts < args.since - 86400:
                break
            stem = Path(asset.filename).stem
            day = asset.created.date().isoformat()
            found[f"{side}|{stem}|{day}"] = {
                "record": asset.id,
                "library": zone,
                "filename": asset.filename,
                "ts": int(ts),
            }
    current.update(found)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(current))
    os.chmod(path, 0o600)
    emit({"ok": True, "count": len(found)})


def _save_response(resp, dest: Path):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    try:
        with tmp.open("wb") as fh:
            for chunk in resp.iter_content(256 * 1024):
                if chunk:
                    fh.write(chunk)
        os.replace(tmp, dest)
        os.chmod(dest, 0o600)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def _version_path(folder: Path, asset, version, size) -> Path:
    """Same names icloudpd writes: stills get -thumb, live movies get -medium."""
    from icloudpd.base import lp_filename_concatinator
    from pyicloud_ipd.asset_version import add_suffix_to_filename, calculate_version_filename
    from pyicloud_ipd.utils import size_to_suffix
    from pyicloud_ipd.version_size import AssetVersionSize

    name = calculate_version_filename(
        asset.filename, version, size, lp_filename_concatinator, asset.item_type,
    )
    # LivePhotoVersionSize is not in the still-photo suffix table, so the
    # medium movie suffix is added the same way icloudpd does.
    if not isinstance(size, AssetVersionSize):
        name = add_suffix_to_filename(size_to_suffix(size), name)
    return folder / name


def _download_version(library, asset, version, dest: Path, ts: int):
    if dest.is_file() and dest.stat().st_size > 0:
        return False
    _save_response(asset.download(library.session, version.url), dest)
    os.utime(dest, (ts, ts))
    return True


def note(msg: str) -> None:
    """One readable line in helper.log and on stdout (the sync log)."""
    logging.getLogger().info("%s", msg)
    print(time.strftime("%Y-%m-%d %H:%M:%S ") + msg, flush=True)


def cmd_pull(args, cfg):
    """Download thumbnails for [since, until] and stop once photos are older.

    icloudpd's date flags skip items but still walk the whole album. A week
    near the top of a 17k library then spends minutes paging everything older
    than that week. This walk is newest-first and breaks at the floor.
    """
    if demo(cfg):
        emit({"ok": True, "count": 0})
        return
    from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize

    api = connect(cfg)
    library = library_by_zone(api, args.library or "PrimarySync")
    dest_root = Path(args.dest)
    zone = args.library or "PrimarySync"
    side = "shared" if zone != "PrimarySync" else "personal"
    path = Path(args.merge) if args.merge else None
    current = {}
    if path is not None and path.exists():
        try:
            current = json.loads(path.read_text())
        except json.JSONDecodeError:
            current = {}
    found = {}
    count = 0
    walked = 0
    skipped_newer = 0
    errors = 0
    missing_thumb = 0
    reason = "end of library"
    started = time.monotonic()
    last_note = started
    last_day = ""
    window = time.strftime("%Y-%m-%d", time.localtime(args.since))
    until_day = time.strftime("%Y-%m-%d", time.localtime(args.until))
    note(f"pull {zone} {window} .. {until_day}: signed in, walking newest first")

    def progress(force: bool = False) -> None:
        nonlocal last_note
        now = time.monotonic()
        if not force and walked % 200 != 0 and now - last_note < 5:
            return
        last_note = now
        note(
            f"pull {zone}: walked {walked}, skipped {skipped_newer} newer, "
            f"downloaded {count}, errors {errors}, at {last_day or '?'}"
        )

    for asset in library.all:
        walked += 1
        ts = int(asset.created.timestamp())
        last_day = asset.created.astimezone().strftime("%Y-%m-%d")
        if ts > args.until + 86400:
            skipped_newer += 1
            progress()
            continue
        if ts < args.since - 86400:
            reason = f"older than {window}"
            break
        folder = dest_root / asset.created.astimezone().strftime("%Y/%m")
        versions = asset.versions
        thumb = versions.get(AssetVersionSize.THUMB)
        if thumb is None:
            missing_thumb += 1
            note(f"pull skip {asset.filename}: no thumbnail")
            continue
        try:
            still = _version_path(folder, asset, thumb, AssetVersionSize.THUMB)
            if _download_version(library, asset, thumb, still, ts):
                count += 1
                note(f"downloaded {still.name}")
            live = versions.get(LivePhotoVersionSize.MEDIUM)
            if live is not None:
                movie = _version_path(folder, asset, live, LivePhotoVersionSize.MEDIUM)
                if _download_version(library, asset, live, movie, ts):
                    note(f"downloaded {movie.name}")
        except Exception as exc:
            errors += 1
            note(f"pull error {asset.filename}: {exc}")
            continue
        day = asset.created.date().isoformat()
        found[f"{side}|{Path(asset.filename).stem}|{day}"] = {
            "record": asset.id,
            "library": zone,
            "filename": asset.filename,
            "ts": ts,
        }
        progress()
    if path is not None:
        current.update(found)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(current))
        os.chmod(path, 0o600)
    elapsed = time.monotonic() - started
    note(
        f"pull done ({reason}): walked {walked}, skipped {skipped_newer} newer, "
        f"downloaded {count}, catalog {len(found)}, missing thumb {missing_thumb}, "
        f"errors {errors}, {elapsed:.0f}s"
    )
    emit({"ok": True, "count": count, "catalog": len(found), "walked": walked, "errors": errors})


def cmd_fetch(args, cfg):
    """Download one original (and its Live Photo companion) into --dest."""
    if demo(cfg):
        fail("demo library does not download from iCloud")
    started = time.monotonic()
    note(f"fetch library={args.library or 'PrimarySync'} ts={args.ts or 0}")
    api = connect(cfg)
    zone, library, asset = locate_record(api, args.record, args.ts or None, args.library, False)
    versions = asset.versions
    original = versions.get(AssetVersionSize.ORIGINAL)
    if original is None:
        fail("no original for this item")
    dest_dir = Path(args.dest)
    ts = int(asset.created.timestamp())
    written = []

    still = dest_dir / asset.filename
    if not still.is_file() or still.stat().st_size == 0:
        _save_response(asset.download(library.session, original.url), still)
        os.utime(still, (ts, ts))
    written.append(str(still))

    live = versions.get(LivePhotoVersionSize.ORIGINAL)
    if live is not None:
        from icloudpd.base import lp_filename_concatinator
        from pyicloud_ipd.asset_version import calculate_version_filename
        live_name = calculate_version_filename(
            asset.filename, live, LivePhotoVersionSize.ORIGINAL,
            lp_filename_concatinator, asset.item_type,
        )
        live_path = dest_dir / live_name
        if not live_path.is_file() or live_path.stat().st_size == 0:
            _save_response(asset.download(library.session, live.url), live_path)
            os.utime(live_path, (ts, ts))
        written.append(str(live_path))
    note(f"fetch done {asset.filename}: {len(written)} file(s) in {time.monotonic() - started:.1f}s")
    emit({"ok": True, "record": asset.id, "library": zone, "files": written})


def main():
    # Everything pyicloud says goes to <cache>/helper.log so a failed sign-in
    # can be understood afterwards. Passwords are masked by pyicloud itself.
    CACHE.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=CACHE / "helper.log", level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    os.chmod(CACHE / "helper.log", 0o600)
    logging.getLogger().info("helper %s", " ".join(sys.argv[1:]))
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    l = sub.add_parser("login"); l.add_argument("--username", required=True); l.add_argument("--save-config", action="store_true")
    f = sub.add_parser("find"); f.add_argument("--file", required=True); f.add_argument("--ts", type=int, required=True)
    f.add_argument("--shared", action="store_true")
    c = sub.add_parser("catalog")
    c.add_argument("--since", type=int, required=True)
    c.add_argument("--until", type=int, required=True)
    c.add_argument("--merge", required=True)
    c.add_argument("--zone", action="append")
    u = sub.add_parser("pull")
    u.add_argument("--since", type=int, required=True)
    u.add_argument("--until", type=int, required=True)
    u.add_argument("--dest", required=True)
    u.add_argument("--library", default="")
    u.add_argument("--merge", default="")
    g = sub.add_parser("fetch")
    g.add_argument("--record", required=True)
    g.add_argument("--dest", required=True)
    g.add_argument("--library", default="")
    g.add_argument("--ts", type=int, default=0)
    d = sub.add_parser("delete"); d.add_argument("--key", required=True); d.add_argument("--file", required=True)
    d.add_argument("--ts", type=int, required=True); d.add_argument("--companion"); d.add_argument("--shared", action="store_true")
    d.add_argument("--record", default=""); d.add_argument("--library", default="")
    r = sub.add_parser("restore"); r.add_argument("--key", required=True)
    args = p.parse_args()
    cfg = read_config(require_id=args.cmd != "login")
    {"login": cmd_login, "find": cmd_find, "catalog": cmd_catalog, "pull": cmd_pull,
     "fetch": cmd_fetch, "delete": cmd_delete, "restore": cmd_restore}[args.cmd](args, cfg)


if __name__ == "__main__":
    main()
