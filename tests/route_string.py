"""Builds Pullwise route strings the way the website does: "!PW1!" + base64(raw DEFLATE(JSON))."""

import base64
import json
import sys
import zlib


def encode(route: dict, prefix: str = "!PW1!") -> str:
    data = json.dumps(route, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw DEFLATE, no zlib header
    packed = deflate.compress(data) + deflate.flush()
    return prefix + base64.b64encode(packed).decode("ascii")


def decode(text: str) -> dict:
    assert text.startswith("!PW1!")
    return json.loads(zlib.decompress(base64.b64decode(text[5:]), -15))


if __name__ == "__main__":
    # python3 tests/route_string.py route.json  -> prints the string
    with open(sys.argv[1], encoding="utf-8") as f:
        print(encode(json.load(f)))
