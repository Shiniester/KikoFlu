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


def requires_build_for_push(before, after, repository=ROOT, *, branch_base=None):
    if not SHA_PATTERN.fullmatch(before) or not SHA_PATTERN.fullmatch(after):
        return True

    ranges = [] if set(before) == {"0"} else [f"{before}..{after}"]
    if branch_base is not None:
        ranges.append(f"{branch_base}...{after}")
    if not ranges:
        return True

    for revision_range in ranges:
        result = subprocess.run(
            ["git", "diff", "--name-only", "-z", "--no-renames", revision_range, "--"],
            cwd=repository,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0:
            return True

        paths = [path.decode("utf-8", errors="surrogateescape") for path in result.stdout.split(b"\0") if path]
        if requires_build_for_paths(paths):
            return True
    return False


def main():
    if len(sys.argv) not in (3, 4):
        print("build_required=true")
        return 0
    before, after = sys.argv[1:3]
    branch_base = sys.argv[3] if len(sys.argv) == 4 else None
    required = requires_build_for_push(before, after, branch_base=branch_base)
    print(f"build_required={str(required).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
