import tempfile
import unittest
import zipfile
import asyncio
import json
from unittest.mock import patch
from pathlib import Path
from epub_audio import chunks, extract, synthesize, output_lock, convert_sections
from types import SimpleNamespace


class Tests(unittest.TestCase):
    def test_chunk_integrity(self):
        for text in ['甲。乙！\n丙？', '长'*3001, '尾段没有标点', '']:
            parts = chunks(text, 100)
            self.assertEqual(''.join(parts), text)
            self.assertTrue(all(0 < len(s) <= 100 for s in parts))

    def test_spine_and_notes(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/'book.epub'
            with zipfile.ZipFile(path,'w') as z:
                z.writestr('META-INF/container.xml','<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
                z.writestr('OPS/book.opf','<package><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="b"/><itemref idref="a"/></spine></package>')
                z.writestr('OPS/a.xhtml','<html><body><h1>第一章</h1><p>甲<i>乙</i>丙<a><sup>[1]</sup></a>。</p><p class="tp">图注</p><h4>【注释】</h4><p class="fnote">文献来源</p></body></html>')
                z.writestr('OPS/b.xhtml','<html><body><h1>序言</h1><p>序言正文</p></body></html>')
            result = extract(path)
            self.assertEqual([s['title'] for s in result], ['序言','第一章'])
            self.assertEqual(result[1]['text'],'第一章\n甲乙丙。')
            self.assertIn('文献来源',extract(path,True)[1]['text'])


class AudioTests(unittest.IsolatedAsyncioTestCase):
    async def test_parallel_order_cache_and_voice_change(self):
        with tempfile.TemporaryDirectory() as directory:
            dest = Path(directory)/'chapter.mp3'
            active, peak = 0, 0
            calls, finished = [], []

            class FakeTTS:
                def __init__(self, text, voice, **kwargs):
                    self.text = text

                async def save(self, filename):
                    nonlocal active, peak
                    active += 1
                    peak = max(peak, active)
                    calls.append(self.text)
                    try:
                        await asyncio.sleep({'A':.04,'B':.02,'C':.001}[self.text])
                        Path(filename).write_bytes(self.text.encode())
                        finished.append(self.text)
                    finally:
                        active -= 1

            def fake_ffmpeg(args, **kwargs):
                if 'concat' in args:
                    listing = Path(args[args.index('-i')+1])
                    names = [line.split("'")[1] for line in listing.read_text().splitlines()]
                    Path(args[-1]).write_bytes(b''.join((listing.parent/n).read_bytes() for n in names))

            with patch('epub_audio.chunks',return_value=['A','B','C']), \
                 patch('epub_audio.edge_tts.Communicate',FakeTTS), \
                 patch('epub_audio.probe',return_value=1), \
                 patch('epub_audio.subprocess.run',side_effect=fake_ffmpeg):
                first = await synthesize('ABC',dest,'voice','-15%','+0Hz',2)
                self.assertEqual(peak,2)
                self.assertNotEqual(finished,['A','B','C'])
                self.assertEqual(dest.read_bytes(),b'ABC')
                self.assertEqual(first['status'],'success')
                count = len(calls)
                second = await synthesize('ABC',dest,'voice','-15%','+0Hz',3)
                self.assertEqual(second['status'],'skipped')
                self.assertEqual(len(calls),count)
                # Tampered final file is rebuilt from valid cache, without requests.
                dest.write_bytes(b'broken')
                await synthesize('ABC',dest,'voice','-15%','+0Hz',3)
                self.assertEqual(dest.read_bytes(),b'ABC')
                self.assertEqual(len(calls),count)
                await synthesize('ABC',dest,'different','-15%','+0Hz',3)
                self.assertEqual(len(calls),count+3)
                self.assertEqual(peak,3)

    async def test_failure_preserves_output_and_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            dest = Path(directory)/'chapter.mp3'
            dest.write_bytes(b'old-valid-audio')
            failed = True
            calls = []

            class FakeTTS:
                def __init__(self,text,*args,**kwargs):
                    self.text = text

                async def save(self,filename):
                    calls.append(self.text)
                    if self.text=='B' and failed:
                        Path(filename).write_bytes(b'partial')
                        raise ConnectionError('test')
                    Path(filename).write_bytes(self.text.encode())

            async def no_sleep(*args):
                pass

            def fake_ffmpeg(args,**kwargs):
                if 'concat' in args:
                    Path(args[-1]).write_bytes(b'ABC')

            with patch('epub_audio.chunks',return_value=['A','B','C']), \
                 patch('epub_audio.edge_tts.Communicate',FakeTTS), \
                 patch('epub_audio.probe',return_value=1), \
                 patch('epub_audio.asyncio.sleep',no_sleep), \
                 patch('epub_audio.subprocess.run',side_effect=fake_ffmpeg):
                with self.assertRaises(RuntimeError):
                    await synthesize('ABC',dest,'voice','-15%','+0Hz')
                self.assertEqual(dest.read_bytes(),b'old-valid-audio')
                state_path = next(Path(directory).rglob('state.json'))
                state = json.loads(state_path.read_text())
                self.assertEqual(state['failed'],1)
                self.assertEqual(state['completed'],2)
                self.assertFalse(list(Path(directory).rglob('*.tmp.mp3')))
                failed = False
                calls.clear()
                await synthesize('ABC',dest,'voice','-15%','+0Hz')
                self.assertEqual(calls,['B'])
                self.assertEqual(dest.read_bytes(),b'ABC')

    async def test_batch_continues_and_retry_failed_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            book = out/'input.epub'
            book.write_bytes(b'test-book')
            args = SimpleNamespace(epub=str(book),retry_failed=False,preview=0,
                                   extract_only=False,voice='voice',rate='-15%',
                                   pitch='+0Hz',concurrency=3,keep_notes=False)
            sections = [{'index':i,'title':str(i),'source':str(i),'text':str(i)} for i in [1,2]]
            calls = []
            should_fail = True

            async def fake_synthesis(text,dest,*args):
                calls.append(text)
                if text=='1' and should_fail:
                    raise RuntimeError('offline')
                return {'file':dest.name,'status':'success','duration_seconds':1}

            with patch('epub_audio.synthesize',side_effect=fake_synthesis):
                self.assertTrue(await convert_sections(args,sections,[1,2],out))
                self.assertEqual(calls,['1','2'])
                self.assertEqual(len(json.loads((out/'failures.json').read_text())),1)
                should_fail = False
                args.retry_failed = True
                calls.clear()
                self.assertFalse(await convert_sections(args,sections,[1,2],out))
                self.assertEqual(calls,['1'])
                self.assertEqual(json.loads((out/'failures.json').read_text()),[])
                self.assertEqual(len(json.loads((out/'report.json').read_text())),2)

    async def test_output_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with output_lock(out):
                with self.assertRaises(RuntimeError):
                    with output_lock(out):
                        self.fail('double lock')
            with output_lock(out):
                pass


if __name__ == '__main__':
    unittest.main()
