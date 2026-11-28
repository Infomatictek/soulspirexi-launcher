"""BattleLens display safety and opt-in contract tests."""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "channels" / "testing" / "payload" / "addons" / "vanacore" / "battlelens"


class BattleLensTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from lupa.luajit21 import LuaRuntime

        cls.rules = LuaRuntime().execute((NATIVE / "rules.lua").read_text(encoding="utf-8"))

    def test_vanacore_only_package(self):
        self.assertTrue((NATIVE / "rules.lua").is_file())
        self.assertFalse((ROOT / "addons" / "ashita4" / "battlelens").exists())

    def test_manual_load_only_and_disabled_default(self):
        config = self.rules.defaults()
        self.assertFalse(config["enabled"])
        self.assertIsNone(self.rules.apply(config, "Alice misses Goblin.", 9, False, False))
        for path in (NATIVE / "battlelens.lua",):
            self.assertIn("battlelens", path.read_text(encoding="utf-8"))

    def test_recognized_lines_condense_and_filter(self):
        config = self.rules.defaults()
        config["enabled"] = True
        cases = (
            ("Alice hits Goblin for 12 points of damage.", "Alice -> Goblin: 12", "melee"),
            ("Alice misses Goblin.", "Alice -> Goblin: miss", "miss"),
            ("Alice evades the attack.", "Alice: evade", "evade"),
        )
        for line, expected, category in cases:
            with self.subTest(category=category):
                result = self.rules.apply(config, line, 9, False, False)
                self.assertEqual(result["message"], expected)
                self.assertEqual(result["category"], category)
                config["show"][category] = False
                self.assertTrue(self.rules.apply(config, line, 9, False, False)["blocked"])
                config["show"][category] = True

    def test_unknown_and_important_messages_are_preserved(self):
        config = self.rules.defaults()
        config["enabled"] = True
        for line in (
            "Alice uses Soul Flare.", "Skillchain: Light.", "Magic Burst!",
            "Alice scores a critical hit!", "Alice recovers 40 HP.",
            "[OXTAL]|opaque", "[OXMOB]|opaque", "[Soulspire] Soul ready",
            "\x1e\x02Alice hits Goblin for 12 points of damage.",
            "Alice hits Goblin for 12 points of damage. Extra text",
        ):
            with self.subTest(line=line):
                self.assertIsNone(self.rules.apply(config, line, 9, False, False))
        self.assertIsNone(self.rules.apply(config, "Alice misses Goblin.", 121, False, False))
        self.assertIsNone(self.rules.apply(config, "Alice misses Goblin.", 9, True, False))
        self.assertIsNone(self.rules.apply(config, "Alice misses Goblin.", 9, False, True))

    def test_commands_toggle_and_validate_colors(self):
        config = self.rules.defaults()
        self.assertTrue(self.rules.command(config, "/battlelens on")[0])
        self.assertTrue(config["enabled"])
        self.assertTrue(self.rules.command(config, "/blens show miss off")[0])
        self.assertFalse(config["show"]["miss"])
        self.rules.command(config, "/battlelens color melee 104")
        self.assertEqual(self.rules.apply(config, "Alice hits Goblin for 12 points of damage.", 9, False, False)["mode"], 104)
        self.rules.command(config, "/battlelens color melee 999")
        self.assertEqual(config["color"]["melee"], 104)
        self.rules.command(config, "/battlelens off")
        self.assertFalse(config["enabled"])
        self.assertIsNone(self.rules.apply(config, "Alice hits Goblin for 12 points of damage.", 9, False, False))

    def test_vanacore_adapter_toggles_live_without_global_settings(self):
        from lupa.luajit21 import LuaRuntime

        lua = LuaRuntime()
        lua.globals().addon = lua.table_from({"path": str(NATIVE)})
        lua.execute("""
            callbacks = {}
            saved = 0
            output = {}
            print = function(line) output[#output + 1] = line end
            vana = {
                settings = { register = function(options)
                    assert(options.scope == 'character')
                    return { data = options.defaults, ready = true,
                        save = function(self) saved = saved + 1; return true end }
                end },
                events = { on = function(name, fn) callbacks[name] = fn end },
            }
        """)
        lua.execute((NATIVE / "battlelens.lua").read_text(encoding="utf-8"))
        event = lua.table_from({"message": "Alice misses Goblin.", "message_modified": "Alice misses Goblin.",
                                "mode": 9, "injected": False, "blocked": False})
        lua.globals().callbacks["text_in"](event)
        self.assertEqual(event["message_modified"], "Alice misses Goblin.")
        lua.globals().callbacks["command"](lua.table_from({"command": "/battlelens on"}))
        lua.globals().callbacks["text_in"](event)
        self.assertEqual(event["message_modified"], "Alice -> Goblin: miss")
        lua.globals().callbacks["command"](lua.table_from({"command": "/battlelens off"}))
        event["message_modified"] = event["message"]
        lua.globals().callbacks["text_in"](event)
        self.assertEqual(event["message_modified"], "Alice misses Goblin.")
        self.assertEqual(lua.globals().saved, 2)


if __name__ == "__main__":
    unittest.main()
