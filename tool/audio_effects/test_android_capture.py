"""Host-only checks: no adb, device, libmpv or fabricated native-pass claim."""
import importlib.util
import io
import json
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('android_capture', ROOT/'scripts/validate_android_audio_effects.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def read_actions(path):
    stream = io.BytesIO(path.read_bytes())
    result = []
    for _ in range(int(stream.readline())):
        when, count = stream.readline().split()
        args = []
        for _ in range(int(count)):
            size = int(stream.readline())
            args.append(stream.read(size).decode('utf-8'))
            assert stream.read(1) == b'\n'
        result.append((float(when), args))
    return result


class AndroidCaptureHostTest(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT/'build/android-capture-host-check'
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commands = []
        adapter.SERIAL = 'host-only-serial'

    def process(self, arguments, **kwargs):
        self.commands.append(arguments)
        stdout = b''
        if arguments[3] == 'pull':
            Path(arguments[-1]).write_bytes(struct.pack('<ff', .1, .2))
        if arguments[3] == 'shell' and 'runner' in arguments[-1]:
            stdout = b'["initialized",1]\n["end",0,0]\n["timeout",false]\n'
        return subprocess.CompletedProcess(arguments, 0, stdout, b'')

    def capture(self, source, actions=(), **kwargs):
        with patch.object(adapter.subprocess, 'run', side_effect=self.process):
            return adapter.run(self.root, Path('unused.so'), 'host', '[in]anull[out]', [], 0,
                               source_url=source, actions=actions, **kwargs)

    def test_local_source_and_loadfile_reinit_paths_are_staged(self):
        files = [self.root/name for name in ('A space.wav','B.wav','C.wav')]
        for file in files:
            file.write_bytes(b'owned wav fixture')
        report, actual = self.capture(str(files[0]), ((.35,['loadfile',str(files[1]),'replace']),
                                                    (.7,['reinit',str(files[2])])))
        command = next(shlex.split(row[-1]) for row in self.commands if row[3]=='shell' and 'runner' in row[-1])
        self.assertTrue(command[2].startswith(adapter.REMOTE+'/'))
        resolved = read_actions(self.root/'actions.bin')
        self.assertTrue(all(item[1][1].startswith(adapter.REMOTE+'/') for item in resolved))
        pushed = [str(value) for row in self.commands if row[3]=='push' for value in row[4:-1]]
        self.assertTrue(all(str(file) in pushed for file in files))
        self.assertEqual(report['capture']['return_code'],0)
        self.assertEqual(len(actual),1)

    def test_owned_hls_stages_only_manifest_and_referenced_aac(self):
        playlist = self.root/'switch.m3u8'
        playlist.write_text('#EXTM3U\n#EXTINF:0.5,\n0.aac\n#EXT-X-DISCONTINUITY\n#EXTINF:0.5,\n1.aac\n#EXT-X-ENDLIST\n')
        for name in ('0.aac','1.aac','unrelated.pcm'):
            (self.root/name).write_bytes(b'owned')
        self.capture(str(playlist),demuxer_format='hls')
        pushed = [str(value) for row in self.commands if row[3]=='push' for value in row[4:-1]]
        self.assertTrue(all(str(self.root/name) in pushed for name in ('switch.m3u8','0.aac','1.aac')))
        self.assertNotIn(str(self.root/'unrelated.pcm'),pushed)

    def test_update_report_keeps_full_and_bare_target_replies(self):
        original_process=self.process
        def process(arguments,**kwargs):
            result=original_process(arguments,**kwargs)
            if arguments[3]=='shell' and 'runner' in arguments[-1]:
                result.stdout=(b'["initialized",1]\n["update",1,0]\n'
                    b'["event",5,-12,100]\n["retry",0,"scene_amount",0]\n'
                    b'["event",5,0,100]\n["end",0,0]\n["timeout",false]\n')
            return result
        self.process=process
        report,_=self.capture('https://example.invalid/owned.wav',updates=((.1,1),),
                              update_target='volume@scene_amount')
        self.assertEqual(report['updates'][0]['attempts'],[
            {'target':'volume@scene_amount','enqueue_code':0,'reply_error':-12},
            {'target':'scene_amount','enqueue_code':0,'reply_error':0}])

    def test_reconfig_metadata_and_reply_parser_keep_native_command(self):
        source='https://example.invalid/owned.wav'
        original_process=self.process
        def process(arguments,**kwargs):
            result=original_process(arguments,**kwargs)
            if arguments[3]=='shell' and 'runner' in arguments[-1]:
                result.stdout=(b'["initialized",1]\n["audio_reconfig",96000,20480]\n'
                    b'["action",0,0]\n["action_reply",0,-12,"no"]\n'
                    b'["action_retry",0,"scene_amount",0]\n["action_reply",0,0,"no"]\n'
                    b'["end",0,0]\n["timeout",false]\n')
            return result
        self.process=process
        command=['af-command','effects','volume','1','volume@scene_amount']
        report,_=self.capture(source,reconfig_actions=((96000,command),))
        encoded=read_actions(self.root/'actions.bin')
        self.assertEqual(encoded,[(0.,['on-audio-reconfig','96000',*command])])
        self.assertEqual(report['actions'][0]['command'],command)
        self.assertEqual(report['actions'][0]['on_audio_reconfig'],96000)
        self.assertEqual(report['actions'][0]['reply_error'],0)
        self.assertEqual(report['actions'][0]['attempts'][-1]['target'],'scene_amount')
        self.assertEqual(report['audio_reconfigs'],[{'sample_rate':96000,'pcm_bytes':20480}])

    def test_loopback_http_is_not_staged_and_keeps_reverse(self):
        source = 'http://127.0.0.1:32109/owned/source.wav?route=A'
        self.capture(source)
        command = next(shlex.split(row[-1]) for row in self.commands if row[3]=='shell' and 'runner' in row[-1])
        self.assertEqual(command[2],source)
        self.assertEqual([row[4:] for row in self.commands if row[3]=='reverse'],
                         [['tcp:32109','tcp:32109'],['--remove','tcp:32109']])
        self.assertFalse(any('source.wav' in str(value) for row in self.commands if row[3]=='push' for value in row[4:-1]))


if __name__ == '__main__':
    unittest.main()
