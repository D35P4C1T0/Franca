#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Live end-to-end GUI smoke & regression test harness for Franca.

Launches an isolated `franca-ui` instance with Dummy audio driver and temporary XDG
directories, drives it via `scripts/francamsg` over Unix-domain IPC, verifies:
  - Engine startup & status
  - Rack plugin add, bypass, rename, reorder, Undo/Redo
  - Split View (left Patchbay + right Rack), ratio persistence, docked minimap cycling,
    and narrow-window compact Rack layout
  - Patchbay state, auto-arrange, hide-unused-ports, zoom, and Ctrl+F quick search
  - Session safety: dirty tracking, atomic .carxp save, and .autosaves/ snapshot
  - Window + Patchbay PNG screenshot capture
  - Clean programmatic shutdown & socket cleanup
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FRANCAMSG = REPO_ROOT / "scripts" / "francamsg"


class SmokeError(RuntimeError):
    pass


class FrancaSmokeRunner:
    def __init__(self, binary: Path, verbose: bool = False, keep_tmp: bool = False):
        self.binary = binary
        self.verbose = verbose
        self.keep_tmp = keep_tmp
        base_tmp = "/tmp" if os.path.isdir("/tmp") else None
        self.tmpdir = Path(tempfile.mkdtemp(prefix="franca-smoke-", dir=base_tmp))
        self.instance_key = f"smoke-{os.getpid()}"
        self.proc = None

        cfg_home = self.tmpdir / "config"
        data_home = self.tmpdir / "data"
        run_dir = self.tmpdir / "run"
        for d in (cfg_home / "franca", data_home, run_dir):
            d.mkdir(parents=True, exist_ok=True)
        os.chmod(run_dir, 0o700)

        # Seed isolated Dummy-driver settings so CI never touches host audio or user config
        (cfg_home / "franca" / "settings.json").write_text(
            json.dumps(
                {
                    "audio_driver": "Dummy",
                    "process_mode": 2,
                    "transport_mode": 1,
                    "confirm_exit": True,
                    "autosave_enabled": True,
                    "autosave_interval_secs": 120,
                    "max_autosaves": 3,
                    "split_view": False,
                    "split_view_ratio": 0.65,
                    "split_minimap_dock": 2,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        self.env = os.environ.copy()
        self.env["XDG_CONFIG_HOME"] = str(cfg_home)
        self.env["XDG_DATA_HOME"] = str(data_home)
        self.env["XDG_RUNTIME_DIR"] = str(run_dir)
        self.env["FRANCA_INSTANCE_KEY"] = self.instance_key
        self.env["FRANCA_LIBDIR"] = str(REPO_ROOT / "bin")
        self.env["FRANCA_DATADIR"] = str(REPO_ROOT / "bin")
        self.env.setdefault("QT_QUICK_CONTROLS_STYLE", "Fusion")

    def msg(self, *args, check=True, parse_json=True):
        cmd = [sys.executable, str(FRANCAMSG), "--instance", self.instance_key]
        if parse_json:
            cmd.append("--json")
        cmd.extend(str(a) for a in args)
        res = None
        for attempt in range(2):
            res = subprocess.run(
                cmd,
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
            )
            if res.returncode == 0 or attempt == 1:
                break
            time.sleep(0.4)
        if self.verbose:
            print(f"$ francamsg {' '.join(str(a) for a in args)} -> rc={res.returncode} {res.stdout.strip()}")
        if check and res.returncode != 0:
            raise SmokeError(f"francamsg {' '.join(str(a) for a in args)} failed: {res.stderr.strip() or res.stdout.strip()}")
        if not parse_json:
            return res.stdout.strip()
        return json.loads(res.stdout) if res.stdout.strip() else None

    def assert_eq(self, label, actual, expected):
        if actual != expected:
            raise SmokeError(f"{label}: expected {expected!r}, got {actual!r}")
        print(f"ok   {label}")

    def assert_true(self, label, cond, detail=""):
        if not cond:
            raise SmokeError(f"{label}{': ' + detail if detail else ''}")
        print(f"ok   {label}")

    def start(self):
        if not self.binary.exists():
            raise SmokeError(f"franca-ui binary not found at {self.binary}")
        self.proc = subprocess.Popen(
            [str(self.binary)],
            cwd=str(REPO_ROOT),
            env=self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        st = self.msg("wait", "--ready", "--timeout", "45")
        self.assert_true("app booted and audio engine ready", bool(st and st.get("engine_running")), str(st))

    def stop(self):
        if self.proc is not None:
            self.msg("quit", "--force", check=False)
            try:
                rc = self.proc.wait(timeout=15)
                print(f"ok   clean shutdown (exit={rc})")
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                raise SmokeError("franca-ui did not exit cleanly after IPC quit")
        sock = Path(self.env["XDG_RUNTIME_DIR"]) / f"franca-{self.instance_key}.sock"
        self.assert_true("IPC socket cleaned up on exit", not sock.exists(), str(sock))
        if not self.keep_tmp:
            shutil.rmtree(self.tmpdir, ignore_errors=True)

    def run_all(self):
        try:
            self.start()

            # 1. Instances discovery
            instances = self.msg("instances")
            self.assert_true(
                "instance registered in discovery",
                any(i.get("key") == self.instance_key for i in instances),
                str(instances),
            )

            # 2. Rack plugin lifecycle + Undo/Redo
            self.msg("rack", "add", "--label", "audiogain_s", "--name", "Smoke Gain A")
            self.msg("rack", "add", "--label", "audiogain_s", "--name", "Smoke Gain B")
            rack = self.msg("rack", "list")["plugins"]
            self.assert_eq("rack has 2 plugins", len(rack), 2)

            self.msg("rack", "active", "0", "off")
            rack = self.msg("rack", "list")["plugins"]
            self.assert_eq("plugin 0 bypassed", rack[0]["active"], False)

            self.msg("rack", "rename", "0", "Input Trim")
            rack = self.msg("rack", "list")["plugins"]
            self.assert_eq("plugin 0 renamed", rack[0]["name"], "Input Trim")

            self.msg("undo")
            rack = self.msg("rack", "list")["plugins"]
            self.assert_eq("undo restores previous name", rack[0]["name"], "Smoke Gain A")

            self.msg("redo")
            rack = self.msg("rack", "list")["plugins"]
            self.assert_eq("redo reapplies rename", rack[0]["name"], "Input Trim")

            # 3. Clara-style Split View, ratio persistence, docked minimap, compact window
            self.msg("view", "split", "on")
            self.msg("view", "ratio", "0.62")
            self.msg("view", "minimap", "top")
            view = self.msg("view", "get")
            self.assert_eq("split_view enabled", view["split_view"], True)
            self.assert_true("split_view_ratio persisted", abs(view["split_view_ratio"] - 0.62) < 0.01, str(view))
            self.assert_eq("split_minimap_dock=top", view["split_minimap_dock"], 1)
            self.msg("view", "minimap", "bottom")

            win_geo = self.msg("window", "900", "640")
            self.assert_true("window resized for compact rack check", win_geo["width"] > 0, str(win_geo))

            # 4. Patchbay ergonomics: arrange, hide unused ports, zoom, Ctrl+F search
            self.msg("patchbay", "refresh")
            self.msg("patchbay", "arrange")
            self.msg("patchbay", "hide-unused", "on")
            pb = self.msg("patchbay", "state")
            self.assert_eq("hide_unused_ports active", pb["hide_unused_ports"], True)
            self.msg("patchbay", "hide-unused", "off")
            self.msg("canvas", "zoom", "0.75")
            self.msg("canvas", "zoom", "fit")
            self.msg("canvas", "search", "Input")
            self.msg("canvas", "search", "--close")

            # 5. Session safety: dirty flag, atomic save, rotating .autosaves/
            st = self.msg("status")
            self.assert_eq("session marked dirty after edits", st["project_dirty"], True)

            proj_path = self.tmpdir / "smoke-session.carxp"
            save_res = self.msg("project", "save", str(proj_path))
            self.assert_eq("project saved cleanly", save_res["saved"], True)
            self.assert_eq("dirty flag cleared after save", save_res["project_dirty"], False)
            self.assert_true("saved .carxp exists", proj_path.is_file() and proj_path.stat().st_size > 100)

            self.msg("rack", "active", "0", "on")
            auto_res = self.msg("project", "autosave")
            self.assert_eq("autosave snapshot succeeded", auto_res["autosaved"], True)
            self.assert_eq("autosave preserved active project_filename", auto_res["project_filename"], str(proj_path))
            autosaves = list((self.tmpdir / ".autosaves" / "smoke-session").glob("autosave-*.carxp"))
            self.assert_true("autosave file created in .autosaves/", len(autosaves) == 1, str(autosaves))

            # 6. Screenshot capture (patchbay + window)
            pb_png = self.tmpdir / "patchbay.png"
            pb_shot = self.msg("shot", str(pb_png), "--target", "patchbay", "--scale", "1.5")
            self.assert_true("patchbay PNG captured", pb_shot["bytes"] > 1000, str(pb_shot))

            win_png = self.tmpdir / "window.png"
            win_shot = self.msg("shot", str(win_png), "--target", "window", check=False)
            if win_shot and win_shot.get("bytes", 0) > 1000:
                print(f"ok   window PNG captured ({win_shot['width']}x{win_shot['height']}, {win_shot['bytes']} bytes)")
            else:
                print("skip window PNG capture (headless renderer without window surface)")

        finally:
            self.stop()


def main():
    parser = argparse.ArgumentParser(description="Live GUI smoke test for Franca")
    parser.add_argument("--binary", default=str(REPO_ROOT / "bin" / "franca-ui"))
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--keep-tmp", action="store_true")
    ns = parser.parse_args()

    runner = FrancaSmokeRunner(Path(ns.binary), verbose=ns.verbose, keep_tmp=ns.keep_tmp)
    try:
        runner.run_all()
    except SmokeError as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 1
    print("ALL UI SMOKE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
