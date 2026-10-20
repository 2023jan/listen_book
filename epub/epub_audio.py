"""Local EPUB extraction + online Edge TTS. No model or paid API key."""
import argparse
import asyncio
import hashlib
import json
import posixpath
import re
import shutil
import subprocess
import sys
import zipfile
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import unquote
import xml.etree.ElementTree as ET

import edge_tts
from bs4 import BeautifulSoup


def extract(path, keep_notes=False):
    """Return spine documents in reading order; titles are not chapter numbers."""
    with zipfile.ZipFile(path) as z:
        container = ET.fromstring(z.read('META-INF/container.xml'))
        opf = container.find('.//{*}rootfile').attrib['full-path']
        root = ET.fromstring(z.read(opf))
        items = {x.attrib['id']: x.attrib for x in root.findall('.//{*}manifest/{*}item')}
        result = []
        for ref in root.findall('.//{*}spine/{*}itemref'):
            if ref.attrib.get('linear') == 'no':
                continue
            item = items[ref.attrib['idref']]
            if 'html' not in item.get('media-type', ''):
                continue
            name = posixpath.normpath(posixpath.join(posixpath.dirname(opf), unquote(item['href'].split('#')[0])))
            soup = BeautifulSoup(z.read(name).decode('utf-8-sig'), 'html.parser')
            body = soup.body or soup
            heading = body.find(re.compile('^h[1-6]$')) or soup.title
            title = heading.get_text(' ', strip=True) if heading else Path(name).stem
            for node in body.select('script,style,nav'):
                node.decompose()
            if not keep_notes:
                # Explicit endnote heading: everything after this is apparatus.
                for h in list(body.find_all(re.compile('^h[1-6]$'))):
                    if re.fullmatch(r'[【\[（(]?\s*(注释|註釋|Notes|Endnotes)\s*[】\]）)]?', h.get_text(strip=True), re.I):
                        for sibling in list(h.next_siblings):
                            sibling.extract()
                        h.decompose()
                        break
                for node in list(body.select('.fnote,.footnote,.endnote,.picture,.tp,[epub\:type="footnote"],[epub\:type="endnote"],[epub\:type="noteref"]')):
                    node.decompose()
                for sup in list(body.find_all('sup')):
                    if re.fullmatch(r'\[?\d+\]?', sup.get_text(strip=True)):
                        sup.decompose()
            for br in body.find_all('br'):
                br.replace_with('\n')
            for block in body.find_all(['p','div','h1','h2','h3','h4','h5','h6','li']):
                block.insert_after('\n')
            text = '\n'.join(re.sub(r'\s+', ' ', line).strip() for line in body.get_text().splitlines() if line.strip())
            if text:
                result.append({'index': len(result)+1, 'title': title, 'source': name, 'text': text})
        return result


def chunks(text, limit=1200):
    pieces = re.findall(r'.+?(?:[。！？!?；;\n]+|$)', text, re.S)
    out, current = [], ''
    for piece in pieces:
        while len(piece) > limit:
            if current:
                out.append(current)
                current = ''
            out.append(piece[:limit])
            piece = piece[limit:]
        if len(current) + len(piece) > limit:
            out.append(current)
            current = ''
        current += piece
    if current:
        out.append(current)
    assert ''.join(out) == text, 'Chunking lost text'
    return out


def probe(file):
    p = subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','json',str(file)], capture_output=True, text=True, check=True)
    seconds = float(json.loads(p.stdout)['format']['duration'])
    if seconds <= 0:
        raise ValueError('Empty audio')
    return seconds


def save_json(path, data):
    tmp = path.with_suffix('.tmp.json')
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    tmp.replace(path)


@contextmanager
def output_lock(out):
    """OS lock releases even after a crash; never delete the lock inode."""
    handle = (out / '.run.lock').open('a+b')
    locked = False
    try:
        handle.seek(0, 2)
        if not handle.tell():
            handle.write(b'0')
            handle.flush()
        handle.seek(0)
        try:
            if sys.platform == 'win32':
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
        except OSError:
            raise RuntimeError('该输出目录已有任务运行；请等待或使用另一个 --out') from None
        yield
    finally:
        if locked:
            handle.seek(0)
            if sys.platform == 'win32':
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


