"""Tests for the parts of the add-on that don't need the game: reading route strings and
putting shared routes back together. Runs the real Lua files in Lua 5.1 (the game's version)
with the game's encoding functions stood in for by Python's.

    python3 -m pip install lupa
    python3 -m unittest discover tests
"""

import base64
import json
import os
import unittest
import zlib

from lupa import lua51

from route_string import encode

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SAMPLE = {
    "v": 1,
    "dungeon": 9999,
    "total": 460,
    "title": "Test route",
    "stops": [
        {"forces": 44, "note": "Corner pull"},
        {"boss": 99991},
        {"forces": 92},
    ],
}


def load():
    # latin-1 passes every byte through unchanged, so binary data and UTF-8 text cross intact.
    lua = lua51.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
    g = lua.globals()

    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        if isinstance(value, str):
            return value.encode("utf-8")
        return value

    def decode_base64(text, variant=None):
        return base64.b64decode(text, validate=True)

    def decompress(data, method):
        assert method == 0
        return zlib.decompress(data.encode("latin-1"), -15)

    def deserialize(text):
        return to_lua(json.loads(text.encode("latin-1").decode("utf-8")))

    g.C_EncodingUtil = lua.table_from(
        {"DecodeBase64": decode_base64, "DecompressString": decompress, "DeserializeJSON": deserialize}
    )
    g.Enum = lua.table_from({"CompressionMethod": lua.table_from({"Deflate": 0})})
    ns = lua.table()
    for name in ("Route.lua", "Share.lua"):
        with open(os.path.join(ROOT, name), encoding="utf-8") as f:
            lua.eval(
                "function(src, ns) return assert(loadstring(src))('Pullwise', ns) end"
            )(f.read(), ns)
    return lua, ns


def text(value):
    """A Lua string as the player would read it (the runtime hands it back byte for byte)."""
    return None if value is None else value.encode("latin-1").decode("utf-8")


