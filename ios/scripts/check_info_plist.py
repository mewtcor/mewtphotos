#!/usr/bin/env python3
"""Fail if a required Info.plist key is missing, empty or widened. Reads a .plist or an .ipa.

Usage: check_info_plist.py PATH [--built]   |   check_info_plist.py --self-test
--built also requires the build-time substitutions (bundle id, versions, git SHA) to have happened.
"""
import contextlib
import copy
import io
import plistlib
import re
import sys
import tempfile
import zipfile
from pathlib import Path

REQUIRED_TEXT = (
    "NSPhotoLibraryUsageDescription",
    "NSLocalNetworkUsageDescription",
    "NSCameraUsageDescription",
)
REQUIRED_TRUE = ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace")
ASCII_NAMES = ("CFBundleName", "CFBundleDisplayName")  # AltStore error 3009 on non-ASCII names
BUILT_TEXT = ("CFBundleIdentifier", "CFBundleShortVersionString", "MewtPhotosGitSHA")
AUTOBACKUP_TASK_ID = "com.mewtcor.mewtphotos.autobackup"
SOURCE_PLIST = Path(__file__).resolve().parent.parent / "MewtPhotos" / "Info.plist"


def read_plist(path):
    """Return the plist dict from a .plist or from the first Payload/*.app/Info.plist in an .ipa."""
    try:
        path = Path(path)
        if path.suffix.lower() == ".ipa":
            with zipfile.ZipFile(path) as z:
                names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
                if not names:
                    raise ValueError("not a readable plist (no Payload/*.app/Info.plist in the .ipa)")
                data = z.read(names[0])
        else:
            data = path.read_bytes()
        plist = plistlib.loads(data)
    except Exception as e:  # unreadable file, bad zip, bad plist: one short message, never a traceback
        if str(e).startswith("not a readable plist"):
            raise
        raise ValueError("not a readable plist (%s)" % (str(e) or type(e).__name__))
    if not isinstance(plist, dict):
        raise ValueError("not a readable plist (top level is not a dictionary)")
    return plist


def _text(plist, key):
    v = plist.get(key)
    return isinstance(v, str) and v.strip() != ""


def _run(plist, built):
    """Return (problems, number_of_checks)."""
    problems, n = [], 0

    def need(ok, msg):
        nonlocal n
        n += 1
        if not ok:
            problems.append(msg)

    for key in REQUIRED_TEXT:
        need(_text(plist, key), "%s is missing, empty or not text" % key)
    ats = plist.get("NSAppTransportSecurity")
    ats = ats if isinstance(ats, dict) else {}
    need(ats.get("NSAllowsLocalNetworking") is True, "NSAllowsLocalNetworking must be true in NSAppTransportSecurity")
    need("NSAllowsArbitraryLoads" not in ats, "NSAllowsArbitraryLoads must not be present (plain HTTP is allowed for the local network only)")
    for key in REQUIRED_TRUE:
        need(plist.get(key) is True, "%s must be true" % key)
    for key in ASCII_NAMES:
        v = plist.get(key)
        need(isinstance(v, str) and v != "" and v.isascii(), "%s must be non-empty ASCII text (AltStore error 3009)" % key)
    bg_modes = plist.get("UIBackgroundModes")
    need(isinstance(bg_modes, list) and "processing" in bg_modes, "UIBackgroundModes must include 'processing' for 24/7 background backup")
    bg_ids = plist.get("BGTaskSchedulerPermittedIdentifiers")
    need(isinstance(bg_ids, list) and AUTOBACKUP_TASK_ID in bg_ids,
         "BGTaskSchedulerPermittedIdentifiers must include '%s'" % AUTOBACKUP_TASK_ID)
    if built:
        for key in BUILT_TEXT:
            v = plist.get(key)
            need(isinstance(v, str) and v.strip() != "" and "$(" not in v, "%s has an unsubstituted or empty value" % key)
        v = plist.get("CFBundleVersion")
        need(isinstance(v, str) and re.fullmatch(r"[1-9][0-9]*", v) is not None, "CFBundleVersion must be a positive integer")
    return problems, n


def check(plist, built):
    return _run(plist, built)[0]


def main(argv):
    if "--self-test" in argv:
        return self_test()
    paths = [a for a in argv if not a.startswith("--")]
    if len(paths) != 1:
        print("usage: check_info_plist.py PATH [--built] | --self-test", file=sys.stderr)
        return 2
    path, built = paths[0], "--built" in argv
    try:
        plist = read_plist(path)
    except ValueError as e:
        print("ERROR %s: %s" % (path, e), file=sys.stderr)
        return 1
    problems, n = _run(plist, built)
    for p in problems:
        print("ERROR %s: %s" % (path, p), file=sys.stderr)
    if problems:
        return 1
    print("OK %s: %d checks passed" % (path, n))
    return 0


