from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]


def discover_test_files(repository=ROOT):
    return sorted(
        path.relative_to(repository).as_posix()
        for path in (repository / "test").rglob("*_test.dart")
        if path.is_file()
    )


def select_test_shard(files, shard, total):
    return [path for index, path in enumerate(files) if index % total == shard]


def main():
    if len(sys.argv) != 3:
        print("Usage: run_flutter_test_shard.py SHARD TOTAL", file=sys.stderr)
        return 2

    try:
        shard, total = (int(value) for value in sys.argv[1:])
    except ValueError:
        print("SHARD and TOTAL must be integers.", file=sys.stderr)
        return 2
    if total < 1 or shard < 0 or shard >= total:
        print("SHARD must be in [0, TOTAL).", file=sys.stderr)
        return 2

    files = discover_test_files()
    selected = select_test_shard(files, shard, total)
    if not selected:
        print(f"No Flutter test files found for shard {shard}/{total}.", file=sys.stderr)
        return 1

    return subprocess.run(
        ["flutter", "test", "--exclude-tags", "external", *selected],
        cwd=ROOT,
        check=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
