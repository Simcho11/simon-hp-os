#!/usr/bin/env python3
"""Builds the HP-OS User Guide: HTML -> PDF with Chrome, twice (the second pass fills in page numbers)."""
import html, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, "img")
CHROME = os.path.expanduser("~/.nix-profile/bin/google-chrome-stable")
PDFTOTEXT = "/nix/store/ffafgfpymilqh8zcbhl0kwfh96ajgvjx-poppler-utils-26.10.0/bin/pdftotext"
VERSION = "2026.11.19.4"
EDITION = "Edition 4 · November 2026"

def img(name):
    return "file://" + os.path.join(IMG, name)

# ---------------------------------------------------------------- content helpers
def p(t): return f"<p>{t}</p>"
def ul(*items): return "<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>"
def steps(*items): return '<ol class="steps">' + "".join(f"<li>{i}</li>" for i in items) + "</ol>"
def k(*keys): return "".join(f"<kbd>{x.replace('_', ' ')}</kbd>" for x in keys)
def keys(s): return "+".join(k(x) for x in s.split("+"))
def note(t, kind="tip", title=None):
    title = title or {"tip": "Tip", "note": "Note", "warn": "Important"}[kind]
    return f'<div class="callout {kind}"><div class="ct">{title}</div><div>{t}</div></div>'
def fig(name, caption, cls="wide"):
    return f'<figure class="{cls}"><img src="{img(name)}"><figcaption>{caption}</figcaption></figure>'
def table(head, rows, cls=""):
    h = "".join(f"<th>{c}</th>" for c in head)
    b = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f'<table class="{cls}"><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table>'
def side(text, image, caption):
    return f'<div class="side"><div class="side-text">{text}</div><figure class="narrow"><img src="{img(image)}"><figcaption>{caption}</figcaption></figure></div>'

chapters = []   # (id, number, title, intro, html)
def chapter(cid, title, intro, *parts):
    chapters.append((cid, len(chapters) + 1, title, intro, "".join(parts)))
def h2(cid, t): return f'<h2 id="{cid}">{t}</h2>'
def h3(t): return f"<h3>{t}</h3>"

exec(open(os.path.join(HERE, "content.py")).read())
def keycombo(s):
    if s.startswith("!"): return s[1:]
    out = []
    for part in s.split("  /  ") if "  /  " in s else [s]:
        bits = re.split(r"\+(?=.)", part.replace(" / ", " / "))
        out.append("+".join(k(b) if b.strip() not in ("…",) else b for b in bits))
    return " / ".join(out)
appendix = "".join(
    f'<div class="sc-group"><h3>{g}</h3>' + table(["Shortcut", "Action"], [[keycombo(a), b] for a, b in rows], "shortcuts") + "</div>"
    for g, rows in shortcut_groups)

# ---------------------------------------------------------------- page assembly
def build(page_numbers):
    toc_rows = ['<div class="toc-list">']
    for cid, n, title, intro, body in chapters:
        pg = page_numbers.get(cid, "")
        toc_rows.append(f'<div class="toc-group"><a class="toc-ch" href="#{cid}"><span class="n">{n:02d}</span><span class="t">{title}</span><span class="dots"></span><span class="pg">{pg}</span></a>')
        for sid, st in re.findall(r'<h2 id="([^"]+)">([^<]+)</h2>', body):
            toc_rows.append(f'<a class="toc-sec" href="#{sid}"><span class="t">{st}</span><span class="dots"></span><span class="pg">{page_numbers.get(sid, "")}</span></a>')
        toc_rows.append('</div>')
    toc_rows.append(f'<div class="toc-group"><a class="toc-ch" href="#shortcuts"><span class="n">A</span><span class="t">Keyboard Shortcuts</span><span class="dots"></span><span class="pg">{page_numbers.get("shortcuts", "")}</span></a></div></div>')

    body = []
    for cid, n, title, intro, html_ in chapters:
        body.append(f'<section class="chapter"><header class="ch-head" id="{cid}" data-marker="CHAPTER-{cid}">'
                    f'<div class="ch-num">Chapter {n}</div><h1>{title}</h1><p class="lede">{intro}</p></header>{html_}</section>')
    body.append(f'<section class="chapter"><header class="ch-head" id="shortcuts"><div class="ch-num">Appendix</div>'
                f'<h1>Keyboard Shortcuts</h1><p class="lede">{k("Super")} is the key with the Windows logo. '
                f'Press {keys("Super+Shift+/")} on your device to see them all at any time.</p></header>'
                f'<div class="sc-grid">{appendix}</div></section>')

    css = open(os.path.join(HERE, "manual.css")).read()
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>HP-OS User Guide</title>
<style>{css}</style></head><body>
<section class="cover">
  <div class="cover-art" style="background-image:url('{img("cover.jpg")}')"></div>
  <div class="cover-veil"></div>
  <div class="cover-top"><span class="brand">HP-OS</span></div>
  <div class="cover-title"><div class="kicker">User Guide</div><h1>HP-OS</h1>
    <p>For HP laptops</p></div>
  <div class="cover-foot"><span>Version {VERSION}</span><span>{EDITION}</span></div>
