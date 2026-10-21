#!/usr/bin/env python3
"""Exercise CLI preservation and configuration without starting Wine."""
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

exe = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="zmd cli ") as temporary:
    root = Path(temporary)
    app = root / "example app.app"
    support = app / "Contents/SharedSupport"
    (support / "scripts").mkdir(parents=True)
    shutil.copy2(Path(__file__).parent / "wine.sh", support / "scripts/wine.sh")
    shutil.copy2(Path(__file__).parent / "prepare-metalfx.sh", support / "scripts/prepare-metalfx.sh")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.zmdmac.endfield.test",
    }))
    marker = app / "do not overwrite"
    marker.write_text("keep")
    result = subprocess.run([exe, "install", "--output", str(app)], capture_output=True)
    assert result.returncode != 0 and marker.read_text() == "keep"
    result = subprocess.run([exe, "install", "--region", "invalid", "--output", str(root / "invalid.app")], capture_output=True)
    assert result.returncode != 0 and b"--region" in result.stderr
    assert not (root / "invalid.app").exists()
    result = subprocess.run([exe, "install", "--region", "global", "--output", str(app)], capture_output=True)
    assert result.returncode != 0 and marker.read_text() == "keep"
    subprocess.run([exe, "configure", "--app", str(app), "--renderer", "dxmt",
                    "--hud", "on", "--msync", "off", "--window", "windowed"], check=True)
    report = json.loads(subprocess.check_output([exe, "inspect", "--app", str(app)]))
    assert (report["renderer"], report["metal_hud"], report["msync"]) == ("dxmt", "on", "off")
    assert report["settings_window"] == "on"
    subprocess.run([exe, "configure", "--app", str(app), "--settings-window", "off"], check=True)
    report = json.loads(subprocess.check_output([exe, "inspect", "--app", str(app)]))
    assert report["settings_window"] == "off" and report["renderer"] == "dxmt"
    result = subprocess.run([exe, "configure", "--app", str(app), "--settings-window", "invalid",
                             "--renderer", "vulkan"], capture_output=True)
    assert result.returncode != 0 and (support / "settings-window.conf").read_text() == "off\n"
    # A later invalid destination must not leave an earlier setting changed.
    (support / "metal-hud.conf").unlink()
    (support / "metal-hud.conf").mkdir()
    result = subprocess.run([exe, "configure", "--app", str(app), "--renderer", "dxmt",
                             "--msync", "on", "--hud", "off"], capture_output=True)
    assert result.returncode != 0 and (support / "msync.conf").read_text() == "off\n"
    (support / "metal-hud.conf").rmdir()
    (support / "metal-hud.conf").write_text("on\n")
    result = subprocess.run([exe, "configure", "--app", str(app), "--hud", "bogus"],
                            capture_output=True)
    assert result.returncode != 0
    assert (support / "metal-hud.conf").read_text() == "on\n"
    wrapper = support / "scripts/wine.sh"
    current_wrapper = wrapper.read_text()
    wrapper.write_text("#!/bin/bash\n# legacy wrapper\n")
    result = subprocess.run([exe, "configure", "--app", str(app), "--hud", "off"],
                            capture_output=True)
    assert result.returncode != 0
    assert (support / "metal-hud.conf").read_text() == "on\n"
    wrapper.write_text(current_wrapper)
    macos = app / "Contents/MacOS"
    macos.mkdir()
    shutil.copy2(Path(__file__).parent / "app-launch.sh", macos / "launch.sh")
    # Resolution defaults preserve game choice; input validation is atomic.
    for size in ["1920x1080", "3840x2160", "3440x1440", "game"]:
        subprocess.run([exe, "configure", "--app", str(app), "--resolution", size,
                        "--window", "fullscreen"], check=True)
        report = json.loads(subprocess.check_output([exe, "inspect", "--app", str(app)]))
        assert report["resolution"] == size and report["window"] == "fullscreen"
    for size in ["0x0", "03120x1440", "99999x1080", "1920x1080 -bad", "1920x1080;touch nope", "hello", "-1x1080"]:
        result = subprocess.run([exe, "configure", "--app", str(app), "--resolution", size,
                                 "--hud", "off"], capture_output=True)
        assert result.returncode != 0 and (support / "metal-hud.conf").read_text() == "on\n"
    # A legacy launcher must reject new options before writing any config.
    current_launch = (macos / "launch.sh").read_text()
    (macos / "launch.sh").write_text("#!/bin/bash\n")
    result = subprocess.run([exe, "configure", "--app", str(app), "--resolution", "1920x1080"], capture_output=True)
    assert result.returncode != 0 and (support / "resolution.conf").read_text() == "game\n"
    (macos / "launch.sh").write_text(current_launch)
    # Reject an unavailable test backend before changing any requested setting.
    result = subprocess.run([exe, "configure", "--app", str(app), "--renderer",
                             "dxmt-metalfx", "--hud", "off"], capture_output=True)
    assert result.returncode != 0
    assert (support / "renderer.conf").read_text() == "dxmt\n"
    assert (support / "metal-hud.conf").read_text() == "on\n"
    # Verify shell environment against a fake executable, not a real game.
    runtime = support / "runtime/wine/bin"
    runtime.mkdir(parents=True)
    wine = runtime / "wine"
    wine.write_text('#!/bin/bash\nprintf "%s:%s:%s" "$WINEMSYNC" "$MTL_HUD_ENABLED" "$WINEPREFIX"\n')
    wine.chmod(0o755)
    shutil.copy2(Path(__file__).parent / "wine.sh", support / "scripts/wine.sh")
    result = subprocess.check_output(["bash", str(support / "scripts/wine.sh")], text=True)
    assert result == "0:1:" + str(support / "prefix")
    patched = support / "runtime/renderers/dxmt-metalfx"
    (patched / "x86_64-windows").mkdir(parents=True)
    (patched / "x86_64-windows/nvngx.dll").touch()
    (patched / "x86_64-windows/nvapi64.dll").touch()
    (patched / "provenance.json").write_text('{"version":"test"}')
    vulkan = support / "runtime/renderers/moltenvk"
    vulkan.mkdir()
    (vulkan / "libMoltenVK.dylib").touch()
    wine.write_text('#!/bin/bash\nprintf "%s:%s:%s|%s" "${DXMT_ENABLE_NVEXT-unset}" "$WINEDLLPATH_DXMT" "${CX_LIBVULKAN-unset}" "$WINEDLLOVERRIDES"\n')
    subprocess.run([exe, "configure", "--app", str(app), "--renderer", "dxmt-metalfx"], check=True)
    result = subprocess.check_output(["bash", str(wrapper)], text=True)
    defaults = "winemenubuilder.exe=d;mscoree,mshtml="
    assert result == "1:" + str(patched) + ":unset|" + defaults + ";nvngx=b;sl.dlss_g,sl.dlss_d,sl.deepdvc=d"
    report = json.loads(subprocess.check_output([exe, "inspect", "--app", str(app)]))
    assert report["dxmt_metalfx"]["version"] == "test"
    subprocess.run([exe, "configure", "--app", str(app), "--renderer", "vulkan"], check=True)
    import os
    result = subprocess.check_output(["bash", str(wrapper)], text=True,
                                     env={**os.environ, "DXMT_ENABLE_NVEXT": "1"})
    assert result == "unset:" + str(support / "runtime/renderers/dxmt") + ":" + str(vulkan / "libMoltenVK.dylib") + "|" + defaults
    # A missing experimental library must not partially change renderer/queue.
    result = subprocess.run([exe, "configure", "--app", str(app), "--moltenvk", "experimental",
                             "--vulkan-queue", "async"], capture_output=True)
    assert result.returncode != 0 and not (support / "vulkan-queue.conf").exists()
    experimental = support / "runtime/renderers/moltenvk-experimental"
    experimental.mkdir()
    (experimental / "libMoltenVK.dylib").touch()
    (experimental / "provenance.json").write_text('{"version":"experimental-test"}')
    wine.write_text('#!/bin/bash\nprintf "%s|%s" "${CX_LIBVULKAN-unset}" "${MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS-unset}"\n')
    for channel, directory in [("stable", vulkan), ("experimental", experimental)]:
        for queue, expected in [("default", "1"), ("async", "0")]:
            subprocess.run([exe, "configure", "--app", str(app), "--moltenvk", channel,
                            "--vulkan-queue", queue], check=True)
            result = subprocess.check_output(["bash", str(wrapper)], text=True,
                env={**os.environ, "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "garbage"})
            assert result == str(directory / "libMoltenVK.dylib") + "|" + expected
    subprocess.run([exe, "configure", "--app", str(app), "--renderer", "dxmt"], check=True)
    assert subprocess.check_output(["bash", str(wrapper)], text=True,
        env={**os.environ, "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "0"}) == "unset|unset"
    subprocess.run([exe, "configure", "--app", str(app), "--renderer", "vulkan",
                    "--moltenvk", "stable", "--vulkan-queue", "default"], check=True)
    assert subprocess.check_output(["bash", str(wrapper)], text=True) == str(vulkan / "libMoltenVK.dylib") + "|1"
    report = json.loads(subprocess.check_output([exe, "inspect", "--app", str(app)]))
    assert report["moltenvk_channel"] == "stable" and report["vulkan_queue"] == "default"
    assert report["moltenvk_experimental"]["version"] == "experimental-test"
    for file in ["moltenvk.conf", "vulkan-queue.conf"]:
        path = support / file
        previous = path.read_text()
        path.write_text("invalid\n")
        result = subprocess.run(["bash", str(wrapper)], capture_output=True)
        assert result.returncode == 2 and not result.stdout
        path.write_text(previous)
    wine.write_text('#!/bin/bash\nprintf "%s|%s|%s|%s|%s" "$WINEDEBUG" "${DXMT_LOG_LEVEL-unset}" "${DXMT_SHADER_CACHE-unset}" "${MTL_DEBUG_LAYER-unset}" "${MTL_SHADER_VALIDATION-unset}"\n')
    subprocess.run([exe, "configure", "--app", str(app), "--dxmt-log", "debug", "--wine-log", "warnings",
                    "--shader-cache", "off", "--metal-validation", "on", "--shader-validation", "on"], check=True)
    assert subprocess.check_output(["bash", str(wrapper)], text=True) == "-all,err+all,warn+all|debug|0|1|1"
    subprocess.run([exe, "configure", "--app", str(app), "--dxmt-log", "default", "--wine-log", "off",
                    "--shader-cache", "on", "--metal-validation", "off", "--shader-validation", "off"], check=True)
    assert subprocess.check_output(["bash", str(wrapper)], text=True,
                                   env={**os.environ, "DXMT_LOG_LEVEL": "debug", "MTL_DEBUG_LAYER": "1"}) == "-all|unset|1|0|0"
    (support / "shader-cache.conf").write_text("invalid\n")
    result = subprocess.run(["bash", str(wrapper)], capture_output=True)
    assert result.returncode == 2 and not result.stdout
    print("PASS: preserve apps, configuration preflight, startup preference, debug environment, HUD/MSync and renderer rollback")

with tempfile.TemporaryDirectory(prefix="zmd display ") as temporary:
    app = Path(temporary) / "Display.app"
    macos = app / "Contents/MacOS"
    support = app / "Contents/SharedSupport"
    macos.mkdir(parents=True)
    (support / "scripts").mkdir(parents=True)
    (support / "runtime/wine/bin").mkdir(parents=True)
    shutil.copy2(Path(__file__).parent / "app-launch.sh", macos / "launch.sh")
    (support / "scripts/prepare-metalfx.sh").write_text("#!/bin/bash\nexit 0\n")
    (support / "scripts/wine.sh").write_text('#!/bin/bash\nif [ "$1" = reg ]; then printf "%s\\n" "$@" > captured-args; fi\n')
    server = support / "runtime/wine/bin/wineserver"
    server.write_text("#!/bin/bash\nexit 0\n")
    server.chmod(0o755)
    (support / "renderer.conf").write_text("vulkan\n")
    for mode, suffix in [("game", ""), ("windowed", " -screen-fullscreen 0"),
                         ("fullscreen", " -screen-fullscreen 1 -window-mode borderless")]:
        (support / "window-mode.conf").write_text(mode + "\n")
        for size in ["game", "3840x2160"]:
            (support / "resolution.conf").write_text(size + "\n")
            subprocess.run(["bash", str(macos / "launch.sh")], check=True)
            args = (support / "captured-args").read_text().splitlines()
            flags = args[args.index("/d") + 1]
            expected = "-force-vulkan" + suffix + (" -screen-width 3840 -screen-height 2160" if size != "game" else "")
            assert flags == expected, (flags, expected)
    (support / "resolution.conf").write_text("1920x1080; touch injected\n")
    (support / "captured-args").unlink()
    result = subprocess.run(["bash", str(macos / "launch.sh")], capture_output=True)
    assert result.returncode == 2 and not (support / "captured-args").exists()
print("PASS: display modes, resolution arguments, validation and game-settings fallback")
