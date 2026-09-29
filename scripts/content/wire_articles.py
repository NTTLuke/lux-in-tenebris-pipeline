#!/usr/bin/env python3
"""
wire_articles.py — Deterministic AI-news retrieval + grounded article writing.

Two strictly separated stages:

  STAGE 1 (DETERMINISTIC, pure code — no LLM):
     fetch RSS feed(s) -> keyword filter (AI only) -> resolve real publisher URL
     -> download the source article -> extract readable text -> dedup -> rank.
     Same input always yields the same selection. No model involved.

  STAGE 2 (THE ONLY LLM CALL):
     for each selected item, call `hermes chat -q` ONCE with a tightly
     controlled prompt built from the facts fetched in Stage 1. The model
     writes an ORIGINAL article grounded in that text, attributes the source,
     and is forbidden from inventing quotes/numbers.

Output: a JSON array of articles on stdout's sibling file (OUTPUT_PATH), plus a
one-line JSON status on stdout (same convention as render.py).

Usage:
    python3 wire_articles.py                 # full run (retrieval + writing)
    python3 wire_articles.py --dry-run       # Stage 1 only: show what WOULD be written
    python3 wire_articles.py --max 3         # cap number of articles

Dependencies: standard library only is enough. `trafilatura` is used if present
(far better article extraction); otherwise a crude HTML stripper is the fallback.
    pip install trafilatura      # recommended, optional
"""

import sys
import os
import re
import json
import html
import base64
import argparse
import subprocess
from pathlib import Path
from datetime import datetime, timezone
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import xml.etree.ElementTree as ET

# ----------------------------------------------------------------------------
# CONFIG — tune these, nothing below should need editing for normal use.
# ----------------------------------------------------------------------------

# Feed list — single source of truth is skills/_shared/sources.md, shared
# with wire-articles' SKILL.md. Edit the JSON block under the
# "sources:wire-articles:feeds" anchor there, not here. The resolver below
# handles both Google-style links and clean publisher URLs, in case a
# Google News feed is ever added back.
SOURCES_FILE = Path(__file__).resolve().parents[2] / "skills" / "_shared" / "sources.md"
_SOURCES_TEXT = SOURCES_FILE.read_text()
_m = re.search(
    r'<!-- sources:wire-articles:feeds -->\s*```json\s*(.*?)```',
    _SOURCES_TEXT, re.S,
)
if not _m:
    raise RuntimeError(f"Could not find wire-articles feeds block in {SOURCES_FILE}")
FEEDS = json.loads(_m.group(1))

# Deterministic AI relevance filter (Stage 1). An item passes if its title+summary
# contains at least one ALLOW term AND is not dominated by a DENY term.
ALLOW = [
    'ai', 'a.i.', 'artificial intelligence', 'machine learning', 'deep learning',
    'llm', 'large language model', 'neural', 'transformer', 'openai', 'anthropic',
    'deepmind', 'gemini', 'claude', 'gpt', 'llama', 'mistral', 'qwen', 'deepseek',
    'hugging face', 'huggingface', 'diffusion', 'inference', 'fine-tun', 'agentic',
    'ai agent', 'chatbot', 'generative', 'open-weights', 'open weights', 'nvidia',
    'robot', 'humanoid', 'gpu', 'tpu', 'accelerator', 'foundation model',
]
# Words that, when present without a strong AI term, signal a false positive.
DENY = [
    'allen iverson', 'air india', 'ai-ais', 'said ai',  # extend as you see noise
]

MODEL = 'Qwen3.8-Flash-Next'   # AI model used for writing
PROVIDER = 'localAIServer'                # provider
USE_Z = False       # True -> use `hermes -z` (purest stdout) instead of `chat -q`

MAX_ITEMS = 5            # how many articles to write per run
CHAR_BUDGET = 6000       # max chars of source text fed to the model (grounding)
TARGET_WORDS = 220       # desired article length
HTTP_TIMEOUT = 20        # seconds
LLM_TIMEOUT = 180        # seconds
USER_AGENT = ('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0 Safari/537.36')

OUTPUT_PATH = '/tmp/v2/wire_articles.json'

# ----------------------------------------------------------------------------
# STAGE 1 — DETERMINISTIC RETRIEVAL (no LLM anywhere in this section)
# ----------------------------------------------------------------------------

def log(msg):
    print(msg, file=sys.stderr, flush=True)


def http_get(url, timeout=HTTP_TIMEOUT):
    """Plain GET with a browser UA. Returns text or None. Deterministic."""
    try:
        req = Request(url, headers={'User-Agent': USER_AGENT,
                                    'Accept-Language': 'en-US,en;q=0.9'})
        with urlopen(req, timeout=timeout) as r:
            charset = r.headers.get_content_charset() or 'utf-8'
            return r.read().decode(charset, errors='replace')
    except (URLError, HTTPError, TimeoutError, ValueError) as e:
        log(f'  http_get failed: {url[:70]}… ({e})')
        return None


