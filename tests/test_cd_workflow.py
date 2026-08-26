from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cd-vps-cis.yml"


class CheckoutIntegrityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW.read_text()

    def test_sync_includes_github_metadata(self) -> None:
        self.assertNotIn("--exclude='.github'", self.workflow)

    def test_workflow_passes_and_verifies_exact_release_sha(self) -> None:
        self.assertIn("RELEASE_SHA: ${{ github.sha }}", self.workflow)
        self.assertIn("Post-rsync · reconcile checkout metadata", self.workflow)
        self.assertIn('git fetch --no-tags origin "$RELEASE_SHA"', self.workflow)
        self.assertIn('verify_dir="$(mktemp -d)"', self.workflow)
        self.assertIn('verify_index="$verify_dir/index"', self.workflow)
        self.assertIn('GIT_INDEX_FILE="$verify_index" git read-tree "$RELEASE_SHA"', self.workflow)
        self.assertIn('GIT_INDEX_FILE="$verify_index" git update-index --refresh', self.workflow)
        self.assertIn('GIT_INDEX_FILE="$verify_index" git diff-files --quiet', self.workflow)
        self.assertNotIn('git diff --exit-code "$RELEASE_SHA" -- .', self.workflow)
        self.assertIn('git read-tree "$RELEASE_SHA"', self.workflow)
        self.assertIn('git reset --soft "$RELEASE_SHA"', self.workflow)
        self.assertIn('test "$(git rev-parse HEAD)" = "$RELEASE_SHA"', self.workflow)

    def test_reconciliation_is_fail_closed_and_scoped(self) -> None:
        self.assertIn('if [ "$WORKDIR" != "." ]', self.workflow)
        self.assertIn('if [ -n "$EXTRA_EXCLUDES" ]', self.workflow)
        self.assertIn("checkout differs from release", self.workflow)


if __name__ == "__main__":
    unittest.main()
