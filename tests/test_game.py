"""Loads the whole add-on against a stand-in game (fake_wow.lua) and drives it the way a player
would: import a route, open it, share it with the group, and receive one from a party member."""

import os
import unittest

from lupa import lua51

from route_string import encode
from test_addon import SAMPLE

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.dirname(os.path.abspath(__file__))
TOC = os.path.join(ROOT, "Pullwise.toc")


def addon_files():
    with open(TOC, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip().endswith(".lua")]


def start(saved=None):
    """A fresh game with the add-on loaded and ADDON_LOADED fired. `saved` is PullwiseDB from an
    earlier session, as Lua source."""
    import base64
    import json
    import zlib

    lua = lua51.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
    with open(os.path.join(HERE, "fake_wow.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    g = lua.globals()

    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        if isinstance(value, str):
            return value.encode("utf-8")
        return value

    g.C_EncodingUtil = lua.table_from(
        {
            "DecodeBase64": lambda s, v=None: base64.b64decode(s, validate=True),
            "DecompressString": lambda d, m: zlib.decompress(d.encode("latin-1"), -15),
            "DeserializeJSON": lambda s: to_lua(json.loads(s.encode("latin-1").decode("utf-8"))),
        }
    )
    g.Enum = lua.table_from({"CompressionMethod": lua.table_from({"Deflate": 0})})
    if saved:
        lua.execute("PullwiseDB = " + saved)
    ns = lua.table()
    run = lua.eval("function(src, name, ns) return assert(loadstring(src, name))('Pullwise', ns) end")
    for name in addon_files():
        with open(os.path.join(ROOT, name), encoding="utf-8") as f:
            run(f.read(), name, ns)
    g.FAKE.fire("ADDON_LOADED", "Pullwise")
    return lua, g, ns


class GameTests(unittest.TestCase):
    def setUp(self):
        self.lua, self.g, self.ns = start()
        self.fake = self.g.FAKE

    def slash(self, text):
        self.g.SlashCmdList.PULLWISE(text)

    def frame(self, name):
        return self.g[name]

    def test_import_saves_and_shows_the_route(self):
        self.slash("import")
        box = self.frame("PullwiseImportFrame").box
        self.assertTrue(self.ns.ImportText(encode(SAMPLE)))
        window = self.frame("PullwiseRouteFrame")
        self.assertTrue(window.shown)
        self.assertEqual(window.title.text, "Test Dungeon: Test route")
        self.assertEqual(window.status.text, "Route saved.")
        self.assertEqual(self.g.PullwiseDB.routes[9999].route.total, 460)
        self.assertIsNotNone(box)

    def test_bad_paste_shows_why_and_saves_nothing(self):
        ok, message = self.ns.ImportText("not a route")
        self.assertFalse(ok)
        self.assertIn("isn't a Pullwise route", message)
        self.assertIsNone(next(iter(self.g.PullwiseDB.routes.keys()), None))

    def test_import_button_reports_errors_in_the_window(self):
        self.slash("import")
        f = self.frame("PullwiseImportFrame")
        f.box.SetText(f.box, "!PW1!@@@")
        import_button = [w for w in self.fake.frames.values() if w.kind == "Button" and w.text == "Import"][0]
        import_button.Click(import_button)
        self.assertIn("damaged", f.status.text)
        self.assertTrue(f.shown)

    def test_reimport_replaces_and_says_so(self):
        self.ns.ImportText(encode(SAMPLE))
        self.ns.ImportText(encode(dict(SAMPLE, title="Second")))
        window = self.frame("PullwiseRouteFrame")
        self.assertIn("Replaced", window.status.text)
        self.assertEqual(self.g.PullwiseDB.routes[9999].route.title, "Second")

    def test_slash_with_nothing_saved_shows_empty_state(self):
        self.slash("")
        window = self.frame("PullwiseRouteFrame")
        self.assertTrue(window.shown)
        self.assertIn("No routes yet", window.summary.text)
        self.slash("")
        self.assertFalse(window.shown)

    def test_rows_show_pulls_bosses_and_notes(self):
        self.ns.ImportText(encode(SAMPLE))
        labels = [w.text for w in self.fake.frames.values() if w.kind == "FontString" and w.text]
        joined = "\n".join(labels)
        self.assertIn("Pull 1", joined)
        self.assertIn("Test Boss", joined)
        self.assertIn("+44 · 9.6%", joined)
        self.assertIn("29.6% total", joined)
        self.assertIn("Corner pull", joined)

    def test_share_sends_pieces_to_party(self):
        self.ns.ImportText(encode(SAMPLE))
        self.slash("share")
        self.fake.runTimers()
        sent = list(self.fake.sent.values())
        self.assertGreaterEqual(len(sent), 1)
        self.assertTrue(all(m.channel == "PARTY" and m.prefix == "PullwiseRoute" for m in sent))
        self.assertIn("Shared with your group", self.frame("PullwiseRouteFrame").status.text)

    def test_share_blocked_in_dungeon(self):
        self.ns.ImportText(encode(SAMPLE))
        self.fake.lockdown = True
        self.ns.ShareShown()
        self.assertIn("Share before you go in", self.frame("PullwiseRouteFrame").status.text)
        self.assertEqual(len(list(self.fake.sent.values())), 0)

    def test_share_lockdown_mid_send(self):
        self.ns.ImportText(encode(dict(SAMPLE, stops=[{"forces": i, "note": "n%d" % i} for i in range(1, 60)])))
        self.fake.sendResults = self.lua.table_from([0, 11])
        self.ns.ShareShown()
        self.fake.runTimers()
        self.assertIn("Share before you go in", self.frame("PullwiseRouteFrame").status.text)

    def test_share_retries_when_throttled(self):
        self.ns.ImportText(encode(SAMPLE))
        self.fake.sendResults = self.lua.table_from([3, 3])
        self.ns.ShareShown()
        self.fake.runTimers()
        self.assertIn("Shared with your group", self.frame("PullwiseRouteFrame").status.text)

    def test_share_needs_a_group(self):
        self.ns.ImportText(encode(SAMPLE))
        self.fake.inGroup = False
        self.ns.ShareShown()
        self.assertIn("Join a group", self.frame("PullwiseRouteFrame").status.text)

    def test_share_without_a_route(self):
        self.slash("")
        self.ns.ShareShown()
        self.assertIn("Import a route first", self.frame("PullwiseRouteFrame").status.text)

    def deliver(self, sender, sent):
        for m in sent:
            self.fake.fire("CHAT_MSG_ADDON", m.prefix, m.msg, m.channel, sender)

    def test_receiving_a_route_asks_then_saves(self):
        _, sender_g, sender_ns = start()
        sender_ns.ImportText(encode(SAMPLE))
        sender_ns.ShareShown()
        sender_g.FAKE.runTimers()
        self.deliver("Friend-Realm", list(sender_g.FAKE.sent.values()))
        popups = list(self.fake.popups.values())
        self.assertEqual(len(popups), 1)
        self.assertEqual(popups[0].a, "Friend")
        self.assertEqual(popups[0].b, "Test Dungeon (Test route)")
        self.assertIsNone(next(iter(self.g.PullwiseDB.routes.keys()), None))
        self.g.StaticPopupDialogs.PULLWISE_ROUTE_RECEIVED.OnAccept()
        self.assertEqual(self.g.PullwiseDB.routes[9999].route.total, 460)

    def test_ignores_routes_from_outside_the_group_and_from_myself(self):
        _, sender_g, sender_ns = start()
        sender_ns.ImportText(encode(SAMPLE))
        sender_ns.ShareShown()
        sender_g.FAKE.runTimers()
        sent = list(sender_g.FAKE.sent.values())
        self.deliver("Stranger-Realm", sent)
        self.deliver("Me", sent)
        self.assertEqual(len(list(self.fake.popups.values())), 0)

    def test_doesnt_ask_about_a_route_already_saved(self):
        text = encode(SAMPLE)
        self.ns.ImportText(text)
        _, sender_g, sender_ns = start()
        sender_ns.ImportText(text)
        sender_ns.ShareShown()
        sender_g.FAKE.runTimers()
        self.deliver("Friend", list(sender_g.FAKE.sent.values()))
        self.assertEqual(len(list(self.fake.popups.values())), 0)

    def test_routes_survive_a_reload_and_step_and_remove(self):
        self.ns.ImportText(encode(SAMPLE))
        self.ns.ImportText(encode(dict(SAMPLE, dungeon=5000, title="Other")))
        saved = self.lua.eval(
            "function(t) local function s(v) if type(v)=='table' then local o={} for k,x in pairs(v) do "
            "o[#o+1]='['..(type(k)=='string' and string.format('%q',k) or k)..']='..s(x) end "
            "return '{'..table.concat(o,',')..'}' elseif type(v)=='string' then return string.format('%q',v) "
            "else return tostring(v) end end return s(t) end"
        )(self.g.PullwiseDB)
        lua2, g2, ns2 = start(saved)
        g2.SlashCmdList.PULLWISE("")
        window = g2.PullwiseRouteFrame
        self.assertEqual(window.title.text, "Dungeon 5000: Other")  # last shown
        self.assertTrue(window.prev.shown)
        ns2.StepShown(1)
        self.assertEqual(window.title.text, "Test Dungeon: Test route")
        ns2.RemoveShown()
        self.assertEqual(window.title.text, "Dungeon 5000: Other")
        ns2.RemoveShown()
        self.assertIn("No routes yet", window.summary.text)

    def test_key_start_mentions_a_saved_route_and_turns_logging_on(self):
        self.ns.ImportText(encode(SAMPLE))
        self.fake.activeMap = 9999
        self.fake.fire("CHALLENGE_MODE_START")
        printed = "\n".join(self.fake.printed.values())
        self.assertIn("Your route for this key is ready", printed)
        self.assertTrue(self.fake.logging)
        self.slash("")
        self.assertEqual(self.frame("PullwiseRouteFrame").title.text, "Test Dungeon: Test route")

    def test_help(self):
        self.slash("help")
        self.assertIn("/pullwise import", "\n".join(self.fake.printed.values()))


if __name__ == "__main__":
    unittest.main()