async def synthesize(text, dest, voice, rate, pitch, concurrency=3):
    if not 1 <= concurrency <= 3:
        raise ValueError('concurrency must be 1..3')
    started = time.monotonic()
    key = hashlib.sha256(json.dumps([text,voice,rate,pitch],ensure_ascii=False).encode()).hexdigest()
    receipt = dest.with_suffix('.json')
    if dest.exists() and receipt.exists():
        previous = json.loads(receipt.read_text(encoding='utf-8'))
        if previous.get('cache_key') == key and previous.get('audio_sha256') == hashlib.sha256(dest.read_bytes()).hexdigest():
            probe(dest)
            return dict(previous, status='skipped', elapsed_seconds=0)
    cache = dest.parent / '.cache' / key
    cache.mkdir(parents=True, exist_ok=True)
    segments = chunks(text)
    if not segments:
        raise ValueError('No text to synthesize')
    state = {'total':len(segments), 'completed':0, 'cached':0, 'failed':0,
             'running':0, 'concurrency':concurrency, 'peak_running':0, 'status':'running',
             'segments':[{'index':i, 'status':'pending'} for i in range(len(segments))]}

    def update(i, status, error=None):
        state['segments'][i] = {'index':i, 'status':status}
        if error:
            state['segments'][i]['error'] = error
        state['running'] = sum(s['status']=='running' for s in state['segments'])
        state['peak_running'] = max(state['peak_running'], state['running'])
        for field, value in [('completed','success'),('cached','cached'),('failed','failed')]:
            state[field] = sum(s['status']==value for s in state['segments'])
        save_json(cache/'state.json', state)

    async def generate(i):
        segment = segments[i]
        part = cache / f'{i:04d}.mp3'
        if part.exists():
            try:
                probe(part)
                update(i, 'cached')
                print(f'  {i+1}/{len(segments)} cached', flush=True)
                return
            except Exception:
                part.unlink()
        update(i, 'running')
        for attempt in range(4):
            tmp = part.with_suffix('.tmp.mp3')
            try:
                await asyncio.wait_for(edge_tts.Communicate(segment,voice,rate=rate,pitch=pitch).save(str(tmp)),timeout=120)
                probe(tmp)
                tmp.replace(part)
                update(i, 'success')
                print(f'  {i+1}/{len(segments)} generated', flush=True)
                return
            except asyncio.CancelledError:
                tmp.unlink(missing_ok=True)
                update(i, 'interrupted')
                raise
            except Exception as e:
                tmp.unlink(missing_ok=True)
                if attempt == 3:
                    update(i, 'failed', type(e).__name__)
                    return
                print(f'  retry {attempt+1}: {type(e).__name__}',flush=True)
                await asyncio.sleep(2 ** (attempt+1))
    # A fixed worker pool bounds both active requests and task count.
    queue = asyncio.Queue()
    for i in range(len(segments)):
        queue.put_nowait(i)

    async def worker():
        while not queue.empty():
            i = queue.get_nowait()
            try:
                await generate(i)
            finally:
                queue.task_done()

    workers = [asyncio.create_task(worker()) for _ in range(min(concurrency,len(segments)))]
    try:
        await asyncio.gather(*workers)
    finally:
        for task in workers:
            if not task.done():
                task.cancel()
        await asyncio.gather(*workers, return_exceptions=True)
    state['status'] = 'failed' if state['failed'] else 'generated'
    save_json(cache/'state.json', state)
    if state['failed']:
        raise RuntimeError(f"{state['failed']} segments failed; rerun to resume; see {cache/'state.json'}")
    # Numeric source order, NOT completion order.
    listing = cache / 'concat.txt'
    listing.write_text(''.join(f"file '{i:04d}.mp3'\n" for i in range(len(segments))),encoding='utf-8')
    tmp = dest.with_suffix('.tmp.mp3')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','concat','-safe','0','-i',str(listing),'-c:a','copy','-metadata','title='+dest.stem,str(tmp)],check=True)
    duration = probe(tmp)
    subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(tmp),'-f','null','-'],check=True)
    tmp.replace(dest)
    result = {'file':dest.name,'characters':len(text),'segments':len(segments),'duration_seconds':duration,'voice':voice,'rate':rate,'pitch':pitch,'text_sha256':hashlib.sha256(text.encode()).hexdigest(),
              'cache_key':key,'audio_sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),
              'concurrency':concurrency,'peak_running':state['peak_running'],
              'elapsed_seconds':round(time.monotonic()-started,3),'status':'success'}
    save_json(receipt, result)
    state['status'] = 'success'
    save_json(cache/'state.json', state)
    return result