def parse_feed(xml_text):
    """Parse RSS/Atom into a list of dicts. Stdlib only -> deterministic."""
    items = []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as e:
        log(f'  feed parse error: {e}')
        return items

    # RSS <item> and Atom <entry>
    nodes = root.iter('item')
    nodes = list(nodes) or list(root.iter(
        '{http://www.w3.org/2005/Atom}entry'))
    for n in nodes:
        def text(tag, atom=None):
            el = n.find(tag)
            if el is None and atom is not None:
                el = n.find(atom)
            return (el.text or '').strip() if el is not None and el.text else ''

        title = text('title', '{http://www.w3.org/2005/Atom}title')
        link = text('link')
        if not link:  # Atom puts the URL in an attribute
            le = n.find('{http://www.w3.org/2005/Atom}link')
            link = le.get('href', '') if le is not None else ''
        summary = text('description', '{http://www.w3.org/2005/Atom}summary')
        pub = text('pubDate') or text('{http://www.w3.org/2005/Atom}updated')
        src_el = n.find('source')
        source = (src_el.text.strip() if src_el is not None and src_el.text
                  else '')
        if title and link:
            items.append({'title': html.unescape(title),
                          'summary': html.unescape(re.sub('<[^>]+>', '', summary)),
                          'link': link, 'published': pub, 'source': source})
    return items


def is_ai_relevant(item):
    """Deterministic keyword gate. No model. Same text -> same verdict."""
    blob = f"{item['title']} {item['summary']}".lower()
    if any(d in blob for d in DENY) and not any(
            a in blob for a in ('artificial intelligence', 'llm', 'openai',
                                'anthropic', 'machine learning')):
        return False
    return any(a in blob for a in ALLOW)


def resolve_url(url):
    """
    Turn a Google News redirect link into the real publisher URL.
    Two deterministic strategies; clean links pass straight through.
    NOTE: Google occasionally changes its token format — this resolver is the
    one spot to revisit if links stop resolving.
    """
    if 'news.google.com' not in url:
        return url
    m = re.search(r'/articles/([A-Za-z0-9_\-]+)', url)
    if m:
        token = m.group(1)
        try:
            raw = base64.urlsafe_b64decode(token + '=' * (-len(token) % 4))
            found = re.search(rb'https?://[^\x00-\x1f"\\\s]+', raw)
            if found:
                return found.group(0).decode('utf-8', 'ignore')
        except Exception:
            pass
    # Fallback: follow the redirect and take the final URL.
    try:
        req = Request(url, headers={'User-Agent': USER_AGENT})
        with urlopen(req, timeout=HTTP_TIMEOUT) as r:
            final = r.geturl()
            if 'news.google.com' not in final:
                return final
    except Exception:
        pass
    return url


def crude_text(html_text):
    """Dependency-free readable-text fallback. Deterministic."""
    html_text = re.sub(r'(?is)<(script|style|nav|header|footer|aside).*?</\1>',
                       ' ', html_text)
    html_text = re.sub(r'(?is)<br\s*/?>', '\n', html_text)
    html_text = re.sub(r'(?is)</p>', '\n\n', html_text)
    text = re.sub(r'(?s)<[^>]+>', ' ', html_text)
    text = html.unescape(text)
    text = re.sub(r'[ \t]+', ' ', text)
    text = re.sub(r'\n\s*\n\s*\n+', '\n\n', text)
    return text.strip()


def fetch_article_text(url):
    """Download + extract readable body. trafilatura if available, else crude."""
    raw = http_get(url)
    if not raw:
        return None
    try:
        import trafilatura
        extracted = trafilatura.extract(raw, include_comments=False,
                                        include_tables=False, favor_precision=True)
        if extracted and len(extracted) > 200:
            return extracted[:CHAR_BUDGET]
    except ImportError:
        pass
    except Exception as e:
        log(f'  trafilatura failed, using fallback ({e})')
    text = crude_text(raw)
    return text[:CHAR_BUDGET] if len(text) > 200 else None


def domain_of(url):
    m = re.search(r'https?://(?:www\.)?([^/]+)', url)
    return m.group(1) if m else ''


def norm_title(t):
    return re.sub(r'[^a-z0-9]+', ' ', t.lower()).strip()


def collect(max_items):
    """Run the full deterministic retrieval and return ranked, grounded items."""
    raw_items = []
    for feed in FEEDS:
        log(f'Fetching feed: {feed[:60]}…')
        xml_text = http_get(feed)
        if xml_text:
            raw_items.extend(parse_feed(xml_text))
    log(f'  {len(raw_items)} raw items')

    # Deterministic filter
    ai_items = [it for it in raw_items if is_ai_relevant(it)]
    log(f'  {len(ai_items)} pass the AI filter')

    # Dedup by normalized title (stable: keep first occurrence)
    seen, deduped = set(), []
    for it in ai_items:
        key = norm_title(it['title'])
        if key and key not in seen:
            seen.add(key)
            deduped.append(it)

    # Stable ordering: newest first when dates parse, else feed order preserved
    def sort_key(it):
        for fmt in ('%a, %d %b %Y %H:%M:%S %Z', '%a, %d %b %Y %H:%M:%S %z',
                    '%Y-%m-%dT%H:%M:%S%z'):
            try:
                return datetime.strptime(it['published'], fmt).timestamp()
            except (ValueError, KeyError):
                continue
        return 0.0
    deduped.sort(key=sort_key, reverse=True)

    # Resolve URLs + fetch article text for the top candidates only (bounded work)
    grounded = []
    for it in deduped:
        if len(grounded) >= max_items:
            break
        real_url = resolve_url(it['link'])
        log(f'  fetching source: {real_url[:70]}…')
        body = fetch_article_text(real_url)
        if not body:
            continue
        it['source_url'] = real_url
        it['source'] = it['source'] or domain_of(real_url)
        it['source_text'] = body
        grounded.append(it)
    log(f'  {len(grounded)} items grounded with source text')
    return grounded


