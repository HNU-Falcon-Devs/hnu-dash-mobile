"""Inspect development-only Android release artifacts on GitHub-hosted CI."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET
import zipfile

ANDROID = "{http://schemas.android.com/apk/res/android}"
ABIS = {"armeabi-v7a", "arm64-v8a", "x86_64"}
PAGE_ABIS = {"arm64-v8a", "x86_64"}
SQLCIPHER_HASHES = {
    "armeabi-v7a": "0999b58c9d7b08a08d840fecebe6a820d8cc9dfb59197ca68ff27e5514c768ba",
    "arm64-v8a": "e615e2750c5fa455d5a7e70fe4df86c3a2f5696367ceb021d46a9262120df046",
    "x86_64": "bae3621c9f0417583e2234ec93eab65e85bf91d6c8131b7db38403a83a59507b",
}
PLATFORM_LIBS = {
    "libandroid.so", "libc.so", "libdl.so", "liblog.so", "libm.so",
    "libEGL.so", "libGLESv1_CM.so", "libGLESv2.so", "libGLESv3.so",
    "libjnigraphics.so", "libvulkan.so", "libz.so", "libOpenSLES.so",
    "libaaudio.so", "libmediandk.so", "libcamera2ndk.so", "libnativewindow.so",
    "libsync.so", "libstdc++.so", "libatomic.so",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(*args):
    return subprocess.check_output(args, text=True)


def inventory():
    config = Path(".dart_tool/package_config.json")
    for package in json.loads(config.read_text())["packages"]:
        uri = urlparse(package["rootUri"])
        if uri.scheme == "file":
            root = Path(unquote(uri.path))
        elif not uri.scheme:
            root = config.parent / unquote(uri.path)
        else:
            raise ValueError(f"Unknown package root scheme: {uri.scheme}")
        files = sorted(
            path for path in root.iterdir()
            if path.is_file() and path.name.upper().startswith(
                ("LICENSE", "LICENCE", "NOTICE", "COPYING", "COPYRIGHT")
            )
        )
        print(json.dumps({
            "package": package["name"],
            "notice_candidates": [
                {"name": path.name, "sha256": digest(path.read_bytes())}
                for path in files
            ],
            "status": "review required" if files else "no root notice found; investigate",
        }))
    print("Inventory only: neither presence nor absence proves license compliance.")


def apk_verify(apk):
    failures = []

    def check(condition, message):
        if not condition:
            failures.append(message)
            print(f"FAIL: {message}")

    sdk = Path(os.environ["ANDROID_HOME"])
    build_tools = sorted(
        (p for p in (sdk / "build-tools").iterdir()
         if (p / "apksigner").is_file() and (p / "zipalign").is_file()),
        key=lambda p: tuple(map(int, re.findall(r"\d+", p.name))),
    )[-1]
    analyzer = sdk / "cmdline-tools" / "latest" / "bin" / "apkanalyzer"
    print(f"Android build tools: {build_tools.name}")
    print(f"APK bytes={apk.stat().st_size} SHA256={digest(apk.read_bytes())}")
    manifest = run(str(analyzer), "manifest", "print", str(apk))
    print(manifest)
    root = ET.fromstring(manifest)
    app = root.find("application")
    uses_sdk = root.find("uses-sdk")
    version = re.search(r"^version:\s*(\S+)\s*$", Path("pubspec.yaml").read_text(), re.M)
    version_name, version_code = version.group(1).split("+")
    check(root.get("package") == "dev.hnudash.hnu_dash_mobile", "development package ID changed")
    check(root.get(ANDROID + "versionName") == version_name, "versionName differs from pubspec")
    check(root.get(ANDROID + "versionCode") == version_code, "versionCode differs from pubspec")
    check(uses_sdk is not None and all(
        uses_sdk.get(ANDROID + key, "").isdigit()
        for key in ("minSdkVersion", "targetSdkVersion")
    ), "effective min/target SDK missing")
    check(app.get(ANDROID + "allowBackup") == "false", "backup must remain disabled")
    check(app.get(ANDROID + "debuggable", "false") == "false", "release is debuggable")
    check(app.get(ANDROID + "usesCleartextTraffic", "false") != "true", "cleartext explicitly enabled")
    callbacks = [(d.get(ANDROID + "scheme"), d.get(ANDROID + "host"))
                 for d in app.findall("activity/intent-filter/data")]
    check(("dev.hnudash.mobile", "login-callback") in callbacks, "development OAuth callback missing")
    permissions = {p.get(ANDROID + "name") for p in root.findall("uses-permission")}
    check({"android.permission.INTERNET", "android.permission.CAMERA"} <= permissions,
          "required permissions missing")
    print(f"Effective permissions: {sorted(permissions)}")
    print("apksigner version:", run(str(build_tools / "apksigner"), "version").strip())
    signature = subprocess.run(
        [str(build_tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)],
        capture_output=True, text=True,
    )
    print(signature.stdout + signature.stderr)
    check(signature.returncode != 0 and "DOES NOT VERIFY" in signature.stdout + signature.stderr,
          "expected unsigned APK, not a verified signature or a tool error")
    with zipfile.ZipFile(apk) as archive, apk.open("rb") as raw:
        names = archive.namelist()
        check(len(names) == len(set(names)), "duplicate ZIP entries")
        v1 = [name for name in names if re.fullmatch(
            r"META-INF/(?:[^/]+\.(?:SF|RSA|DSA|EC)|SIG-[^/]+)", name, re.I
        )]
        check(not v1, "JAR signing entries present")
        raw.seek(archive.start_dir - 16)
        check(raw.read(16) != b"APK Sig Block 42", "APK signing block present")
        libraries = sorted(name for name in names if re.fullmatch(r"lib/[^/]+/[^/]+\.so", name))
        actual_abis = {name.split("/")[1] for name in libraries}
        check(actual_abis == ABIS, f"unexpected ABI set: {sorted(actual_abis)}")
        for abi in sorted(ABIS):
            for library in ("libapp.so", "libflutter.so", "libsqlcipher.so"):
                check(f"lib/{abi}/{library}" in names, f"missing {abi}/{library}")
        for name in libraries:
            abi = name.split("/")[1]
            binary = archive.read(name)
            sha = digest(binary)
            if name.endswith("/libsqlcipher.so"):
                check(any(marker in binary for marker in (b"cipher_version", b"sqlite3_key", b"SQLCipher")),
                      f"{name}: no SQLCipher marker")
                print(f"{name}: upstream release hash match={sha == SQLCIPHER_HASHES.get(abi)}")
            with tempfile.NamedTemporaryFile() as tmp:
                tmp.write(binary)
                tmp.flush()
                dynamic = run("readelf", "-dW", tmp.name)
                segments = run("readelf", "-lW", tmp.name)
            needed = re.findall(r"Shared library: \[([^]]+)\]", dynamic)
            alignments = [int(line.split()[-1], 16) for line in segments.splitlines()
                          if line.strip().startswith("LOAD ")]
            check(bool(alignments), f"{name}: no ELF LOAD segments")
            missing = [dep for dep in needed if dep not in PLATFORM_LIBS
                       and f"lib/{abi}/{dep}" not in names]
            check(not missing, f"{name}: unresolved native dependencies {missing}")
            compressed = archive.getinfo(name).compress_type != zipfile.ZIP_STORED
            print(json.dumps({"library": name, "sha256": sha, "needed": needed,
                              "load_alignment": [hex(a) for a in alignments],
                              "compressed": compressed}))
            if abi in PAGE_ABIS:
                check(bool(alignments) and min(alignments) >= 16384,
                      f"{name}: ELF LOAD alignment below 16 KiB")
                check(not compressed, f"{name}: compressed; direct ZIP alignment not established")
    aligned = subprocess.run(
        [str(build_tools / "zipalign"), "-c", "-P", "16", "4", str(apk)]
    )
    check(aligned.returncode == 0, "16 KiB ZIP alignment verification failed")
    if failures:
        raise SystemExit(f"Unsigned release verification failed ({len(failures)} checks)")
    print("PASS: unsigned development APK, manifest, ABI/native dependencies and 16 KiB packaging.")
    print("NOT a signed, distributable, licensed, or physically accepted APK.")


if __name__ == "__main__":
    if sys.argv[1:] == ["inventory"]:
        inventory()
    elif len(sys.argv) == 3 and sys.argv[1] == "apk":
        apk_verify(Path(sys.argv[2]))
    else:
        raise SystemExit("Usage: verify_unsigned_release.py inventory | apk PATH")