class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua, cls.ns = load()
        cls.Route = cls.ns.Route

    def decode(self, text):
        return self.Route.Decode(text)

    def assertFails(self, text, code):
        route, result = self.decode(text)
        self.assertIsNone(route)
        self.assertEqual(result, code)
        self.assertIsNotNone(self.Route.MESSAGES[code])

    def test_reads_a_route(self):
        text = encode(SAMPLE)
        route, cleaned = self.decode(text)
        self.assertEqual(cleaned, text)
        self.assertEqual(route.dungeon, 9999)
        self.assertEqual(route.total, 460)
        self.assertEqual(route.title, "Test route")
        self.assertEqual(route.stops[1].forces, 44)
        self.assertEqual(route.stops[1].note, "Corner pull")
        self.assertEqual(route.stops[2].boss, 99991)
        self.assertIsNone(route.stops[3].note)

    def test_sample_file_reads(self):
        with open(os.path.join(ROOT, "tests", "sample-route.json"), encoding="utf-8") as f:
            route, _ = self.decode(encode(json.load(f)))
        self.assertIsNotNone(route)

    def test_rows_number_pulls_and_running_percent(self):
        route, _ = self.decode(encode(SAMPLE))
        rows = self.Route.Rows(route)
        self.assertEqual(rows[1].pull, 1)
        self.assertAlmostEqual(rows[1].percent, 44 / 460 * 100)
        self.assertEqual(rows[2].boss, 99991)
        self.assertEqual(rows[3].pull, 2)
        self.assertAlmostEqual(rows[3].running, 136 / 460 * 100)

    def test_ignores_spaces_and_line_breaks_from_pasting(self):
        text = encode(SAMPLE)
        messy = "  " + text[:20] + "\n" + text[20:40] + " \t" + text[40:] + "\r\n"
        route, cleaned = self.decode(messy)
        self.assertIsNotNone(route)
        self.assertEqual(cleaned, text)

    def test_ignores_fields_it_doesnt_know(self):
        data = dict(SAMPLE, source="pullwise.gg", future={"x": 1})
        data["stops"] = [dict(SAMPLE["stops"][0], npcs=[[123, 2]])] + SAMPLE["stops"][1:]
        route, _ = self.decode(encode(data))
        self.assertIsNotNone(route)

    def test_empty_and_wrong_strings(self):
        self.assertFails("", "empty")
        self.assertFails("   \n", "empty")
        self.assertFails(None, "empty")
        self.assertFails("!WA:2!abc", "not_pullwise")
        self.assertFails("hello", "not_pullwise")
        self.assertFails("!PW2!abcd", "newer_version")
        self.assertFails("!PW1!" + "A" * 20000, "too_long")

    def test_damaged_strings(self):
        text = encode(SAMPLE)
        self.assertFails("!PW1!", "corrupt")
        self.assertFails("!PW1!@@@@", "corrupt")
        self.assertFails(text[:-12], "corrupt")
        self.assertFails("!PW1!" + base64.b64encode(b"not deflate at all").decode(), "corrupt")
        raw = zlib.compressobj(9, zlib.DEFLATED, -15)
        notjson = raw.compress(b"{not json") + raw.flush()
        self.assertFails("!PW1!" + base64.b64encode(notjson).decode(), "corrupt")

    def test_missing_or_wrong_fields(self):
        def without(key):
            return {k: v for k, v in SAMPLE.items() if k != key}

        for key in ("v", "dungeon", "total", "stops"):
            self.assertFails(encode(without(key)), "invalid")
        self.assertFails(encode(dict(SAMPLE, v=2)), "invalid")
        self.assertFails(encode(dict(SAMPLE, total=0)), "invalid")
        self.assertFails(encode(dict(SAMPLE, total="460")), "invalid")
        self.assertFails(encode(dict(SAMPLE, dungeon=-1)), "invalid")
        self.assertFails(encode(dict(SAMPLE, dungeon=1.5)), "invalid")
        self.assertFails(encode(dict(SAMPLE, season="one")), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops=[])), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops={"a": 1})), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops=[{"boss": 1}])), "invalid")  # no pulls
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": -3}])), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": 2.5}])), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": 3}, {"note": "x"}])), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": 3}, "pull"])), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": 3}, {"boss": 0}])), "invalid")
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": 3}, {"boss": 99991, "forces": 40}])), "invalid")
        self.assertFails(encode([1, 2, 3]), "invalid")

    def test_deep_nesting_is_rejected_before_parsing(self):
        deep = [1]
        for _ in range(50):
            deep = [deep]
        self.assertFails(encode(dict(SAMPLE, extra=deep)), "invalid")
        route, _ = self.decode(encode(dict(SAMPLE, title="[[[[{{{{[[[[{{{{ \\\" [[[[")))
        self.assertIsNotNone(route)  # brackets inside text don't count

    def test_a_gap_in_the_stops_is_rejected(self):
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": 3}, None, {"forces": 4}])), "invalid")

    def test_invisible_and_direction_characters_are_removed(self):
        route, _ = self.decode(encode(dict(SAMPLE, title="Safe\u202eetirW\u200b\u2066x\ufeff")))
        self.assertEqual(text(route.title), "SafeetirWx")

    def test_too_many_stops(self):
        self.assertFails(encode(dict(SAMPLE, stops=[{"forces": 1}] * 121)), "too_many_stops")
        route, _ = self.decode(encode(dict(SAMPLE, stops=[{"forces": 1}] * 120)))
        self.assertIsNotNone(route)

    def test_text_is_made_safe_for_the_game(self):
        data = dict(SAMPLE, title="|cffff0000Red|r |Hitem:1|h[x]|h", author="  ")
        data["stops"] = [{"forces": 3, "note": "line one\nline two\ttab  spaced"}]
        route, _ = self.decode(encode(data))
        self.assertEqual(route.title, "||cffff0000Red||r ||Hitem:1||h[x]||h")
        self.assertIsNone(route.author)
        self.assertEqual(route.stops[1].note, "line one line two tab spaced")

    def test_long_text_is_cut_without_breaking_characters(self):
        data = dict(SAMPLE, title="é" * 100)  # two bytes each
        route, _ = self.decode(encode(data))
        self.assertEqual(text(route.title), "é" * 40)
        data = dict(SAMPLE, title="a" + "€" * 100)  # three bytes each, cut lands mid-character
        route, _ = self.decode(encode(data))
        self.assertEqual(text(route.title), "a" + "€" * 26)
        note = "x" * 300
        route, _ = self.decode(encode(dict(SAMPLE, stops=[{"forces": 1, "note": note}])))
        self.assertEqual(len(route.stops[1].note), 200)


class ShareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua, cls.ns = load()
        cls.Share = cls.ns.Share

    def messages(self, text, id="ab12"):
        out = self.Share.Split(text, id)
        return [out[i] for i in range(1, len(out) + 1)]

    def test_split_fits_in_one_message_each(self):
        text = encode(dict(SAMPLE, stops=[{"forces": i, "note": "note %d" % i} for i in range(1, 120)]))
        for m in self.messages(text):
            self.assertLessEqual(len(m), 255)

    def test_reassembles_in_any_order(self):
        text = encode(dict(SAMPLE, stops=[{"forces": i, "note": "n%d" % i} for i in range(1, 60)]))
        parts = self.messages(text)
        self.assertGreater(len(parts), 2)
        pending = self.lua.table()
        order = list(reversed(parts))
        results = [self.Share.Accept(pending, "Ally-Realm", m, 10) for m in order]
        self.assertTrue(all(r is None for r in results[:-1]))
        self.assertEqual(results[-1], text)
        self.assertIsNone(next(iter(pending.keys()), None))

    def test_duplicate_pieces_dont_complete_early(self):
        parts = self.messages("A" * 450)  # three pieces
        pending = self.lua.table()
        self.assertIsNone(self.Share.Accept(pending, "P", parts[0], 1))
        self.assertIsNone(self.Share.Accept(pending, "P", parts[0], 1))
        self.assertIsNone(self.Share.Accept(pending, "P", parts[1], 1))
        self.assertEqual(self.Share.Accept(pending, "P", parts[2], 1), "A" * 450)

    def test_senders_are_kept_apart(self):
        a, b = self.messages("A" * 300, "aaaa"), self.messages("B" * 300, "bbbb")
        pending = self.lua.table()
        self.assertIsNone(self.Share.Accept(pending, "One", a[0], 1))
        self.assertIsNone(self.Share.Accept(pending, "Two", b[0], 1))
        self.assertEqual(self.Share.Accept(pending, "One", a[1], 1), "A" * 300)
        self.assertEqual(self.Share.Accept(pending, "Two", b[1], 1), "B" * 300)

    def test_late_piece_of_an_older_route_doesnt_push_out_the_new_one(self):
        old, new = self.messages("A" * 300, "aaaa"), self.messages("B" * 300, "bbbb")
        pending = self.lua.table()
        self.Share.Accept(pending, "One", new[0], 1)
        self.Share.Accept(pending, "One", old[1], 1)
        self.assertEqual(self.Share.Accept(pending, "One", new[1], 1), "B" * 300)

    def test_a_sender_holds_two_unfinished_routes_at_most(self):
        pending = self.lua.table()
        self.Share.Accept(pending, "One", "aa:1:2:x", 1)
        self.Share.Accept(pending, "One", "bb:1:2:x", 2)
        self.Share.Accept(pending, "One", "cc:1:2:x", 3)
        self.assertEqual(len(list(pending.keys())), 2)
        self.assertIsNone(self.Share.Accept(pending, "One", "aa:2:2:y", 4))  # oldest was dropped
        self.assertEqual(self.Share.Accept(pending, "One", "cc:2:2:y", 4), "xy")

    def test_unfinished_routes_expire(self):
        parts = self.messages("A" * 300)
        pending = self.lua.table()
        self.Share.Accept(pending, "One", parts[0], 1)
        self.assertIsNone(self.Share.Accept(pending, "One", parts[1], 1 + 61))

    def test_a_slow_route_keeps_going_while_pieces_arrive(self):
        parts = self.messages("A" * 600)  # three pieces
        pending = self.lua.table()
        self.assertIsNone(self.Share.Accept(pending, "One", parts[0], 1))
        self.assertIsNone(self.Share.Accept(pending, "One", parts[1], 14))
        self.assertEqual(self.Share.Accept(pending, "One", parts[2], 27), "A" * 600)

    def test_rejects_malformed_messages(self):
        pending = self.lua.table()
        for bad in ("", "x", "ab:1:2", "ab:0:2:x", "ab:3:2:x", "ab:1:0:x", "ab:1:999:x", "a-b:1:1:x", "ab:x:1:y"):
            self.assertIsNone(self.Share.Accept(pending, "One", bad, 1), bad)
        self.assertIsNone(next(iter(pending.keys()), None))

    def test_piece_count_must_match(self):
        pending = self.lua.table()
        self.Share.Accept(pending, "One", "ab:1:3:x", 1)
        self.assertIsNone(self.Share.Accept(pending, "One", "ab:2:2:y", 1))
        self.assertIsNone(self.Share.Accept(pending, "One", "ab:3:3:z", 1))

    def test_holds_a_limited_number_of_unfinished_routes(self):
        pending = self.lua.table()
        for i in range(15):
            self.Share.Accept(pending, "P%d" % i, "ab:1:2:x", 1)
        self.assertEqual(len(list(pending.keys())), 10)

    def test_single_piece_route(self):
        pending = self.lua.table()
        self.assertEqual(self.Share.Accept(pending, "One", "ab:1:1:hello", 1), "hello")


if __name__ == "__main__":
    unittest.main()
