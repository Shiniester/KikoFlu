from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
SHA_PATTERN = re.compile(r"[0-9a-fA-F]{40}\Z")


def is_document(path):
    path = path.replace("\\", "/")
    if path.startswith("assets/"):
        return False
    name = path.rsplit("/", 1)[-1]
    name_lower = name.lower()
    if name_lower.startswith("license"):
        return False
    if path.startswith("docs/") and path.lower().endswith((".json", ".txt")):
        return True
    if path.startswith("docs/") and path.lower().endswith((".md", ".mdx")):
        return True
    return path.lower().endswith((".md", ".mdx")) or name_lower == "readme"


def requires_build_for_paths(paths):
    return not paths or any(not is_document(path) for path in paths)


def requires_build_for_push(before, after, repository=ROOT):
    if not SHA_PATTERN.fullmatch(before) or not SHA_PATTERN.fullmatch(after):
        return True
    if set(before) == {"0"}:
        return True

    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", "--no-renames", f"{before}..{after}"],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        return True

    paths = [path.decode("utf-8", errors="surrogateescape") for path in result.stdout.split(b"\0") if path]
    return requires_build_for_paths(paths)


def main():
    if len(sys.argv) != 3:
        print("build_required=true")
        return 0
    before, after = sys.argv[1:]
    required = requires_build_for_push(before, after)
    print(f"build_required={str(required).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
