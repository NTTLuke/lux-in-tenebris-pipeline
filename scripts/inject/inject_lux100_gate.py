#!/usr/bin/env python3
"""
inject_lux100_gate.py — Post-process Lux in Tenebris HTML to add the Edition-100
celebration gate (fullscreen LVX Fragments game) ONLY when the issue number is 100.

Behaviour:
  * issue == 100  → injects the gate overlay + copies the game HTML + image
                    into the deploy/render dir so the site can serve them.
  * issue != 100  → no-op (newspaper renders exactly as normal).

The gate never touches the newspaper's own CSS/fonts: it adds a fixed fullscreen
overlay with a prefixed (l100-*) stylesheet and an <iframe> hosting the standalone
game. Layout/content of index.html itself is untouched.

Usage:
    python3 inject_lux100_gate.py <index.html> <NEXT_ISSUE> [--game PATH] [--image PATH] [--output PATH]
"""
import os, sys, re, shutil, argparse

# ──────────────────────────────────────────────────────────────
# The game iframe + skip button + win card. Everything is scoped
# under l100-* so it can never collide with Lux's own classes.
# ──────────────────────────────────────────────────────────────
GAME_FILENAME = "lux-fragments-100.html"
IMAGE_FILENAME = "lux100.png"

def build_css():
    return (
        # Gate: fullscreen cover, sits ABOVE the newspaper but below no header
        # of its own — it IS the screen when active.
        ".l100-gate{position:fixed;inset:0;z-index:9001;display:flex;"
        "flex-direction:column;background:#0a0b0e;}"

        ".l100-panel{flex:1;position:relative;}"
        ".l100-frame{width:100%;height:100%;border:0;display:block;}"

        # Skip button pinned to the bottom of the game panel.
        ".l100-skipwrap{position:absolute;bottom:0;left:0;right:0;"
        "display:flex;justify-content:center;padding:18px;"
        "background:linear-gradient(transparent,rgba(10,11,14,.94));}"
        ".l100-skip{border:1px solid #725332;background:#101014;color:#d9cbb4;"
        "font:13px Inter,Arial,sans-serif;padding:11px 18px;border-radius:4px;"
        "cursor:pointer;letter-spacing:.03em;transition:.2s;}"
        ".l100-skip:hover{border-color:#c99a51;color:#c99a51;}"

        # Win card: shown after the game reports completion.
        ".l100-win{position:fixed;inset:0;z-index:9100;background:rgba(7,8,11,.9);"
        "display:flex;align-items:center;justify-content:center;padding:20px;}"
        ".l100-winbox{border:1px solid #725332;background:#0d0e12;"
        "max-width:880px;width:100%;text-align:center;padding:0 0 30px;"
        "border-radius:6px;overflow:hidden;}"
        ".l100-winbox img{width:100%;display:block;border-bottom:1px solid #2a2822;}"
        ".l100-winbox h2{font-family:Newsreader,Georgia,serif;font-size:28px;"
        "margin:22px 0 6px;color:#efe6d5;}"
        ".l100-winbox p{color:#a8906b;font:13px Inter,Arial,sans-serif;margin-bottom:20px;}"
        ".l100-enter{border:1px solid #c99a51;background:#c99a51;color:#191410;"
        "font:13px Inter,Arial,sans-serif;font-weight:600;padding:12px 26px;"
        "border-radius:4px;cursor:pointer;}"
        ".l100-enter:hover{filter:brightness(1.08);}"
        ".l100-hidden{display:none!important;}"
    )

def build_markup():
    return (
        '<div class="l100-gate" id="l100-gate">'
        '  <div class="l100-panel">'
        f'    <iframe class="l100-frame" id="l100-frame" src="{GAME_FILENAME}" '
        'title="LVX Fragments" allow="fullscreen" allowfullscreen></iframe>'
        '    <div class="l100-skipwrap"><button class="l100-skip" id="l100-skip" '
        'type="button">I don&#39;t want to play, just read</button></div>'
        '  </div>'
        '</div>'
        '<div class="l100-win l100-hidden" id="l100-win">'
        '  <div class="l100-winbox">'
        f'    <img id="l100-winimg" src="{IMAGE_FILENAME}" alt="The hundredth light">'
        '    <h2>The image is complete</h2>'
        '    <p>The hundredth light has returned home. On to the news.</p>'
        '    <button class="l100-enter" id="l100-enter" type="button">'
        'Read the newspaper — Edition 100</button>'
        '  </div>'
        '</div>'
    )

def build_js():
    return (
        "(function(){"
        "var g=document.getElementById('l100-gate'),"
        "f=document.getElementById('l100-frame'),"
        "s=document.getElementById('l100-skip'),"
        "w=document.getElementById('l100-win');"
        "function closeGate(){if(g)g.style.display='none';}"
        "window.addEventListener('message',function(e){"
        "if(e.data&&e.data.type==='lux-game-complete'){"
        "if(f)f.style.display='none';"
        "var sw=document.querySelector('.l100-skipwrap');if(sw)sw.style.display='none';"
        "if(w)w.classList.remove('l100-hidden');"
        "}});"
        "if(s)s.addEventListener('click',closeGate);"
        "var en=document.getElementById('l100-enter');if(en)en.addEventListener('click',closeGate);"
        "window.addEventListener('load',function(){try{var fr=document.getElementById('l100-frame');"
        "if(fr)fr.focus();}catch(e){}});"
        "})();"
    )

def main():
    ap = argparse.ArgumentParser(description='Inject Edition-100 celebration gate')
    ap.add_argument('html', help='Path to rendered index.html')
    ap.add_argument('issue', help='Next issue number (deploy issue)')
    ap.add_argument('--game', default=None, help='Path to game HTML to copy (optional)')
    ap.add_argument('--image', default=None, help='Path to image to copy (optional)')
    ap.add_argument('--output', '-o', default=None)
    args = ap.parse_args()

    try:
        issue = int(args.issue)
    except (TypeError, ValueError):
        print(json_status('error', error=f'bad issue number: {args.issue!r}'))
        sys.exit(1)

    output = args.output or args.html
    out_dir = os.path.dirname(os.path.abspath(output))

    # Only edition 100 gets the gate. Anything else = untouched newspaper.
    if issue != 100:
        print(json_status('ok', injected=False, message='issue != 100, gate disabled'))
        return

    if not os.path.exists(args.html):
        print(json_status('error', error=f'index.html not found: {args.html}'))
        sys.exit(1)

    with open(args.html, encoding='utf-8') as f:
        html = f.read()

    # Guard against double-injection on re-runs.
    if 'id="l100-gate"' in html:
        print(json_status('ok', injected=True, message='gate already present (idempotent)'))
    else:
        html = re.sub(r'(</head>)', '<style>' + build_css() + '</style>\n\\1', html, count=1)
        html = re.sub(r'(</body>)', build_markup() + '<script>' + build_js() + '</script>\n\\1',
                      html, count=1)
        with open(output, 'w', encoding='utf-8') as f:
            f.write(html)

    # Copy the game + image next to index.html so the iframe can serve them.
    copied = []
    for src_name, dest_name in ((args.game, GAME_FILENAME), (args.image, IMAGE_FILENAME)):
        if src_name and os.path.exists(src_name):
            dest = os.path.join(out_dir, dest_name)
            shutil.copy(src_name, dest)
            copied.append(dest_name)
        else:
            print(json_status('warn', message=f'missing optional asset: {src_name}'))

    print(json_status('ok', injected=True, copied=copied))

def json_status(status, **kw):
    import json
    d = {'status': status}
    d.update(kw)
    return json.dumps(d)

if __name__ == '__main__':
    main()
