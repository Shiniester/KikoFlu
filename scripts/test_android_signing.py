from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = (
    ".github/workflows/build.yml",
    ".github/workflows/build_android.yml",
    ".github/workflows/build_test_only.yml",
)


def expected_certificate(workflow):
    source = (ROOT / workflow).read_text(encoding="utf-8")
    matches = re.findall(
        r"^\s*EXPECTED_CERT_SHA256:\s*([0-9a-f]{64})\s*$",
        source,
        re.MULTILINE,
    )
    assert len(matches) == 1, f"{workflow} must declare one Android certificate expectation"
    return matches[0]


certificates = {workflow: expected_certificate(workflow) for workflow in WORKFLOWS}
assert len(set(certificates.values())) == 1, (
    "Android build workflows must verify the same release certificate: "
    f"{certificates}"
)

test_workflow = (ROOT / WORKFLOWS[-1]).read_text(encoding="utf-8")
assert 'apksigner" verify --print-certs "$apk"' in test_workflow
assert 'if [ "$actual_cert" != "$EXPECTED_CERT_SHA256" ]; then' in test_workflow
