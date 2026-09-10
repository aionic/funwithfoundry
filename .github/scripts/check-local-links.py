"""Check local Markdown and HTML link targets without requesting external URLs."""

import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt


class HtmlLinks(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.targets: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for name, value in attrs:
            if value and ((tag == "a" and name == "href") or (tag == "img" and name == "src")):
                self.targets.append(value)


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    markdown = MarkdownIt("commonmark")
    failures: list[str] = []
    checked = 0
    for filename in sys.argv[1:]:
        source = root / filename
        targets: list[str] = []
        for block in markdown.parse(source.read_text(encoding="utf-8-sig")):
            for token in [block, *(block.children or [])]:
                if token.type in ("link_open", "image"):
                    target = token.attrGet("href" if token.type == "link_open" else "src")
                    if target:
                        targets.append(target)
                elif token.type in ("html_block", "html_inline"):
                    html = HtmlLinks()
                    html.feed(token.content)
                    targets.extend(html.targets)
        for target in targets:
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            relative = unquote(parsed.path)
            destination = root / relative.lstrip("/") if relative.startswith("/") else source.parent / relative
            checked += 1
            if not destination.exists():
                failures.append(f"{filename}: missing local link target {target}")
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"Local file links checked: {checked}; missing: {len(failures)}. External URLs and fragments are not checked.")
    return int(bool(failures) or not sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
