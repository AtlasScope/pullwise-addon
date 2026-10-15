# Pullwise

A free World of Warcraft add-on that goes with [pullwise.gg](https://pullwise.gg).

- **Combat logging for keys.** Turns combat logging on when you enter a Mythic or Mythic+
  dungeon, so the key's start is in the log, and off when the key ends or you leave (only if it
  was the one that turned it on). The first time, it also turns on the game's Advanced Combat
  Logging setting, which the review needs for health and positions. Tools outside the game, such
  as the Pullwise Helper, read the log file afterwards.
- **Routes.** Copy a route on pullwise.gg, type `/pullwise import` and paste it. `/pullwise` opens
  it as a pull list: each pull's enemy forces, the running total, your notes and where the bosses
  fall. **Share with group** sends it to party members who have Pullwise; they're asked before it's
  saved. The game blocks add-on messages inside dungeons, so share before you go in.

Nothing is sent anywhere except a route you choose to share with your own group.

## Commands

| Command | Does |
| --- | --- |
| `/pullwise` | Opens or closes your route (the current key's dungeon if you have one saved) |
| `/pullwise import` | Paste a route from pullwise.gg |
| `/pullwise share` | Sends the open route to your group |

## Route strings

`!PW1!` followed by standard base64 of raw-DEFLATE-compressed JSON, read with the game's own
`C_EncodingUtil`, so nothing extra is bundled. `tests/route_string.py` builds one from a JSON file,
and `tests/sample-route.json` is a test route.

## Installing

From CurseForge, Wago or WoWInterface once listed, or download `Pullwise.zip` from the latest release and unzip it
into `World of Warcraft/_retail_/Interface/AddOns/`.

## Tests

The route reader and sharing run in Lua 5.1 against a stand-in for the game:

```sh
python3 -m pip install lupa
python3 -m unittest discover -s tests
```

Free, with its code public, under the MIT licence.