# ----------------------------------------------------------------------------
# STAGE 2 — THE SINGLE, CONTROLLED LLM CALL (writing only)
# ----------------------------------------------------------------------------

def build_prompt(item):
    """The model sees ONLY this: instructions + the fetched facts. Nothing else."""
    model_name = os.environ.get('WIRE_MODEL', MODEL)
    return f"""You are a tech-news writer for an AI daily called "Lux in Tenebris".
Write ONE original short article in ENGLISH based ONLY on the source text below.

STRICT RULES:
- Use ONLY facts present in the SOURCE TEXT. Do NOT add numbers, dates, names or
  quotes that are not in it. If a detail is missing, leave it out.
- Write in your OWN words. Do NOT copy or closely paraphrase the source's sentences.
- Neutral, factual, concise — about {TARGET_WORDS} words.
- Attribute clearly in the body (e.g. "according to {{SOURCE}}").
- End with a brief editorial note in *italics* (one sentence, personal take).
- After the editorial note, add a new line with: *— Written by AI ({model_name})*

OUTPUT FORMAT (exactly this, nothing else):
- Line 1: the headline (plain text, no markdown, no quotes)
- Line 2: blank
- Then: the article body in plain prose.
- Then: the editorial note wrapped in *asterisks*.
- Then: the AI signature wrapped in *asterisks*.

SOURCE: {item['source']}
ORIGINAL HEADLINE: {item['title']}

SOURCE TEXT:
\"\"\"
{item['source_text']}
\"\"\"
"""


def call_hermes(prompt):
    """Invoke hermes once, capture only the final text. Returns str or None."""
    if USE_Z:
        cmd = ['hermes', '-z', prompt]
    else:
        cmd = ['hermes', 'chat', '--quiet', '-q', prompt]
    if MODEL:
        cmd += ['--model', MODEL]
    if PROVIDER:
        cmd += ['--provider', PROVIDER]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=LLM_TIMEOUT)
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log(f'  hermes call failed: {e}')
        return None
    if res.returncode != 0:
        log(f'  hermes exit {res.returncode}: {res.stderr.strip()[:200]}')
        return None
    # Filter out hermes warning lines from the output
    lines = res.stdout.strip().splitlines()
    clean = [l for l in lines if not l.startswith('Warning:')]
    return '\n'.join(clean).strip() or None


def write_article(item):
    """Stage 2 for one item -> structured article dict, or None on failure."""
    out = call_hermes(build_prompt(item))
    if not out:
        return None
    lines = out.splitlines()
    headline = lines[0].strip().strip('"').strip('#').strip()
    body = '\n'.join(lines[1:]).strip() if len(lines) > 1 else ''
    if not headline or not body:
        return None
    return {
        'headline': headline,
        'body': body,
        'source': item['source'],
        'source_url': item['source_url'],
        'original_title': item['title'],
        'published': item.get('published', ''),
        'generated_at': datetime.now(timezone.utc).isoformat(),
    }


# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true',
                    help='Stage 1 only: list selected items, skip the LLM.')
    ap.add_argument('--max', type=int, default=MAX_ITEMS)
    ap.add_argument('--out', default=OUTPUT_PATH)
    ap.add_argument('--model', default=None,
                    help='Override model (default: Qwen3.8-Flash-Next)')
    ap.add_argument('--provider', default=None,
                    help='Override provider (default: localAIServer)')
    args = ap.parse_args()

    # Override model/provider from args if provided
    if args.model:
        globals()['MODEL'] = args.model
    if args.provider:
        globals()['PROVIDER'] = args.provider

    grounded = collect(args.max)

    if args.dry_run:
        preview = [{'title': g['title'], 'source': g['source'],
                    'source_url': g['source_url'],
                    'chars': len(g['source_text'])} for g in grounded]
        print(json.dumps({'status': 'ok', 'stage': 'retrieval-only',
                          'selected': preview}, indent=2))
        return

    articles = []
    for g in grounded:
        log(f'Writing: {g["title"][:60]}…')
        art = write_article(g)
        if art:
            articles.append(art)

    try:
        with open(args.out, 'w', encoding='utf-8') as f:
            json.dump(articles, f, ensure_ascii=False, indent=2)
    except OSError as e:
        print(json.dumps({'status': 'error', 'error': str(e)}))
        sys.exit(1)

    print(json.dumps({'status': 'ok', 'output': args.out,
                      'written': len(articles),
                      'selected': len(grounded)}))


if __name__ == '__main__':
    main()
