#!/usr/bin/env python3
"""Write a local-only Paintbot manifest for the Coworld Checkpoints Docker E2E.

Takes coworld_manifest_paintbot.json, substitutes locally built images, and
adds one small variant, `checkpoint-e2e`: the battle-royale-s2 rules with
SEATS play seats (baseline players), a short lobby chat and a short clock,
so a save -> kill -> restore -> branch round trip fits in a few minutes on a
laptop. Never published.

  tools/checkpoints/make_e2e_manifest.py OUT.json \
      --game-image coworld-ctf-game:ckpt --player-image coworld-ctf-baseline:ckpt
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil

REPO = pathlib.Path(__file__).resolve().parents[2]
COLORS = ["red", "blue", "green", "yellow", "black", "silver", "ivory", "pink"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--game-image", required=True)
    parser.add_argument("--player-image", required=True)
    parser.add_argument("--seats", type=int, default=4)
    parser.add_argument("--max-ticks", type=int, default=1500)
    parser.add_argument("--keyframe-ticks", type=int, default=0,
                        help="Set CTF_REPLAY_KEYFRAME_TICKS on the game (embedded replay keyframes).")
    args = parser.parse_args()
    text = (REPO / "coworld_manifest_paintbot.json").read_text()
    text = text.replace("{{GAME_IMAGE}}", args.game_image).replace("{{PLAYER_IMAGE}}", args.player_image)
    manifest = json.loads(text)
    manifest["game"]["version"] = "0.0.1"
    if args.keyframe_ticks > 0:
        manifest["game"]["runnable"]["env"]["CTF_REPLAY_KEYFRAME_TICKS"] = str(args.keyframe_ticks)
    # replay_viewer.bundle stays package-relative: copy static-replay-viewer/
    # next to OUT.json.
    viewer = args.out.parent / "static-replay-viewer"
    if not viewer.exists():
        shutil.copytree(REPO / "static-replay-viewer", viewer)
    base = next(v for v in manifest["variants"] if v["id"] == "battle-royale-s2")
    config = json.loads(json.dumps(base["game_config"]))
    config["players"] = [{"name": f"Player{i + 1}"} for i in range(args.seats)]
    config["slots"] = [{"team": COLORS[i], "control": "play"} for i in range(args.seats)]
    config["num_agents"] = args.seats
    config["minPlayers"] = args.seats
    config["maxTicks"] = args.max_ticks
    config["lobbyChatTicks"] = 48
    config["seed"] = 4242
    config["variantId"] = "checkpoint-e2e"
    variant = {
        "id": "checkpoint-e2e",
        "name": "Checkpoint E2E (local only)",
        "description": "battle-royale-s2 rules on a small roster with a short clock, for checkpoint tests.",
        "game_config": config,
    }
    manifest["variants"] = [variant] + [v for v in manifest["variants"] if v["id"] == "battle-royale-s2"]
    manifest["certification"]["players"] = [{"player_id": "baseline"} for _ in range(args.seats)]
    manifest["certification"]["game_config"] = json.loads(json.dumps(config))
    args.out.write_text(json.dumps(manifest, indent=2))
    print(args.out)


if __name__ == "__main__":
    main()