</section>
<section class="toc"><h1 class="toc-title">Contents</h1>{''.join(toc_rows)}</section>
{''.join(body)}
<section class="colophon"><div>
<h2>HP-OS User Guide</h2>
<p>Version {VERSION} · {EDITION}</p>
<p>HP-OS is built on Ubuntu 26.04 LTS. Its desktop is based on iNiR by snowarch and the niri window manager, with HP-OS’s own design and additions.</p>
<p>Microsoft 365, Word, Excel, PowerPoint, Outlook, Teams, OneDrive, OneNote and SharePoint are trademarks of Microsoft Corporation. Google Chrome is a trademark of Google LLC. Ubuntu is a trademark of Canonical Ltd. HP and OmniBook are trademarks of HP Inc. Intel is a trademark of Intel Corporation. AMD is a trademark of Advanced Micro Devices, Inc. Other names may be trademarks of their respective owners.</p>
<p>Features described in this guide may change with software updates. Screens show HP-OS in its standard light appearance and are representative; your device may look different if you’ve chosen another wallpaper, color or dark mode.</p>
</div></section>
</body></html>"""

def render(html_text, out_pdf):
    src = os.path.join(HERE, "manual.html")
    open(src, "w").write(html_text)
    prof = os.path.join(HERE, ".chrome-profile")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--no-sandbox", f"--user-data-dir={prof}",
                    "--no-pdf-header-footer", "--allow-file-access-from-files", f"--print-to-pdf={out_pdf}",
                    "--virtual-time-budget=8000", "file://" + src], check=True, capture_output=True, timeout=180)

def find_pages(pdf):
    """Page number (as printed) for each chapter and section heading."""
    pages = []
    n = int(re.search(r"Pages:\s+(\d+)", subprocess.run(["/nix/store/ffafgfpymilqh8zcbhl0kwfh96ajgvjx-poppler-utils-26.10.0/bin/pdfinfo", pdf], capture_output=True, text=True).stdout).group(1))
    for i in range(1, n + 1):
        pages.append(subprocess.run([PDFTOTEXT, "-f", str(i), "-l", str(i), "-layout", pdf, "-"], capture_output=True, text=True).stdout)
    def norm(s): return re.sub(r"\s+", " ", s).strip()
    found = {}
    start = 3   # cover and contents are not numbered in the text search
    for cid, num, title, intro, body in chapters:
        for i in range(start - 1, n):
            if f"chapter {num}" in pages[i].lower() and all(w in pages[i].lower() for w in norm(title).lower().split()):
                found[cid] = i + 1; start = i + 1; break
        for sid, st in re.findall(r'<h2 id="([^"]+)">([^<]+)</h2>', body):
            t = html.unescape(st)
            for i in range(start - 1, n):
                if norm(t) in norm(pages[i]):
                    found[sid] = i + 1; start = i + 1; break
    for i in range(start - 1, n):
        if "appendix" in pages[i].lower() and "keyboard" in pages[i].lower() and "shortcuts" in pages[i].lower():
            found["shortcuts"] = i + 1; break
    return found, n

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "HP-OS User Guide.pdf")
    first = os.path.join(HERE, "pass1.pdf")
    render(build({}), first)
    pages, n = find_pages(first)
    for attempt in range(4):
        render(build(pages), out)
        pages2, n2 = find_pages(out)
        if pages2 == pages: break
        pages = pages2
    print(json.dumps({"pages": n2, "stable": pages == pages2, "passes": attempt + 2, "missing": [c[0] for c in chapters if c[0] not in pages2]}))
