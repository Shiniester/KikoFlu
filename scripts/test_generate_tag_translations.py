import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import generate_tag_translations


class SupportedTagLanguagesTest(unittest.TestCase):
    def test_extra_translations_exclude_removed_languages(self):
        with tempfile.TemporaryDirectory() as directory:
            for language in ['en', 'ja', 'zh', 'zh_Hant', 'ru', 'ko']:
                Path(directory, f'tag_translations_{language}.json').write_text(
                    json.dumps({'1': 'tag'}), encoding='utf-8'
                )
            with patch.object(generate_tag_translations, 'SCRIPT_DIR', directory):
                self.assertEqual(
                    set(generate_tag_translations.load_extra_translations()),
                    {'en', 'ja', 'zh', 'zh_Hant'},
                )


if __name__ == '__main__':
    unittest.main()
