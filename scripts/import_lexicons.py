#!/usr/bin/env python3
"""從固定來源快照匯入詞庫；保留逐詞來源，不改寫既有詞條。"""
import argparse
import hashlib
import json
import lzma
import re
import shutil
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / 'data/lexicon-import'
MANIFEST = ROOT / 'lexicons/imported_entries.jsonl'
SUMMARY = ROOT / 'lexicons/import_manifest.json'
ENGLISH = ROOT / 'src/englishIME/Resources/english_words.tsv'
CHINESE = ROOT / 'src/unifyIME/Resources/phrase_map.tsv'
CATEGORIES = {
    'languages': ('Q9143', '程式語言'),
    'software': ('Q7397', '軟體'),
    'operating-systems': ('Q9135', '作業系統'),
    'brands': ('Q431289', '品牌'),
    'companies': ('Q783794', '公司'),
    'public-companies': ('Q891723', '上市公司'),
    'manufacturers': ('Q187939', '製造商'),
    'video-games': ('Q7889', '電子遊戲'),
}
HEADERS = {'User-Agent': 'UnifyIME-Lexicon-Importer/1.0 (https://github.com/VaderChen/UnifyIME)',
           'Accept': 'application/json'}


def download(url):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as response:
                return response.read()
        except (OSError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    if not (CACHE / 'moedict.json.xz').exists():
        revision = json.loads(download('https://api.github.com/repos/g0v/moedict-data/commits/main'))['sha']
        url = f'https://raw.githubusercontent.com/g0v/moedict-data/{revision}/dict-revised.json.xz'
        (CACHE / 'moedict.json.xz').write_bytes(download(url))
        (CACHE / 'moedict-source.json').write_text(json.dumps({'revision': revision, 'url': url}))
    for category, (entity, _) in CATEGORIES.items():
        path = CACHE / f'wikidata-{category}.json'
        if path.exists():
            continue
        query = '''SELECT ?item ?en ?links WHERE {
          ?item wdt:P31 wd:ENTITY; rdfs:label ?en; wikibase:sitelinks ?links.
          FILTER(LANG(?en)="en" && ?links >= 5)
        } ORDER BY DESC(?links) ?item LIMIT 2000'''.replace('ENTITY', entity)
        url = 'https://query.wikidata.org/sparql?' + urllib.parse.urlencode({'query': query, 'format': 'json'})
        content = download(url)
        payload = json.loads(content)
        assert isinstance(payload['results']['bindings'], list)
        path.write_bytes(content)
        path.with_suffix('.query.txt').write_text(query)
        print(f'已下載 {category}：{len(payload["results"]["bindings"])} 筆', flush=True)
        time.sleep(1)

    for batch, path in name_batches():
        if path.exists():
            continue
        query = '''SELECT ?item ?zhTw ?zhHant ?zh (GROUP_CONCAT(DISTINCT ?alias;separator="|") AS ?aliases) WHERE {
            VALUES ?item { ITEMS }
            OPTIONAL { ?item rdfs:label ?zhTw FILTER(LANG(?zhTw)="zh-tw") }
            OPTIONAL { ?item rdfs:label ?zhHant FILTER(LANG(?zhHant)="zh-hant") }
            OPTIONAL { ?item rdfs:label ?zh FILTER(LANG(?zh)="zh") }
            OPTIONAL { ?item skos:altLabel ?alias FILTER(LANG(?alias)="en") }
        } GROUP BY ?item ?zhTw ?zhHant ?zh'''.replace('ITEMS', ' '.join('wd:' + item for item in batch))
        url = 'https://query.wikidata.org/sparql?' + urllib.parse.urlencode({'query': query, 'format': 'json'})
        content = download(url)
        assert isinstance(json.loads(content)['results']['bindings'], list)
        path.write_bytes(content)
        path.with_suffix('.query.txt').write_text(query)
        print(f'已取得別名與中文名稱：{len(batch)} 筆（{path.name}）', flush=True)
        time.sleep(0.25)


def name_batches():
    items = sorted({row['item']['value'].rsplit('/', 1)[-1]
                    for category in CATEGORIES
                    for row in json.loads((CACHE / f'wikidata-{category}.json').read_text())['results']['bindings']
                    if re.fullmatch(r"[A-Za-z]+(?:[ '-][A-Za-z]+)*", row['en']['value'])
                    and 3 <= len(row['en']['value'].replace(' ', '')) <= 32})
    for start in range(0, len(items), 100):
        batch = items[start:start + 100]
        digest = hashlib.sha256(' '.join(batch).encode()).hexdigest()[:16]
        yield batch, CACHE / f'wikidata-names-{digest}.json'


def reading_for(word, raw):
    if not re.fullmatch(r'[\u3400-\u9fff]{2,8}', word):
        return None
    syllables = raw.split()
    if len(syllables) != len(word):
        return None
    result = []
    for syllable in syllables:
        # 輕聲點移至尾端僅轉換引擎表示法，不變更原始讀音。
        if syllable.startswith('˙'):
            syllable = syllable[1:] + '˙'
        if not re.fullmatch(r'[ㄅ-ㄩ]+[ˊˇˋ˙]?', syllable):
            return None
        result.append(syllable)
    return ''.join(result)


def import_data(apply):
    previous = [json.loads(line) for line in MANIFEST.read_text().splitlines()] if MANIFEST.exists() else []
    original = {'en': ENGLISH.read_text(), 'zh': CHINESE.read_text()}
    base = {language: text.splitlines() for language, text in original.items()}
    base_sets = {language: set(lines) for language, lines in base.items()}
    # 重跑前只移除本工具上次產生且未被人工修改的完整行。
    for row in previous:
        line = row['line']
        if line not in base_sets[row['language']]:
            raise RuntimeError('已匯入詞條被修改或移除，請先處理來源清單：' + row['surface'])
    owned = {language: {row['line'] for row in previous if row['language'] == language} for language in base}
    base = {language: [line for line in lines if line not in owned[language]] for language, lines in base.items()}
    seen = {language: {tuple(line.split('\t')[:2]) for line in lines} for language, lines in base.items()}
    common = (ROOT / 'src/unifyIME/Resources/common_map.tsv').read_text().splitlines()
    seen['zh'].update(tuple(line.split('\t')[:2]) for line in common)
    entries = []
    def add(language, key, surface, weight, source, extra=None):
        if (key, surface) in seen[language]:
            return
        if any(c in key + surface for c in '\t\r\n'):
            return
        seen[language].add((key, surface))
        fields = [key, surface, str(weight)]
        if language == 'en':
            fields.append(extra.get('category', '專有名詞'))
        entries.append({'language': language, 'key': key, 'surface': surface,
                        'line': '\t'.join(fields), 'source': source, **(extra or {})})

    moe_source = json.loads((CACHE / 'moedict-source.json').read_text())
    dictionary = json.loads(lzma.decompress((CACHE / 'moedict.json.xz').read_bytes()))
    readings = {}
    for row in dictionary:
        word = row.get('title', '')
        for heteronym in row.get('heteronyms', []):
            raw = heteronym.get('bopomofo', '')
            reading = reading_for(word, raw)
            if reading:
                readings.setdefault(word, set()).add(reading)
                add('zh', reading, word, 0, 'moe-revised', {'original_bopomofo': raw})
    name_details = {}
    for _, path in name_batches():
        for row in json.loads(path.read_text())['results']['bindings']:
            name_details[row['item']['value'].rsplit('/', 1)[-1]] = row
    wikidata_count = 0
    pending_aliases = []
    for category, (_, description) in CATEGORIES.items():
        payload = json.loads((CACHE / f'wikidata-{category}.json').read_text())
        for row in payload['results']['bindings']:
            item = row['item']['value'].rsplit('/', 1)[-1]
            if not re.fullmatch(r'Q\d+', item):
                continue
            en = row['en']['value']
            details = name_details.get(item, row)
            zh = next((details[k]['value'] for k in ['zhTw', 'zhHant', 'zh'] if k in details), '')
            # 只收錄目前英文引擎能處理的鍵序；不擅改產品拼寫或刪除數字。
            key = en.lower().replace(' ', '')
            if 3 <= len(key) <= 32 and re.fullmatch(r"[A-Za-z]+(?:[ '-][A-Za-z]+)*", en):
                add('en', key, en, 200, 'wikidata', {'entity': item, 'category': description, 'zh_label': zh})
                wikidata_count += 1
                for alias in details.get('aliases', {}).get('value', '').split('|'):
                    alias_key = alias.lower().replace(' ', '')
                    if 3 <= len(alias_key) <= 32 and re.fullmatch(r"[A-Za-z]+(?:[ '-][A-Za-z]+)*", alias):
                        pending_aliases.append((alias_key, en,
                            {'entity': item, 'category': description, 'alias': alias, 'zh_label': zh}))
            # 百科名稱只能使用字典的完整詞讀音，不拼接單字猜音。
            for reading in sorted(readings.get(zh, set())):
                add('zh', reading, zh, 0, 'wikidata+moe-revised', {'entity': item})
    # 正式名稱先完成去重，再加入較低權重別名，避免別名搶先占用正式詞條。
    for key, surface, extra in pending_aliases:
        add('en', key, surface, 150, 'wikidata', extra)
    entries.sort(key=lambda row: (row['language'], row['key'], row['surface']))
    counts = {language: sum(row['language'] == language for row in entries) for language in base}
    sources = []
    for path in sorted(CACHE.glob('*')):
        if path.is_file() and path.suffix in ['.json', '.xz', '.txt']:
            sources.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    metadata = {'schema_version': 1, 'moedict': moe_source, 'wikidata_classes': CATEGORIES,
                'weights': {'en': 200, 'en_alias': 150, 'zh': 0}, 'imported': counts, 'source_files': sources,
                'licenses': {'moe-revised': 'CC-BY-ND-3.0-TW', 'wikidata': 'CC0-1.0'}}
    print(json.dumps({'imported': counts, 'wikidata_supported_labels': wikidata_count}, ensure_ascii=False), flush=True)
    outputs = {ENGLISH: '\n'.join(base['en'] + [r['line'] for r in entries if r['language'] == 'en']) + '\n',
               CHINESE: '\n'.join(base['zh'] + [r['line'] for r in entries if r['language'] == 'zh']) + '\n',
               MANIFEST: ''.join(json.dumps(r, ensure_ascii=False, sort_keys=True) + '\n' for r in entries),
               SUMMARY: json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + '\n'}
    if not apply:
        return outputs
    # 預先產生所有檔案，修改前保留備份；失敗保留備份供復原。
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            backup = path.with_name(path.name + '.import.bak')
            if backup.exists():
                raise RuntimeError('請先處理既有備份：' + str(backup))
            shutil.copy2(path, backup)
        path.with_name(path.name + '.import.tmp').write_text(content)
    for path in outputs:
        path.with_name(path.name + '.import.tmp').replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fetch', action='store_true', help='下載尚未存在的來源快照；已有快照不覆寫')
    parser.add_argument('--apply', action='store_true', help='寫入詞庫及逐詞來源；預設僅顯示匯入數量')
    args = parser.parse_args()
    if args.fetch:
        fetch()
    import_data(args.apply)


if __name__ == '__main__':
    main()
