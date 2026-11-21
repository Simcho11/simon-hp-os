"""hp-os-search looks in the user's own folders (user-dirs.dirs), in any language."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / 'packaging/hp-os-search'
loader = importlib.machinery.SourceFileLoader('hp_os_search', str(HELPER))
spec = importlib.util.spec_from_loader('hp_os_search', loader)
search = importlib.util.module_from_spec(spec)
loader.exec_module(search)


class SearchFolderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / '.config').mkdir()
        patch = mock.patch.dict(os.environ, {'HOME': str(self.home), 'XDG_CONFIG_HOME': str(self.home / '.config'),
                                             'XDG_STATE_HOME': str(self.home / 'state')})
        patch.start()
        self.addCleanup(patch.stop)

    def test_english_names_without_user_dirs(self):
        self.assertEqual([p.name for p in search.user_folders(self.home)],
                         ['Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos'])

    def test_the_users_own_names_and_turned_off_folders(self):
        (self.home / '.config/user-dirs.dirs').write_text(
            '# written by xdg-user-dirs-update\n'
            'XDG_DESKTOP_DIR="$HOME/桌面"\nXDG_DOCUMENTS_DIR="$HOME/文档"\nXDG_DOWNLOAD_DIR="/data/Downloads"\n'
            'XDG_MUSIC_DIR="$HOME/"\nXDG_PICTURES_DIR="$HOME"\nXDG_VIDEOS_DIR="$HOME/文档"\n')
        self.assertEqual(search.user_folders(self.home),
                         [self.home / '桌面', self.home / '文档', Path('/data/Downloads')])

    def test_search_finds_files_in_a_renamed_folder(self):
        (self.home / '.config/user-dirs.dirs').write_text('XDG_DOCUMENTS_DIR="$HOME/Dokumente"\n')
        (self.home / 'Dokumente').mkdir()
        (self.home / 'Dokumente' / 'Rechnung.pdf').write_bytes(b'%PDF')
        self.assertEqual([r['name'] for r in search.search(self.home, 'rechnung')], ['Rechnung.pdf'])

    def test_index_folders_follow_the_user_folders_and_keep_other_settings(self):
        (self.home / 'Desktop').mkdir()
        conf = search.configure()
        text = (conf / 'recoll.conf').read_text()
        self.assertIn('topdirs = "%s"\n' % (self.home / 'Desktop'), text)
        (conf / 'recoll.conf').write_text(text + 'customsetting = 1\n')
        (self.home / '.config/user-dirs.dirs').write_text('XDG_DESKTOP_DIR="$HOME/Bureau"\n')
        (self.home / 'Bureau').mkdir()
        search.configure()
        text = (conf / 'recoll.conf').read_text()
        self.assertIn('topdirs = "%s"\n' % (self.home / 'Bureau'), text)
        self.assertNotIn(str(self.home / 'Desktop') + '"', text)
        self.assertIn('customsetting = 1', text)
        self.assertIn('pdfocr = 1', text)


if __name__ == '__main__':
    unittest.main()
