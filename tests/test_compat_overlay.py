import hashlib
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("compat_overlay", Path(__file__).resolve().parents[1] / "port/r36sporthub/bin/compat_overlay.py")
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)


class OverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "stage"
        self.game = self.stage / "ducktales"
        self.game.mkdir(parents=True)
        self.dest = self.root / "ports with spaces"
        self.libs = self.root / "libs"
        self.libs.mkdir()
        header = bytearray(20)
        header[:6] = b"\x7fELF\x01\x01"
        header[18] = 40
        (self.libs / "libmali.so").write_bytes(header)
        self.archive = self.root / "runtime.zip"

    def package(self, extra=None):
        with zipfile.ZipFile(self.archive, "w") as z:
            z.writestr(overlay.LAUNCHER, "#!/bin/sh\necho official\n")
            z.writestr("ducktales/runtime/ducktales", b"\x7fELFnative")
            z.writestr("ducktales/defaults/NEXTOSSETTINGS.txt", "quality=auto\n")
            z.writestr("ducktales/gamedata/owner.apk", "must not overwrite")
            if extra:
                z.writestr(*extra)
        return hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def apply(self, sha):
        return overlay.apply_overlay(self.archive, self.stage, self.dest, sha, self.libs)

    def test_new_install_preserves_data_and_uses_single_gpu_object(self):
        data = self.game / "gamedata"
        data.mkdir()
        (data / "owner.apk").write_bytes(b"original")
        sha = self.package()
        self.apply(sha)
        self.assertEqual((data / "owner.apk").read_bytes(), b"original")
        self.assertEqual((self.game / "NEXTOSSETTINGS.txt").read_text(), "quality=low\n")
        launcher = (self.stage / overlay.LAUNCHER).read_text()
        assignments = [line.split("=", 1)[1] for line in launcher.splitlines() if line.startswith(("export SDL_VIDEO_EGL_DRIVER=", "export SDL_VIDEO_GL_DRIVER="))]
        self.assertEqual(len(assignments), 2)
        self.assertEqual(assignments[0], assignments[1])
        self.assertEqual((self.game / "runtime/lib/libGLESv2.so.2").read_bytes(), (self.libs / "libmali.so").read_bytes())
        self.apply(sha)
        self.assertEqual((self.stage / overlay.LAUNCHER).read_text().count(overlay.MARKER), 1)

    def test_reinstall_keeps_existing_settings_and_saves(self):
        installed = self.dest / "ducktales"
        (installed / "saves").mkdir(parents=True)
        (installed / "saves/slot1").write_text("save")
        (installed / "NEXTOSSETTINGS.txt").write_text("quality=custom\n")
        (self.game / "saves").mkdir()
        (self.game / "saves/slot1").write_text("packaged")
        (self.game / "NEXTOSSETTINGS.txt").write_text("quality=auto\n")
        self.apply(self.package())
        self.assertFalse((self.game / "saves").exists())
        self.assertFalse((self.game / "NEXTOSSETTINGS.txt").exists())
        self.assertEqual((installed / "saves/slot1").read_text(), "save")
        self.assertEqual((installed / "NEXTOSSETTINGS.txt").read_text(), "quality=custom\n")

    def test_wrong_hash_leaves_stage_untouched(self):
        self.package()
        with self.assertRaises(ValueError):
            self.apply("0" * 64)
        self.assertEqual(list(self.game.iterdir()), [])

    def test_unsafe_archive_paths_rejected_before_writes(self):
        for path in ["../escape", "/escape", "other/file", "ducktales/../../escape"]:
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    self.apply(self.package((zipfile.ZipInfo(path), "bad")))
                self.assertEqual(list(self.game.iterdir()), [])

    def test_symlink_archive_rejected(self):
        info = zipfile.ZipInfo("ducktales/link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(ValueError):
            self.apply(self.package((info, "../../escape")))

    def test_wrong_architecture_rejected(self):
        (self.libs / "libmali.so").write_bytes(b"\x7fELF\x02" + b"\0" * 20)
        with self.assertRaises(ValueError):
            self.apply(self.package())
        self.assertEqual(list(self.game.iterdir()), [])

    def strikers_package(self, extra=False):
        binary = bytearray(32)
        binary[:6] = b"\x7fELF\x02\x01"
        binary[18] = 183
        with zipfile.ZipFile(self.archive, "w") as z:
            z.writestr("strikers", binary)
            if extra:
                z.writestr("../escape", "bad")
        return overlay.digest(self.archive), bytes(binary)

    def test_strikers_runtime_backup_and_data_preservation(self):
        game = self.stage / "strikers"
        game.mkdir()
        (game / "strikers").write_bytes(b"old-staged")
        (game / "owner-data").write_bytes(b"game-data")
        installed = self.dest / "strikers"
        installed.mkdir(parents=True)
        (installed / "strikers").write_bytes(b"old-installed")
        (installed / "save.gci").write_bytes(b"save")
        sha, binary = self.strikers_package()
        backup = self.root / "backup"
        overlay.apply_strikers_overlay(self.archive, self.stage, self.dest, sha, backup)
        self.assertEqual((game / "strikers").read_bytes(), binary)
        self.assertEqual((game / "owner-data").read_bytes(), b"game-data")
        self.assertEqual((installed / "save.gci").read_bytes(), b"save")
        self.assertEqual(next(backup.rglob("strikers/strikers")).read_bytes(), b"old-installed")

    def test_strikers_rejects_tampered_and_extra_members(self):
        (self.stage / "strikers").mkdir()
        sha, _ = self.strikers_package()
        with self.assertRaises(ValueError):
            overlay.apply_strikers_overlay(self.archive, self.stage, self.dest, "0" * 64)
        sha, _ = self.strikers_package(extra=True)
        with self.assertRaises(ValueError):
            overlay.apply_strikers_overlay(self.archive, self.stage, self.dest, sha)
        self.assertFalse((self.stage / "strikers/strikers").exists())


if __name__ == "__main__":
    unittest.main()
