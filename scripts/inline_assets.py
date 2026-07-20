#!/usr/bin/env python3
"""Inline CSS and JS into index.html for file:// loading in sandboxed WKWebView.

WKWebView in App Sandbox blocks file:// sub-resource loading (external CSS/JS).
This script inlines style.css and app.js directly into index.html so the page
renders correctly when loaded via file:// protocol.
"""
import sys

def inline(html_path: str, css_path: str, js_path: str) -> None:
    with open(html_path) as f:
        html = f.read()
    with open(css_path) as f:
        css = f.read()
    with open(js_path) as f:
        js = f.read()
    html = html.replace(
        '<link rel="stylesheet" href="style.css">',
        '<style>' + css + '</style>',
    )
    html = html.replace(
        '<script src="app.js"></script>',
        '<script>' + js + '</script>',
    )
    with open(html_path, 'w') as f:
        f.write(html)
    print(f'Inlined CSS ({len(css)} bytes) + JS ({len(js)} bytes) -> {html_path} ({len(html)} bytes)')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f'Usage: {sys.argv[0]} <index.html> <style.css> <app.js>')
        sys.exit(1)
    inline(sys.argv[1], sys.argv[2], sys.argv[3])
