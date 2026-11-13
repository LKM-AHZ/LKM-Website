import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "submodule_pointers", Path(__file__).parents[1] / "scripts/check_submodule_pointers.py"
)
checker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = checker
spec.loader.exec_module(checker)


class PointerTests(unittest.TestCase):
    def test_index_and_configuration_must_match_without_head_or_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            sha = "a" * 40
            subprocess.run(
                ["git", "update-index", "--add", "--cacheinfo", f"160000,{sha},desktop"],
                cwd=root, check=True,
            )
            config = root / ".gitmodules"
            config.write_text('[submodule "service"]\npath = service\nurl = https://github.com/example/service.git\n')
            with patch.object(checker, "REPO_ROOT", root):
                with self.assertRaisesRegex(ValueError, "没有 gitlink"):
                    checker._pointers()
                config.write_text('[submodule "desktop"]\npath = desktop\nurl = https://github.com/example/desktop.git\n')
                self.assertEqual(checker._pointers()[0].sha, sha)
                subprocess.run(
                    ["git", "update-index", "--add", "--cacheinfo", f"160000,{sha},unmapped"],
                    cwd=root, check=True,
                )
                with self.assertRaisesRegex(ValueError, "unmapped"):
                    checker._pointers()


if __name__ == "__main__":
    unittest.main()
