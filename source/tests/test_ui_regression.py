#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Automated UI regression & contract test suite for Franca (headless, zero-Qt-dep).

Validates:
  1. QML <-> Rust cxx-qt bridge contracts (properties, invokables, signals)
  2. build.rs QML module manifest completeness
  3. UI layout & feature regression contracts (Split View, Compact Rack, Docked Minimap,
     Ctrl+F search, Hide Unused Ports, Save & Quit / Recovery dialogs)
  4. End-to-end `francamsg` IPC protocol tests against a live Unix-domain socket server
"""

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
FRONTEND_RS = REPO_ROOT / "source" / "frontend-rs"
QML_DIR = FRONTEND_RS / "qml"
QT_BRIDGE = FRONTEND_RS / "src" / "qt_bridge.rs"
BUILD_RS = FRONTEND_RS / "build.rs"
FRANCAMSG = REPO_ROOT / "scripts" / "francamsg"


class QmlBridgeContractTests(unittest.TestCase):
    def setUp(self):
        self.qb_text = QT_BRIDGE.read_text(encoding="utf-8")
        self.props = re.findall(r"#\[qproperty\([^,]+,\s*(\w+)\)\]", self.qb_text)
        self.invokables = re.findall(r"#\[qinvokable\]\s*fn\s+(\w+)\s*\(", self.qb_text)
        self.signals = re.findall(r"#\[qsignal\]\s*fn\s+(\w+)\s*\(", self.qb_text)

    def test_every_qproperty_has_rust_field(self):
        struct_body = self.qb_text.split("pub struct FrancaControllerRust {")[1].split("}")[0]
        for prop in self.props:
            self.assertRegex(
                struct_body,
                rf"\b{re.escape(prop)}\s*:",
                f"Missing FrancaControllerRust field for #[qproperty] {prop}",
            )

    def test_every_qinvokable_has_impl_method(self):
        impl_body = self.qb_text.split("impl qobject::FrancaController {")[1]
        prop_setters = {f"set_{p}" for p in self.props}
        for fn in self.invokables:
            self.assertNotIn(
                fn,
                prop_setters,
                f"#[qinvokable] {fn} collides with auto-generated cxx-qt setter for #[qproperty]",
            )
            self.assertRegex(
                impl_body,
                rf"\bpub fn {re.escape(fn)}\b",
                f"Missing impl method for #[qinvokable] {fn}",
            )

    def test_all_qml_controller_references_exist(self):
        known = set(self.props) | set(self.invokables) | set(self.signals)
        for qml in sorted(QML_DIR.glob("*.qml")):
            text = qml.read_text(encoding="utf-8")
            for match in re.finditer(r"\b(?:ctrl|controller)\.(\w+)", text):
                member = match.group(1)
                self.assertIn(
                    member,
                    known,
                    f"{qml.name} references unknown controller member '{member}'",
                )

    def test_build_rs_lists_every_qml_file(self):
        build_txt = BUILD_RS.read_text(encoding="utf-8")
        listed = set(re.findall(r'"(qml/[^"]+\.qml)"', build_txt))
        on_disk = {f"qml/{p.name}" for p in QML_DIR.glob("*.qml")}
        self.assertEqual(
            listed,
            on_disk,
            f"build.rs QML list mismatch: missing={on_disk - listed}, extra={listed - on_disk}",
        )

    def test_qml_delimiters_balanced(self):
        for qml in sorted(QML_DIR.glob("*.qml")):
            txt = qml.read_text(encoding="utf-8")
            cleaned = re.sub(r"//.*", "", txt)
            cleaned = re.sub(r'"(?:\\.|[^"\\])*"', '""', cleaned)
            cleaned = re.sub(r"'(?:\\.|[^'\\])*'", "''", cleaned)
            self.assertEqual(cleaned.count("{"), cleaned.count("}"), f"{qml.name}: unbalanced braces")
            self.assertEqual(cleaned.count("("), cleaned.count(")"), f"{qml.name}: unbalanced parens")


class UiLayoutRegressionContractTests(unittest.TestCase):
    def test_split_view_layout_and_shortcuts(self):
        main_qml = (QML_DIR / "Main.qml").read_text(encoding="utf-8")
        # Patchbay must be declared before Rack inside dualSplit (Clara left=Patchbay, right=Rack)
        split_section = main_qml.split("id: dualSplit")[1]
        pb_pos = split_section.find("PatchbayView {")
        rack_pos = split_section.find("RackView {")
        self.assertGreater(pb_pos, 0, "dualSplit missing PatchbayView")
        self.assertGreater(rack_pos, pb_pos, "PatchbayView must appear left of RackView in dualSplit")
        self.assertIn("split_view_ratio", split_section, "Split ratio must be persisted/restored")
        self.assertIn("syncGuard", main_qml, "Bidirectional focus sync must guard against feedback loops")
        self.assertIn('sequence: "Ctrl+\\\\"', main_qml, "Missing Ctrl+\\ Split View shortcut")
        self.assertIn('sequence: "Ctrl+F"', main_qml, "Missing Ctrl+F node search shortcut")
        self.assertIn("onIpc_ui_action:", main_qml, "Main.qml must handle IPC UI actions")

    def test_rack_compact_mode_and_docked_minimap(self):
        rack_qml = (QML_DIR / "RackView.qml").read_text(encoding="utf-8")
        self.assertIn("compactMode", rack_qml, "RackView must adapt layout for narrow split panes")
        self.assertIn("split_minimap_dock === 1", rack_qml, "Missing top-docked minimap in RackView")
        self.assertIn("split_minimap_dock === 2", rack_qml, "Missing bottom-docked minimap in RackView")
        self.assertIn("smoothScrollAnim", rack_qml, "RackView focusPlugin must animate smooth scroll")

    def test_patchbay_search_and_hide_unused(self):
        pb_qml = (QML_DIR / "PatchbayView.qml").read_text(encoding="utf-8")
        self.assertIn("id: searchOverlay", pb_qml, "Missing Ctrl+F search overlay in PatchbayView")
        self.assertIn("apply_hide_unused_ports", pb_qml, "Missing global hide-unused-ports toggle")
        self.assertIn("patchbay_toggle_group_hide_unused", pb_qml, "Missing per-node hide-unused toggle")

    def test_session_safety_dialogs(self):
        dlg_qml = (QML_DIR / "Dialogs.qml").read_text(encoding="utf-8")
        self.assertIn("file_save_and_check()", dlg_qml, "Save & Quit must verify save succeeded before exit")
        self.assertIn("id: recoveryDialog", dlg_qml, "Missing startup autosave recovery dialog")
        self.assertIn("recover_autosave()", dlg_qml, "Missing recover_autosave action")


class IpcClientProtocolTests(unittest.TestCase):
    """Spins up a real Unix-domain socket mock IPC server and tests scripts/francamsg end-to-end."""

    def setUp(self):
        # Use /tmp directly so AF_UNIX socket paths stay well under the 104-byte macOS limit
        base_tmp = "/tmp" if os.path.isdir("/tmp") else None
        self.tmpdir = tempfile.TemporaryDirectory(prefix="franca-ipc-", dir=base_tmp)
        self.runtime = Path(self.tmpdir.name)
        self.key = "utest"
        self.sock_path = self.runtime / f"franca-{self.key}.sock"
        self.reg_dir = self.runtime / "franca-instances"
        self.reg_dir.mkdir(parents=True, exist_ok=True)
        self.state = {
            "engine_running": True,
            "split_view": False,
            "split_view_ratio": 0.65,
            "split_minimap_dock": 2,
            "hide_unused_ports": False,
            "plugins": [],
        }
        self.received = []
        self.stop_event = threading.Event()
        self.server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_sock.bind(str(self.sock_path))
        self.server_sock.listen(8)
        self.server_sock.settimeout(0.1)

        (self.reg_dir / f"{self.key}.json").write_text(
            json.dumps(
                {
                    "key": self.key,
                    "pid": os.getpid(),
                    "socket": str(self.sock_path),
                    "version": "2.6.0-test",
                    "project": "",
                    "started_unix": int(time.time()),
                }
            ),
            encoding="utf-8",
        )
        # Also drop a stale dead-PID entry to verify pruning
        (self.reg_dir / "stale.json").write_text(
            json.dumps(
                {
                    "key": "stale",
                    "pid": 99999999,
                    "socket": str(self.runtime / "franca-stale.sock"),
                    "version": "2.6.0-test",
                    "project": "",
                    "started_unix": 1,
                }
            ),
            encoding="utf-8",
        )

        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.stop_event.set()
        self.thread.join(timeout=2.0)
        self.server_sock.close()
        self.tmpdir.cleanup()

    def _serve(self):
        while not self.stop_event.is_set():
            try:
                conn, _ = self.server_sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with conn:
                data = conn.recv(65536).decode("utf-8", errors="replace").strip()
                req = json.loads(data)
                cmd = req.get("cmd")
                args = req.get("args") or {}
                self.received.append((cmd, args))
                if cmd == "ping":
                    reply = {"ok": True, "result": {"pong": True, "v": 1}}
                elif cmd == "status":
                    reply = {"ok": True, "result": dict(self.state)}
                elif cmd == "view.set":
                    for k in ("split_view", "split_view_ratio", "split_minimap_dock"):
                        if k in args:
                            self.state[k] = args[k]
                    reply = {"ok": True, "result": dict(self.state)}
                elif cmd == "view.get":
                    reply = {"ok": True, "result": dict(self.state)}
                elif cmd == "patchbay.hide_unused":
                    self.state["hide_unused_ports"] = bool(args.get("enabled"))
                    reply = {"ok": True, "result": {"hide_unused_ports": self.state["hide_unused_ports"]}}
                elif cmd == "settings.get":
                    f = args.get("field")
                    if f == "split_view_ratio":
                        reply = {"ok": True, "result": {"field": f, "value": self.state["split_view_ratio"]}}
                    else:
                        reply = {"ok": False, "error": f"Unknown settings field: {f}"}
                elif cmd == "quit":
                    reply = {"ok": True, "result": {"quitting": True}}
                else:
                    reply = {"ok": False, "error": f"Unknown command: {cmd}"}
                conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))

    def run_msg(self, *args, check=True):
        env = os.environ.copy()
        env["XDG_RUNTIME_DIR"] = str(self.runtime)
        env.pop("FRANCA_INSTANCE_KEY", None)
        proc = subprocess.run(
            [sys.executable, str(FRANCAMSG), *args],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
        if check and proc.returncode != 0:
            self.fail(f"francamsg {args} failed ({proc.returncode}): {proc.stderr}")
        return proc

    def test_instances_discovery_and_stale_pruning(self):
        proc = self.run_msg("--json", "instances")
        items = json.loads(proc.stdout)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["key"], self.key)
        self.assertFalse((self.reg_dir / "stale.json").exists(), "Stale PID registry entry should be pruned")

    def test_wait_status_view_and_error_handling(self):
        self.run_msg("wait", "--ready", "--timeout", "5")
        self.run_msg("view", "split", "on")
        self.run_msg("view", "ratio", "0.58")
        self.run_msg("view", "minimap", "top")
        self.run_msg("patchbay", "hide-unused", "on")

        st = json.loads(self.run_msg("--json", "status").stdout)
        self.assertTrue(st["split_view"])
        self.assertAlmostEqual(st["split_view_ratio"], 0.58, places=2)
        self.assertEqual(st["split_minimap_dock"], 1)
        self.assertTrue(st["hide_unused_ports"])

        # Settings get single field prints plain value
        val = self.run_msg("settings", "get", "split_view_ratio").stdout.strip()
        self.assertEqual(val, "0.58")

        # Unknown field exits non-zero cleanly
        bad = self.run_msg("settings", "get", "does_not_exist", check=False)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("Unknown settings field", bad.stderr)

        # Quit command succeeds
        q = json.loads(self.run_msg("--json", "quit", "--force").stdout)
        self.assertTrue(q["quitting"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
