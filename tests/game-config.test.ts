import { expect, test } from "bun:test";
import { configureLocalGame } from "../scripts/game-config";
import { readSettings } from "../config/settings";

const settings = readSettings({ FACTORIO_RCON_PASSWORD: "test_$&" });
const paths = { readData: "C:\\Steam\\Factorio\\data", writeData: "C:\\Users\\Player\\Factorio" };

test("local launch profile replaces disabled and duplicate RCON settings in the correct section", () => {
  const source = [
    "; version=13",
    "[other]",
    "; local-rcon-socket=0.0.0.0:0",
    "local-rcon-socket=localhost:9",
    " ; local-rcon-password=",
    "volume=0.7",
    "[unrelated]",
    "local-rcon-socket=keep",
    "[path]",
    "write-data=old",
    "",
  ].join("\r\n");
  const profile = configureLocalGame(source, settings, paths);
  expect(profile).toContain("local-rcon-socket=127.0.0.1:34198\r\n");
  expect(profile).toContain("local-rcon-password=test_$&\r\n");
  expect(profile).not.toContain("localhost:9");
  expect(profile).toContain("[unrelated]\r\nlocal-rcon-socket=keep");
  expect(profile).toContain("volume=0.7");
  expect(profile).toContain("write-data=C:/Users/Player/Factorio");
  expect(configureLocalGame(profile, settings, paths)).toBe(profile);
});

test("local launch profile creates missing sections and rejects multiline values", () => {
  const profile = configureLocalGame("; version=13\n[general]\nlocale=auto\n", settings, paths);
  expect(profile).toContain("[other]\nlocal-rcon-password=test_$&\n");
  expect(profile).toContain("[path]\nwrite-data=C:/Users/Player/Factorio\n");
  expect(() =>
    configureLocalGame("", { ...settings, FACTORIO_RCON_PASSWORD: "bad\nvalue" }, paths),
  ).toThrow();
});
