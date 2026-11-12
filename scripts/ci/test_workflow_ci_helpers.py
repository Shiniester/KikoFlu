from collections import Counter
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/ci"))

from build_test_scope import requires_build_for_paths, requires_build_for_push
from run_flutter_test_shard import discover_test_files, select_test_shard


class BuildScopeTests(unittest.TestCase):
    def test_skips_only_document_changes_outside_packaged_assets(self):
        self.assertFalse(
            requires_build_for_paths(
                [
                    "docs/development/evidence.json",
                    "docs/development/build-log.txt",
                    "third_party/package/README.md",
                    "README",
                ]
            )
        )
        self.assertTrue(requires_build_for_paths(["assets/manual.md"]))
        self.assertTrue(requires_build_for_paths(["LICENSE"]))
        self.assertTrue(requires_build_for_paths(["third_party/package/LICENSE"]))
        self.assertTrue(requires_build_for_paths(["docs/development/check.dart"]))
        self.assertTrue(requires_build_for_paths(["docs/workflow-example.yml"]))
        self.assertTrue(requires_build_for_paths(["README.dart"]))
        self.assertTrue(requires_build_for_paths([]))

    def test_git_range_covers_multiple_commits(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            self.run_git(repository, "init", "-q")
            self.run_git(repository, "config", "user.name", "CI Test")
            self.run_git(repository, "config", "user.email", "ci@example.invalid")
            (repository / "app.dart").write_text("base\n", encoding="utf-8")
            self.commit(repository, "base")
            before = self.run_git(repository, "rev-parse", "HEAD").stdout.strip()

            (repository / "docs").mkdir()
            (repository / "docs" / "guide with spaces.json").write_text(
                "{}\n", encoding="utf-8"
            )
            (repository / "docs" / "historical log.txt").write_text(
                "build evidence\n", encoding="utf-8"
            )
            self.commit(repository, "docs evidence")
            (repository / "README.md").write_text("Read me\n", encoding="utf-8")
            self.commit(repository, "readme")
            after = self.run_git(repository, "rev-parse", "HEAD").stdout.strip()
            self.assertFalse(requires_build_for_push(before, after, repository))
            self.assertTrue(requires_build_for_push(after, after, repository))

            (repository / "app.dart").write_text("changed\n", encoding="utf-8")
            self.commit(repository, "app change")
            changed = self.run_git(repository, "rev-parse", "HEAD").stdout.strip()
            self.assertTrue(requires_build_for_push(before, changed, repository))

    def test_unknown_or_empty_push_range_builds(self):
        self.assertTrue(requires_build_for_push("0" * 40, "1" * 40))
        self.assertTrue(requires_build_for_push("1" * 40, "2" * 40))

    @staticmethod
    def run_git(repository, *args):
        return subprocess.run(
            ["git", *args],
            cwd=repository,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    @classmethod
    def commit(cls, repository, message):
        cls.run_git(repository, "add", "--all")
        cls.run_git(repository, "commit", "-qm", message)


class TestShardTests(unittest.TestCase):
    def test_current_flutter_test_files_are_partitioned_once(self):
        files = discover_test_files(ROOT)
        self.assertTrue(files)
        shards = [select_test_shard(files, shard, 2) for shard in range(2)]
        combined = [path for shard in shards for path in shard]
        self.assertEqual(Counter(files), Counter(combined))


@unittest.skipUnless(shutil.which("bash"), "Bash is required for the emulator wrapper test.")
class EmulatorWrapperTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.output = self.root / "diagnostics"
        self.adb_calls = self.root / "adb-calls.txt"
        self.flutter_calls = self.root / "flutter-calls.txt"
        self.write_command(
            "adb",
            """#!/usr/bin/env bash
printf '%s\\n' \"$*\" >> \"$ADB_CALLS\"
if [[ \"$1\" == logcat && \" $* \" == *\" -d \"* ]]; then
  echo final-log
elif [[ \"$1\" == logcat ]]; then
  while true; do
    echo streamed-log
    sleep 0.01
  done
elif [[ \"$1\" == devices ]]; then
  echo emulator-5554
else
  echo diagnostics
fi
""",
        )

    def tearDown(self):
        self.directory.cleanup()

    def test_failure_captures_diagnostics_and_preserves_exit_code(self):
        self.write_flutter("sleep 0.05\nexit \"$FLUTTER_EXIT_CODE\"\n")
        result = self.run_wrapper("9")
        self.assertEqual(9, result.returncode)
        self.assertIn("streamed-log", (self.output / "logcat-live.txt").read_text())
        self.assertIn("final-log", (self.output / "logcat-final.txt").read_text())
        self.assertIn("diagnostics", (self.output / "activities.txt").read_text())

    def test_success_returns_zero_without_failure_dumps(self):
        self.write_flutter("sleep 0.05\nexit 0\n")
        result = self.run_wrapper("0")
        self.assertEqual(0, result.returncode)
        self.assertTrue((self.output / "logcat-live.txt").is_file())
        self.assertFalse((self.output / "activities.txt").exists())

    def test_term_is_nonzero_and_captures_diagnostics(self):
        self.write_flutter('kill -TERM "$PPID"\nexit 0\n')
        result = self.run_wrapper("0")
        self.assertEqual(143, result.returncode)
        self.assertTrue((self.output / "activities.txt").is_file())

    def write_flutter(self, body):
        self.write_command(
            "flutter",
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" > \"$FLUTTER_CALLS\"\n"
            + body,
        )

    def write_command(self, name, contents):
        command = self.bin / name
        command.write_text(contents, encoding="utf-8")
        command.chmod(0o755)

    def run_wrapper(self, failure_code):
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin}{os.pathsep}{environment['PATH']}",
                "RUNNER_TEMP": str(self.root),
                "ADB_CALLS": str(self.adb_calls),
                "FLUTTER_CALLS": str(self.flutter_calls),
                "FLUTTER_EXIT_CODE": failure_code,
            }
        )
        return subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/ci/run_android_emulator_test.sh"),
                str(self.output),
                "--",
                "flutter",
                "test",
                "--no-pub",
                "-d",
                "emulator-5554",
            ],
            cwd=ROOT,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


if __name__ == "__main__":
    unittest.main()