async def main():
    p = argparse.ArgumentParser(description='EPUB 转 MP3：本地提取，免费在线语音')
    p.add_argument('epub',nargs='?')
    p.add_argument('--list',action='store_true',help='列出阅读顺序中的文档编号')
    p.add_argument('--sections',help='选择 --list 输出的编号，例如 6,7（不是书籍章号）')
    p.add_argument('--voices',action='store_true')
    p.add_argument('--voice',default='zh-CN-XiaoxiaoNeural')
    p.add_argument('--rate',default='-15%')
    p.add_argument('--pitch',default='+0Hz')
    p.add_argument('--out',default='audio')
    p.add_argument('--preview',type=int,default=0,help='只生成每个文档前 N 字试听')
    p.add_argument('--keep-notes',action='store_true')
    p.add_argument('--extract-only',action='store_true')
    p.add_argument('--concurrency',type=int,choices=range(1,4),default=3,help='同时生成的片段数，默认 3')
    p.add_argument('--retry-failed',action='store_true',help='在选定章节中只重试 failures.json 中失败项')
    a = p.parse_args()
    if a.preview < 0:
        p.error('--preview 不能为负数')
    if a.voices:
        for v in await edge_tts.list_voices():
            if v['Locale'].startswith('zh'):
                print(v['ShortName'], v['Gender'])
        return
    if not a.epub:
        p.error('请指定 EPUB')
    sections = extract(a.epub,a.keep_notes)
    if a.list:
        for s in sections:
            print(f"{s['index']:2d}  {s['title']}  ({len(s['text'])} 字符)")
        return
    if not a.sections:
        p.error('先 --list 核对章节，再 --sections 选择，避免把序言当第一章')
    ids = [int(x) for x in a.sections.split(',')]
    if len(ids)!=len(set(ids)) or any(i<1 or i>len(sections) for i in ids):
        p.error('文档编号重复或超出范围')
    if not a.extract_only and not all(shutil.which(x) for x in ['ffmpeg','ffprobe']):
        p.error('请安装 FFmpeg，并将 ffmpeg/ffprobe 加入 PATH')
    out = Path(a.out).resolve()
    out.mkdir(parents=True,exist_ok=True)
    with output_lock(out):
        failed = await convert_sections(a, sections, ids, out)
    if failed:
        raise SystemExit(1)


async def convert_sections(a, sections, ids, out):
    book_key = hashlib.sha256(Path(a.epub).read_bytes()).hexdigest()
    failure_path = out/'failures.json'
    failures = json.loads(failure_path.read_text(encoding='utf-8')) if failure_path.exists() else []
    if a.retry_failed:
        failed_ids = {r['index'] for r in failures if r['book_sha256']==book_key}
        ids = [i for i in ids if i in failed_ids]
        if not ids:
            print('没有匹配的失败章节。')
            return False
    failed = False
    report_path = out/'report.json'
    report = json.loads(report_path.read_text(encoding='utf-8')) if report_path.exists() else []
    for i in ids:
        s = sections[i-1]
        title = re.sub(r'[<>:"/\\|?*\x00-\x1f]','_',s['title']).strip(' .')[:100]
        stem = f'{i:02d}_{title}' + ('_试听' if a.preview else '')
        text = s['text'][:a.preview] if a.preview else s['text']
        print(f"START {s['title']} ({len(text)} chars)",flush=True)
        (out / (stem+'.txt')).write_text(text,encoding='utf-8')
        if not a.extract_only:
            try:
                r = await synthesize(text,out/(stem+'.mp3'),a.voice,a.rate,a.pitch,a.concurrency)
            except Exception as e:
                failed = True
                failures = [f for f in failures if (f['book_sha256'],f['index']) != (book_key,i)]
                failures.append({'book_sha256':book_key,'index':i,'title':s['title'],'error':str(e)})
                save_json(failure_path, failures)
                print(f"FAILED {s['title']}: {e}",flush=True)
                continue
            r.update(source=s['source'],title=s['title'],notes_included=a.keep_notes)
            report = [old for old in report if old['file'] != r['file']] + [r]
            save_json(report_path, report)
            failures = [f for f in failures if (f['book_sha256'],f['index']) != (book_key,i)]
            save_json(failure_path, failures)
            print(f"{r['status'].upper()} {stem}: {r['duration_seconds']/60:.1f} min",flush=True)
    return failed


if __name__ == '__main__':
    if hasattr(sys.stdout,'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    asyncio.run(main())
