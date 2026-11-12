#!/usr/bin/env python3
"""Native (no Docker) check of Paintbot's Coworld Checkpoint path (spec 0157).

Mirrors what `coworld run-episode --checkpoint-ticks T` and
`--from-checkpoint DIR` do, with native binaries, so the game-side contract
can be iterated on without image rebuilds:

  phase A  one episode with COGAME_SNAPSHOT_DIR + COGAME_CHECKPOINT_TICKS=T +
           COGAME_CHECKPOINT_RESTART=1. When the game writes
           tick_T/manifest.json this harness copies each seat's state.bin
           into the checkpoint (seats/seat_N.snapshot), SIGKILLs every player
           process group and respawns it with COWORLD_PLAYER_STATE_IN (what
           runner/player_supervisor.sh does in a container).
  phase B  a fresh game process booted from tick_T/game.snapshot
           (COGAME_LOAD_SNAPSHOT_URI) and fresh players restored from the
           seat snapshots.

Both phases must end with results.json and a replay; the harness then runs
tools/expand_replay on each replay (hash parity over the WHOLE match,
including the resumed half).

Usage:
  tools/checkpoints/local_resume_check.py --server BIN --baseline BIN \
      --expand BIN [--seats 4] [--tick 600] [--out DIR] [--discard-state]
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
COLORS = ["red", "blue", "green", "yellow", "black", "silver", "ivory", "pink"]


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def episode_config(seats: int, max_ticks: int) -> dict:
    manifest = json.loads((REPO / "coworld_manifest_paintbot.json").read_text())
    variant = next(v for v in manifest["variants"] if v["id"] == "battle-royale-s2")
    config = json.loads(json.dumps(variant["game_config"]))
    config["players"] = [{"name": f"Player{i + 1}"} for i in range(seats)]
    config["slots"] = [{"team": COLORS[i], "control": "play"} for i in range(seats)]
    config["num_agents"] = seats
    config["minPlayers"] = seats
    config["maxTicks"] = max_ticks
    config["lobbyChatTicks"] = 48
    config["tokens"] = [f"tok-{i}" for i in range(seats)]
    return config


class Episode:
    def __init__(self, args, name: str, config: dict, game_env: dict, state_in: dict[int, pathlib.Path]):
        self.args = args
        self.dir = args.out / name
        self.dir.mkdir(parents=True, exist_ok=True)
        self.port = free_port()
        self.config = config
        (self.dir / "config.json").write_text(json.dumps(config))
        self.results = self.dir / "results.json"
        self.replay = self.dir / "replay.bitreplay"
        env = dict(os.environ)
        env.update({
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(self.port),
            "COGAME_CONFIG_URI": f"file://{self.dir / 'config.json'}",
            "COGAME_RESULTS_URI": f"file://{self.results}",
            "COGAME_SAVE_REPLAY_URI": f"file://{self.replay}",
        })
        env.update(game_env)
        self.game_log = open(self.dir / "game.log", "w")
        self.game = subprocess.Popen([str(args.server)], cwd=REPO, env=env,
                                     stdout=self.game_log, stderr=subprocess.STDOUT)
        self.players: dict[int, subprocess.Popen] = {}
        self.player_logs = {}
        self.state_dirs = {}
        for slot in range(len(config["slots"])):
            state_dir = self.dir / "state" / f"seat_{slot}"
            state_dir.mkdir(parents=True, exist_ok=True)
            self.state_dirs[slot] = state_dir
            if slot in state_in:
                shutil.copyfile(state_in[slot], state_dir / "state.bin")
            self.player_logs[slot] = open(self.dir / f"player_{slot}.log", "w")
        self.wait_for_port()
        for slot in self.state_dirs:
            self.spawn(slot, restore=(self.state_dirs[slot] / "state.bin").is_file())

    def wait_for_port(self) -> None:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if self.game.poll() is not None:
                raise SystemExit(f"game exited early; see {self.dir / 'game.log'}")
            with socket.socket() as sock:
                if sock.connect_ex(("127.0.0.1", self.port)) == 0:
                    return
            time.sleep(0.2)
        raise SystemExit("game never opened its port")

    def spawn(self, slot: int, restore: bool) -> None:
        env = dict(os.environ)
        env["COWORLD_PLAYER_WS_URL"] = (
            f"ws://127.0.0.1:{self.port}/player?slot={slot}&token={self.config['tokens'][slot]}")
        env["BASELINE_PLAYBOOK"] = str(self.args.playbook)
        env["COWORLD_PLAYER_STATE_OUT"] = str(self.state_dirs[slot] / "state.bin")
        if restore:
            env["COWORLD_PLAYER_STATE_IN"] = str(self.state_dirs[slot] / "state.bin")
        if self.args.discard_state:
            env["BASELINE_DISCARD_STATE"] = "1"
        log = self.player_logs[slot]
        log.write(f"=== spawn restore={restore} at {time.time():.3f}\n")
        log.flush()
        self.players[slot] = subprocess.Popen([str(self.args.baseline)], env=env, stdout=log,
                                              stderr=subprocess.STDOUT, start_new_session=True)

    def restart_all(self) -> None:
        for slot, process in self.players.items():
            with_suppress = process.poll() is None
            if with_suppress:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            self.spawn(slot, restore=(self.state_dirs[slot] / "state.bin").is_file())

    def run(self, checkpoint_dir: pathlib.Path | None, timeout: float) -> list[pathlib.Path]:
        assembled = []
        seen: set[str] = set()
        deadline = time.monotonic() + timeout
        while self.game.poll() is None and time.monotonic() < deadline:
            if checkpoint_dir is not None:
                for manifest in sorted(checkpoint_dir.glob("tick_*/manifest.json")):
                    if manifest.parent.name in seen:
                        continue
                    seen.add(manifest.parent.name)
                    seats = manifest.parent / "seats"
                    seats.mkdir(exist_ok=True)
                    for slot, state_dir in self.state_dirs.items():
                        if (state_dir / "state.bin").is_file():
                            shutil.copyfile(state_dir / "state.bin", seats / f"seat_{slot}.snapshot")
                    print(f"[{self.dir.name}] checkpoint {manifest.parent.name}: "
                          f"{json.loads(manifest.read_text())}; restarting players", flush=True)
                    self.restart_all()
                    assembled.append(manifest.parent)
            time.sleep(0.05)
        if self.game.poll() is None:
            self.game.kill()
            raise SystemExit(f"[{self.dir.name}] game did not finish in {timeout}s")
        for process in self.players.values():
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
        print(f"[{self.dir.name}] game exit {self.game.returncode}", flush=True)
        return assembled


def expand(args, replay: pathlib.Path) -> bool:
    result = subprocess.run([str(args.expand), str(replay)], capture_output=True, text=True, cwd=REPO)
    tail = (result.stdout + result.stderr).strip().splitlines()[-3:]
    print(f"expand_replay {replay}: exit {result.returncode}: {' | '.join(tail)}", flush=True)
    return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path, required=True)
    parser.add_argument("--expand", type=pathlib.Path, required=True)
    parser.add_argument("--playbook", type=pathlib.Path, required=True)
    parser.add_argument("--seats", type=int, default=4)
    parser.add_argument("--tick", type=int, default=600)
    parser.add_argument("--max-ticks", type=int, default=1500)
    parser.add_argument("--out", type=pathlib.Path)
    parser.add_argument("--discard-state", action="store_true")
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    args.out = args.out or pathlib.Path(tempfile.mkdtemp(prefix="coworld-ctf-qa-ckpt-"))
    print(f"output: {args.out}", flush=True)
    config = episode_config(args.seats, args.max_ticks)

    snapshots = args.out / "snapshots"
    snapshots.mkdir(parents=True, exist_ok=True)
    a = Episode(args, "a_checkpoint_restart", config, {
        "COGAME_SNAPSHOT_DIR": f"file://{snapshots}",
        "COGAME_CHECKPOINT_TICKS": str(args.tick),
        "COGAME_CHECKPOINT_RESTART": "1",
    }, {})
    checkpoints = a.run(snapshots, args.timeout)
    ok = a.results.is_file() and a.replay.is_file() and expand(args, a.replay)
    if not checkpoints:
        print("no checkpoint was written", flush=True)
        return 1
    checkpoint = checkpoints[0]
    seat_states = {slot: checkpoint / "seats" / f"seat_{slot}.snapshot" for slot in range(args.seats)
                   if (checkpoint / "seats" / f"seat_{slot}.snapshot").is_file()}
    b = Episode(args, "b_from_checkpoint", config, {
        "COGAME_LOAD_SNAPSHOT_URI": f"file://{checkpoint / 'game.snapshot'}",
    }, seat_states)
    b.run(None, args.timeout)
    ok = ok and b.results.is_file() and b.replay.is_file() and expand(args, b.replay)
    for episode in (a, b):
        if episode.results.is_file():
            results = json.loads(episode.results.read_text())
            print(f"[{episode.dir.name}] results: scores={results.get('scores')} "
                  f"finalTick={results.get('finalTick')} endRule={results.get('endRule')}", flush=True)
    print("OK" if ok else "FAILED", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
