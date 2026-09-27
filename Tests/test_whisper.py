"""Ensure encoder reuse never confuses different windows or different recordings."""
import importlib.util
from pathlib import Path
from unittest import TestCase, main
from unittest.mock import patch, MagicMock
import numpy as np
import mlx.core as mx
import io
import json
spec=importlib.util.spec_from_file_location('helper',Path(__file__).parents[1]/'whisper/murmur_whisper.py')
h=importlib.util.module_from_spec(spec); spec.loader.exec_module(h)

class TranscriptionTests(TestCase):
    def setUp(self):
        self.model=MagicMock()
        self.model.dims.n_mels=128
        self.model.detect_language.return_value=(None,{'zh':0.9,'en':0.1})
        self.original=MagicMock(side_effect=lambda mel: mel+10)
        self.model.encoder=self.original
        self.mel=mx.ones((h.N_FRAMES+100,2))
        self.patches=[patch.object(h.ModelHolder,'get_model',return_value=self.model),
                      patch.object(h,'log_mel_spectrogram',return_value=self.mel),
                      patch.object(h.mlx_whisper,'transcribe')]
        self.mocks=[p.start() for p in self.patches]
        self.addCleanup(lambda: [p.stop() for p in reversed(self.patches)])

    def window(self):
        return h.pad_or_trim(self.mel[:100],h.N_FRAMES,axis=-2).astype(mx.float16)[None]

    def test_identical_window_reuses_and_keeps_transcript(self):
        def standard(audio,**kwargs):
            one=self.model.encoder(self.window())
            two=self.model.encoder(self.window())
            self.assertTrue(bool(mx.array_equal(one,two).item()))
            self.assertEqual(kwargs['language'],'zh')
            return {'text':'你好，hello。','language':'zh','segments':[{'text':'all speech'}]}
        self.mocks[-1].side_effect=standard
        result=h.transcribe(np.ones(16000),'dictionary')
        self.assertEqual(result['text'],'你好，hello。')
        self.assertEqual(result['segments'],[{'text':'all speech'}])
        self.assertEqual(result['mode'],'shared-encoder; reused=2')
        self.original.assert_called_once()
        self.assertIs(self.model.encoder,self.original)

    def test_different_window_is_recomputed(self):
        def standard(audio,**kwargs):
            self.model.encoder(self.window()+1)
            return {'text':'second window'}
        self.mocks[-1].side_effect=standard
        h.transcribe(np.ones(16000),None)
        self.assertEqual(self.original.call_count,2)

    def test_cache_is_discarded_between_requests(self):
        self.mocks[-1].return_value={'text':'done'}
        h.transcribe(np.ones(16000),None)
        h.transcribe(np.ones(16000),None)
        self.assertEqual(self.original.call_count,2)

    def test_failure_restores_encoder(self):
        self.mocks[-1].side_effect=RuntimeError('recognition failed')
        with self.assertRaises(RuntimeError): h.transcribe(np.ones(16000),None)
        self.assertIs(self.model.encoder,self.original)

    def test_full_long_recording_and_prompt_pass_through(self):
        audio=np.ones(40*16000,dtype=np.float32)
        self.mocks[-1].return_value={'text':'last word'}
        h.transcribe(audio,'vocabulary')
        self.assertIs(self.mocks[-1].call_args.args[0],audio)
        self.assertEqual(self.mocks[-1].call_args.kwargs['initial_prompt'],'vocabulary')
        self.assertNotIn('temperature',self.mocks[-1].call_args.kwargs)
        self.assertNotIn('without_timestamps',self.mocks[-1].call_args.kwargs)

    def test_cjk_punctuation_keeps_english(self):
        self.assertEqual(h.fix_cjk_punctuation('你好, 明天见! English, unchanged.'),'你好，明天见！English, unchanged.')

class PrewarmProtocolTests(TestCase):
    def run_protocol(self, fail=False):
        incoming = io.StringIO('{"warmup":true}\n{"path":"test.f32"}\n')
        outgoing = io.StringIO()
        with patch.object(h.sys, 'stdin', incoming), patch.object(h.sys, 'stdout', outgoing), \
             patch.object(h, 'warmup', side_effect=RuntimeError('test') if fail else None), \
             patch.object(h.np, 'fromfile', return_value=np.ones(16000, dtype=np.float32)), \
             patch.object(h, 'transcribe', return_value={'text':'你好，hello。','language':'zh'}):
            h.serve()
        return [json.loads(line) for line in outgoing.getvalue().splitlines()]

    def test_prewarm_is_separate_from_queued_transcript(self):
        rows = self.run_protocol()
        self.assertTrue(rows[0]['ready'])
        self.assertTrue(rows[1]['warmed'])
        self.assertNotIn('text', rows[1])
        self.assertEqual(rows[2]['text'], '你好，hello。')

    def test_failed_prewarm_does_not_consume_next_dictation(self):
        rows = self.run_protocol(fail=True)
        self.assertFalse(rows[1]['warmed'])
        self.assertIn('error', rows[1])
        self.assertEqual(rows[2]['text'], '你好，hello。')

if __name__=='__main__': main()
