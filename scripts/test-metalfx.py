#!/usr/bin/env python3
"""Verify prefix entry preparation and rollback without Wine or game files."""
import os
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).with_name("prepare-metalfx.sh").resolve()
with tempfile.TemporaryDirectory(prefix="zmd ngx ") as directory:
    prefix = Path(directory)
    target = prefix / "drive_c/windows/system32/nvngx.dll"
    game = prefix / "drive_c/EndfieldLauncher/games/Arknights Endfield/nvngx_dlss.dll"
    state = prefix / ".zmd-metalfx-ngx"
    target.parent.mkdir(parents=True)
    game.parent.mkdir(parents=True)

    def run(mode="dxmt-metalfx", success=True):
        result = subprocess.run(["bash", str(script), mode], capture_output=True,
                                env={**os.environ, "ZMD_PREFIX": str(prefix)})
        assert (result.returncode == 0) == success, result.stderr.decode()

    # Before downloading the game, opening the launcher still works.
    target.write_bytes(b"original")
    run()
    assert target.read_bytes() == b"original" and not state.exists()
    game.write_bytes(b"signed fixture")
    run()
    run()
    assert target.read_bytes() == game.read_bytes()
    assert (state / "original.dll").read_bytes() == b"original"
    # A game update refreshes the entry while keeping the original backup.
    game.write_bytes(b"updated signed fixture")
    run()
    assert target.read_bytes() == game.read_bytes()
    run("vulkan")
    assert target.read_bytes() == b"original" and not state.exists()
    assert game.read_bytes() == b"updated signed fixture"
    # Another tool's change is preserved instead of silently overwritten.
    run()
    target.write_bytes(b"external")
    run("vulkan", success=False)
    assert target.read_bytes() == b"external" and state.exists()
    target.write_bytes(game.read_bytes())
    backup = state / "original.dll"
    backup.rename(state / "held")
    run("dxmt", success=False)
    (state / "held").rename(backup)
    run("dxmt")
    # A target symlink must not cause a write into the shared runtime.
    original = prefix / "runtime-original.dll"
    original.write_bytes(b"runtime")
    target.unlink()
    target.symlink_to(original)
    run()
    assert not target.is_symlink() and original.read_bytes() == b"runtime"
    run("vulkan")
    assert target.read_bytes() == b"runtime" and original.read_bytes() == b"runtime"
    # Restore an originally absent entry, including after game removal.
    target.unlink()
    run()
    game.unlink()
    run()
    assert not target.exists() and not state.exists()
    global_game = prefix / "drive_c/EndfieldLauncher/games/EndField Game/nvngx_dlss.dll"
    global_game.parent.mkdir(parents=True)
    global_game.write_bytes(b"global signed fixture")
    run()
    assert target.read_bytes() == global_game.read_bytes()
    run("vulkan")
    assert not target.exists() and global_game.read_bytes() == b"global signed fixture"
print("PASS: NGX entry prepare, update, rollback, missing game and external-change preservation")