def self_test():
    """Prove the gate still fails when it should; the first failing control stops the run."""
    controls = 0

    def expect(cond, label):
        nonlocal controls
        if not cond:
            print("SELF-TEST FAILED: %s" % label, file=sys.stderr)
            raise SystemExit(1)
        controls += 1

    def fails_naming(plist, key, label, built=False):
        expect(any(key in p for p in check(plist, built)), "%s (expected a problem naming %s)" % (label, key))

    base = read_plist(SOURCE_PLIST)
    expect(check(base, False) == [], "source plist must pass: %s" % check(base, False))

    for key in REQUIRED_TEXT:
        for label, value in (("removed", None), ("empty", ""), ("whitespace", "   "), ("non-string", 123)):
            p = copy.deepcopy(base)
            if value is None:
                del p[key]
            else:
                p[key] = value
            fails_naming(p, key, "%s %s" % (key, label))

    p = copy.deepcopy(base)
    del p["NSAppTransportSecurity"]["NSAllowsLocalNetworking"]
    fails_naming(p, "NSAllowsLocalNetworking", "ATS local networking removed")
    p = copy.deepcopy(base)
    p["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"] = True
    fails_naming(p, "NSAllowsArbitraryLoads", "arbitrary loads added")
    for key in REQUIRED_TRUE:
        p = copy.deepcopy(base)
        p[key] = False
        fails_naming(p, key, "%s false" % key)
        del p[key]
        fails_naming(p, key, "%s removed" % key)
    for key in ASCII_NAMES:
        p = copy.deepcopy(base)
        p[key] = "MewtPhotosé"
        fails_naming(p, key, "%s non-ASCII" % key)
    p = copy.deepcopy(base)
    p["UIBackgroundModes"] = []
    fails_naming(p, "UIBackgroundModes", "UIBackgroundModes missing processing")
    p = copy.deepcopy(base)
    p["BGTaskSchedulerPermittedIdentifiers"] = []
    fails_naming(p, "BGTaskSchedulerPermittedIdentifiers", "BGTaskSchedulerPermittedIdentifiers missing autobackup id")

    # --built: the source plist keeps its $(...) placeholders, so it must fail; a substituted copy must pass.
    fails_naming(base, "CFBundleIdentifier", "unsubstituted source plist in --built mode", built=True)
    built = copy.deepcopy(base)
    built.update({"CFBundleIdentifier": "com.example.mewtphotos", "CFBundleShortVersionString": "0.1.0",
                  "MewtPhotosGitSHA": "abc1234", "CFBundleVersion": "7"})
    expect(check(built, True) == [], "substituted plist must pass --built: %s" % check(built, True))
    built["CFBundleVersion"] = "0"
    fails_naming(built, "CFBundleVersion", "CFBundleVersion 0 in --built mode", built=True)

    # File level: drive main() so the one-line ERROR format and the exit codes are covered too.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)

        def run_main(args):
            err = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                rc = main(args)
            return rc, err.getvalue()

        stripped = copy.deepcopy(base)
        del stripped["NSCameraUsageDescription"]
        (d / "stripped.plist").write_bytes(plistlib.dumps(stripped))
        rc, err = run_main([str(d / "stripped.plist")])
        expect(rc == 1 and "NSCameraUsageDescription" in err, "stripped file exits 1 naming the key")
        (d / "garbage.plist").write_bytes(b"\x00\xffnot a plist")
        rc, err = run_main([str(d / "garbage.plist")])
        expect(rc == 1 and "not a readable plist" in err and "Traceback" not in err, "garbage file gives one ERROR line")
        (d / "empty.plist").write_bytes(b"")
        rc, err = run_main([str(d / "empty.plist")])
        expect(rc == 1 and "not a readable plist" in err and "Traceback" not in err, "empty file gives one ERROR line")
        rc, err = run_main([str(d / "missing.plist")])
        expect(rc == 1 and "not a readable plist" in err, "missing file gives one ERROR line")
        rc, _ = run_main([])
        expect(rc == 2, "no path is a usage error")
        with zipfile.ZipFile(d / "app.ipa", "w") as z:
            z.writestr("Payload/MewtPhotos.app/Info.plist", plistlib.dumps(base))
        rc, _ = run_main([str(d / "app.ipa")])
        expect(rc == 0, "an .ipa is read from Payload/*.app/Info.plist")
        with zipfile.ZipFile(d / "empty.ipa", "w") as z:
            z.writestr("readme.txt", "x")
        rc, err = run_main([str(d / "empty.ipa")])
        expect(rc == 1 and "not a readable plist" in err, "an .ipa without an app plist fails")

    print("SELF-TEST OK: %d controls" % controls)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
