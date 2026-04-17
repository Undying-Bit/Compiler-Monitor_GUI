from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class EnvTemplateSecurityTest(unittest.TestCase):
    def test_packaged_env_template_contains_no_cloud_credentials(self) -> None:
        template = (ROOT / "packaging" / "env.template").read_text(encoding="utf-8")

        self.assertNotIn("ACCESS_KEY", template)
        self.assertNotIn("SECRET_KEY", template)
        self.assertNotIn("SESSION_TOKEN", template)
        self.assertIn("MONITOR_PRIMARY_BASE_URL=", template)
        self.assertIn("MONITOR_UPDATE_MANIFEST_URL=", template)


if __name__ == "__main__":
    unittest.main()
