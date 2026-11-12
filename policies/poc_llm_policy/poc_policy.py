#!/usr/bin/env python3
"""Proof-of-concept LLM policy image: one Season 2 play seat, end to end.

What this does, in order:

1. Connects to the game server's ``/player`` endpoint as a play seat.
2. Pumps a 0xA2 StatusAck, which is also this PoC's request for the seat's
   0xB0 PlayContext (control_context + play_context).
3. Summarizes the match in a few lines of text and asks a model for a lobby
   chat line and an opening ladder call.
4. Sends the chat line as 0xA3 and waits for its own 0xB2 broadcast echo.
5. Uploads every ``.wasm`` in the baked-in playbook as 0xA0, waiting for
   ``module_accepted`` and then ``module_ready`` for each.
6. Sends the opening call as 0xA1 canonical ladder JSON, waits for
   ``call_accepted``.
7. Waits, asks the model a second time with an updated summary, and sends a
   mid-match re-call as a second 0xA1 with a higher proposal id.

Everything it puts on the wire is built from the byte layouts in
``src/shell/types.nim`` / ``src/shell/packets.nim`` and the canonical JSON
grammar in ``src/shell/canonical.nim`` -- see :mod:`wire`. Nothing links
against the engine.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import time

from websockets.sync.client import connect
from websockets.exceptions import WebSocketException

import brain
import wire

# ── The playbook contract, transcribed from the reference manifests ───────
# tests/fixtures/shell/manifest_edge_ride.golden.json
# tests/fixtures/shell/manifest_pact.golden.json
#
# A real policy would read these off the module it built. The PoC hardcodes
# them so the model's output can be repaired locally before it ever costs a
# round trip; the server's validator remains the oracle either way.
PLAY_SPECS = {
    "edge_ride": {
        "class": "controller",
        "params": {
            "margin": {"kind": "int", "min": 40, "max": 600},
            "enterLead": {"kind": "int", "min": 0, "max": 600},
            "coverBias": {"kind": "float", "min": 0.0, "max": 1.0},
        },
    },
    "pact": {
        "class": "overlay",
        "params": {
            "partners": {"kind": "seat_set", "min_items": 1, "max_items": 8},
            "protect": {"kind": "bool"},
            "onBetrayal": {"kind": "enum", "of": ["disengage", "returnFire"]},
        },
    },
}

ENTRY_ID_CHARS = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

MAX_SEAT = 31


def log(message: str) -> None:
    print(f"[poc] {message}", flush=True)


# ── Turning a model reply into bytes the validator will accept ────────────


def _clamp_number(value, spec):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = max(spec["min"], min(spec["max"], value))
    # An "integer: true" manifest param is rejected unless the JSON value is
    # itself an integer, so the canonical encoding must not carry a ".0".
    return int(round(value)) if spec["kind"] == "int" else float(value)


def _clean_partners(value):
    if not isinstance(value, list):
        return None
    seats = []
    for item in value:
        if isinstance(item, int) and not isinstance(item, bool):
            item = f"seat:{item}"
        if not isinstance(item, str):
            continue
        # `duo:<team>` is legal in the protocol but needs a configured duo on
        # the server; the PoC only ever emits the always-valid seat form.
        if item.startswith("duo:"):
            continue
        if not item.startswith("seat:"):
            continue
        digits = item[len("seat:"):]
        if not digits.isdigit() or int(digits) > MAX_SEAT:
            continue
        seats.append(f"seat:{int(digits)}")
    # A "set" param must be sorted and unique by its CANONICAL encoding, so
    # sort the encoded strings, not the raw values ("seat:10" < "seat:2").
    seats = sorted(set(seats), key=wire.canonical_json)
    if not seats:
        return None
    return seats[:8]


def _clean_params(play: str, params) -> dict:
    if not isinstance(params, dict):
        return {}
    specs = PLAY_SPECS[play]["params"]
    cleaned = {}
    for key, value in params.items():
        spec = specs.get(key)
        if spec is None:
            continue  # unknown params are rejected by name; drop them here
        if spec["kind"] in ("int", "float"):
            number = _clamp_number(value, spec)
            if number is not None:
                cleaned[key] = number
        elif spec["kind"] == "bool":
            if isinstance(value, bool):
                cleaned[key] = value
        elif spec["kind"] == "enum":
            if value in spec["of"]:
                cleaned[key] = value
        elif spec["kind"] == "seat_set":
            partners = _clean_partners(value)
            if partners is not None:
                cleaned[key] = partners
    if play == "pact" and "partners" not in cleaned:
        return {}  # partners is required; an unusable pact entry is dropped
    return cleaned


def _clean_entry_id(raw, play: str, index: int, seen: set) -> str:
    candidate = raw if isinstance(raw, str) else ""
    candidate = "".join(c for c in candidate if c in ENTRY_ID_CHARS)[:32]
    if not candidate:
        candidate = f"{play}_{index}"
    while candidate in seen:
        candidate = f"{candidate}x"
    seen.add(candidate)
    return candidate


def build_call(decision: dict) -> tuple[bytes, list]:
    """Repair a model reply into a canonical ladder call.

    Returns the canonical bytes and the entry list that produced them. Unusable
    entries are dropped rather than sent; if nothing survives, a bare
    ``edge_ride`` controller stands in so the seat still declares something.
    """
    raw_entries = []
    call = decision.get("call")
    if isinstance(call, dict):
        candidate = call.get("entries") or call.get("plays")
        if isinstance(candidate, list):
            raw_entries = candidate

    entries = []
    seen_ids: set = set()
    overlays = 0
    for index, raw in enumerate(raw_entries):
        if not isinstance(raw, dict):
            continue
        play = raw.get("play")
        if play not in PLAY_SPECS:
            continue
        if PLAY_SPECS[play]["class"] == "overlay":
            if overlays >= wire.MAX_ACTIVE_OVERLAYS:
                continue
            overlays += 1
        params = _clean_params(play, raw.get("params"))
        if play == "pact" and not params:
            overlays -= 1
            continue
        entry = {
            "play": play,
            "entry_id": _clean_entry_id(raw.get("entry_id"), play, index,
                                        seen_ids),
        }
        if params:
            entry["params"] = params
        entries.append(entry)
        if len(entries) >= wire.MAX_LADDER_ENTRIES:
            break

    if not entries:
        log("model produced no usable entries; falling back to bare edge_ride")
        entries = [{"play": "edge_ride", "entry_id": "ride"}]

    payload = wire.canonical_json({"plays": entries}).encode("utf-8")
    if len(payload) > wire.MAX_CALL_BYTES:
        raise wire.WireError(f"call is {len(payload)} bytes; cap is "
                             f"{wire.MAX_CALL_BYTES}")
    return payload, entries


# ── The seat ──────────────────────────────────────────────────────────────


class PlaySeat:
    """One bound play-seat socket and the protocol bookkeeping around it."""

    def __init__(self, connection, slot: int) -> None:
        self.connection = connection
        self.slot = slot
        # uploadId and proposalId are per-seat monotonic floors: an id at or
        # below the last admitted one is a stale rejection (§4.3).
        self.next_upload_id = 1
        self.next_proposal_id = 1
        self.ack_mark = 0
        self.highest_ordinal = 0
        self.context = None
        self.control_context = None
        self.statuses: list[dict] = []
        self.chat: list[dict] = []
        self.last_view_tick = 0
        # Coworld Checkpoints (Metta spec 0157; PLAYER.md "Checkpoints").
        # Subclasses add their own fields via checkpoint_state() /
        # restore_checkpoint_state(); this base keeps the per-episode id
        # floors, without which a respawned process restarts its ids at 1
        # and has every upload/call refused as stale.
        self.restored_state: dict | None = None
        self.load_checkpoint_state()

    # ── seat state ────────────────────────────────────────────────────────

    def checkpoint_state(self) -> dict:
        return {"version": 1, "next_upload_id": self.next_upload_id,
                "next_proposal_id": self.next_proposal_id}

    def restore_checkpoint_state(self, state: dict) -> None:
        self.next_upload_id = max(self.next_upload_id, int(state.get("next_upload_id", 1)))
        self.next_proposal_id = max(self.next_proposal_id, int(state.get("next_proposal_id", 1)))

    def load_checkpoint_state(self) -> None:
        path = os.environ.get("COWORLD_PLAYER_STATE_IN", "")
        if not path or not os.path.isfile(path) or os.path.getsize(path) == 0:
            return
        with open(path, encoding="utf-8") as source:
            state = json.load(source)
        if state.get("version") != 1:
            log(f"seat state {path}: unknown version, starting fresh")
            return
        self.restore_checkpoint_state(state)
        self.restored_state = state
        log(f"seat state restored from {path}: {json.dumps(state, sort_keys=True)[:200]}")

    def save_checkpoint_state(self, tick: int | None) -> None:
        path = os.environ.get("COWORLD_PLAYER_STATE_OUT", "")
        if not path:
            return
        temporary = f"{path}.tmp"
        with open(temporary, "w", encoding="utf-8") as sink:
            json.dump({**self.checkpoint_state(), "tick": tick}, sink)
        os.replace(temporary, path)

    def _on_text(self, message: str) -> None:
        """TEXT frames carry only the checkpoint handshake; save, then ack."""
        try:
            prompt = json.loads(message)
        except ValueError:
            return
        if not isinstance(prompt, dict) or prompt.get("type") != "checkpoint":
            return
        tick = prompt.get("tick")
        self.save_checkpoint_state(tick)
        self.connection.send(json.dumps({"type": "checkpoint_ack", "tick": tick}))
        log(f"checkpoint tick={tick}: state saved, acknowledged")

    def send(self, payload: bytes) -> None:
        self.connection.send(payload)

    def pump(self) -> None:
        """Acknowledge the highest status ordinal actually received.

        The StatusAck mark is a nondecreasing high-water acknowledgement of
        consumed statuses. The production server refuses a mark beyond what it
        has delivered (``status_ack_out_of_range``), so acking ordinals we have
        not seen — the old "tick pump" trick that worked against the PoC glue
        server — is a protocol violation, and an unacked backlog is simply
        redelivered. Ack exactly what we have consumed, only when it advances.
        """
        if self.highest_ordinal > self.ack_mark:
            self.ack_mark = self.highest_ordinal
            self.send(wire.encode_status_ack(self.ack_mark))

    def drain(self, seconds: float) -> None:
        """Read for `seconds`, filing every shell packet the server sends."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            try:
                message = self.connection.recv(timeout=remaining)
            except TimeoutError:
                return
            if isinstance(message, str):
                # The checkpoint handshake (TEXT frames); the legacy Sprite
                # stream's text also lands here and is ignored.
                self._on_text(message)
                continue
            packet = wire.decode_server_packet(message)
            if packet is None:
                continue
            self._file(packet)

    def _file(self, packet: dict) -> None:
        kind = packet["kind"]
        if kind == "play_context":
            self.control_context = json.loads(packet["control"])
            self.context = json.loads(packet["context"])
            log(f"0xB0 play_context: {packet['context']}")
        elif kind == "play_view":
            self.last_view_tick = packet["tick"]
            control = json.loads(packet["control"])
            for status in control.get("statuses", []):
                self.statuses.append(status)
                try:
                    ordinal = int(status.get("ordinal", "0"))
                except ValueError:
                    ordinal = 0
                self.highest_ordinal = max(self.highest_ordinal, ordinal)
                log(f"0xB1 status: {json.dumps(status, sort_keys=True)}")
        elif kind == "lobby_chat":
            self.chat.append(packet)
            log(f"0xB2 chat: seat={packet['seat']} ordinal={packet['ordinal']} "
                f"text={packet['text']!r}")

    def await_status(self, predicate, seconds: float = 15.0):
        """Pump and read until a status entry matches, or time out."""
        deadline = time.monotonic() + seconds
        seen = 0
        while time.monotonic() < deadline:
            for status in self.statuses[seen:]:
                if predicate(status):
                    return status
            seen = len(self.statuses)
            self.pump()
            self.drain(0.4)
        return None

    def await_chat(self, text: str, seconds: float = 15.0):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            for message in self.chat:
                if message["seat"] == self.slot and message["text"] == text:
                    return message
            self.pump()
            self.drain(0.4)
        return None

    def upload(self, name: str, blob: bytes) -> bool:
        upload_id = self.next_upload_id
        self.next_upload_id += 1
        log(f"0xA0 upload {name}: upload_id={upload_id} bytes={len(blob)}")
        self.send(wire.encode_module_upload(upload_id, blob))
        accepted = self.await_status(
            lambda s: s.get("upload_id") == str(upload_id)
            and s.get("kind") in ("module_accepted", "module_rejected"))
        if accepted is None:
            log(f"upload {name}: no admission status before timeout")
            return False
        if accepted["kind"] == "module_rejected":
            log(f"upload {name} REJECTED: {accepted.get('reason')}")
            return False
        ready = self.await_status(
            lambda s: s.get("upload_id") == str(upload_id)
            and s.get("kind") in ("module_ready", "module_rejected"))
        if ready is None or ready["kind"] != "module_ready":
            log(f"upload {name}: no module_ready "
                f"({ready.get('reason') if ready else 'timeout'})")
            return False
        log(f"upload {name} READY: name={ready['name']} sha256={ready['sha256']}")
        return True

    def call(self, payload: bytes, label: str):
        proposal_id = self.next_proposal_id
        self.next_proposal_id += 1
        log(f"0xA1 {label}: proposal_id={proposal_id} bytes={len(payload)} "
            f"call={payload.decode('utf-8')}")
        self.send(wire.encode_play_call(proposal_id, payload))
        outcome = self.await_status(
            lambda s: s.get("proposal_id") == str(proposal_id)
            and s.get("kind") in ("call_accepted", "call_rejected"))
        if outcome is None:
            log(f"{label}: no call status before timeout")
            return None
        if outcome["kind"] == "call_rejected":
            # The refusal names the offending path; that is the signal a real
            # policy author fixes its bytes from.
            log(f"{label} REJECTED: {outcome.get('reason')}")
            return outcome
        log(f"{label} ACCEPTED: epoch={outcome['epoch']} "
            f"proposal_id={outcome['proposal_id']} tick={outcome['tick']}")
        return outcome


HUDDLE_LINES = 12
"""How many heard huddle lines the summary quotes (most recent last)."""


def seat_name(context: dict | None, seat_index) -> str | None:
    """The display name the PlayContext roster carries for a seat, if any.

    The engine fills ``roster[].name`` from the closed roster (James's ruling
    2026-09-02: huddle partners are addressed by name); an older engine or an
    unnamed seat simply has no ``name`` key.
    """
    for row in (context or {}).get("roster", []):
        if isinstance(row, dict) and row.get("seat") == seat_index:
            name = row.get("name")
            return name if isinstance(name, str) and name else None
    return None


def seat_label(context: dict | None, seat_index) -> str:
    """``"<name> (seat N)"`` when the roster names the seat, else ``"seat N"``."""
    name = seat_name(context, seat_index)
    return f"{name} (seat {seat_index})" if name else f"seat {seat_index}"


def roster_lines(context: dict | None) -> list[str]:
    """One line per roster seat: who they are and which team they are on."""
    rows = [row for row in (context or {}).get("roster", [])
            if isinstance(row, dict)]
    if not rows:
        return []
    lines = ["Roster (name, seat, team):"]
    for row in rows:
        lines.append(f"  {seat_label(context, row.get('seat'))} -- "
                     f"team {row.get('team', '?')}")
    return lines


def huddle_lines(seat: "PlaySeat", limit: int = HUDDLE_LINES) -> list[str]:
    """The lobby chat heard so far, most recent last, attributed by name.

    The 0xB2 packet carries only the sender's seat index; the name comes from
    the context roster, so the model can answer people rather than numbers.
    """
    if not seat.chat:
        return []
    lines = ["Huddle so far (most recent last):"]
    for packet in seat.chat[-limit:]:
        lines.append(f"  {seat_label(seat.context, packet.get('seat'))}: "
                     f"{packet.get('text', '')}")
    return lines


def summarize(seat: PlaySeat, phase: str, standing: bytes | None = None) -> str:
    """The tiny text summary the model reasons over.

    `standing` is the ladder currently in force. Without it the second turn is
    a fresh decision rather than a revision, and a model handed the same map
    facts twice will simply repeat itself -- which is exactly what the first
    live run did.
    """
    context = seat.context or {}
    game_map = context.get("map", {})
    roster = context.get("roster", [])
    my_seat = context.get("self", {}).get("seat", seat.slot)
    lines = [
        f"Phase: {phase}.",
        f"Mode: {context.get('mode', 'unknown')}.",
        f"Map: {game_map.get('name', '?')}, "
        f"{game_map.get('width', '?')}x{game_map.get('height', '?')} px.",
        f"Seats in the roster: {len(roster)}.",
        f"You are {seat_label(context, my_seat)} "
        f"on team {context.get('self', {}).get('team', '?')}.",
        f"Gun range: {context.get('gun_range', '?')} px.",
        f"Server tick: {seat.last_view_tick}.",
    ]
    partner = context.get("self", {}).get("duo_partner")
    if partner is not None:
        lines.append(f"Your duo partner is {seat_label(context, partner)}.")
    roster_block = roster_lines(context)
    if roster_block:
        lines.append("")
        lines.extend(roster_block)
    heard = huddle_lines(seat)
    if heard:
        lines.append("")
        lines.extend(heard)
    lines.append("")
    lines.append("In chat, address other players by name; they see yours. "
                 "In the call, seats are always written seat:<N>.")
    if standing is not None:
        lines.append("")
        lines.append("The ladder you already have in force is:")
        lines.append(standing.decode("utf-8"))
        lines.append("Re-call only what you would actually change, and say in "
                     "one line what changed and why.")
    return "\n".join(lines)


def load_playbook(directory: pathlib.Path) -> list[tuple[str, bytes]]:
    """Read the wasm blobs baked into the image, controllers first.

    Order matters on the wire only in that uploads are one per seat per tick;
    the controller goes first so a truncated run still has a usable ladder.
    """
    if not directory.is_dir():
        raise SystemExit(f"playbook directory not found: {directory}")
    modules = []
    for path in sorted(directory.glob("*.wasm")):
        modules.append((path.stem, path.read_bytes()))
    if not modules:
        raise SystemExit(f"no .wasm modules in {directory}")
    modules.sort(key=lambda item: 0 if item[0] == "edge_ride" else 1)
    return modules


def run(args) -> int:
    playbook = load_playbook(pathlib.Path(args.playbook))
    log("playbook: " + ", ".join(f"{n} ({len(b)}B)" for n, b in playbook))

    engine, why = brain.build_brain(args.canned, args.model)
    log(f"model backend: {engine.name} ({why})")

    url = (f"ws://{args.host}:{args.port}/player"
           f"?slot={args.slot}&token={args.token}")
    log(f"connecting to {url}")

    failures = []
    with connect(url, max_size=None, open_timeout=args.connect_timeout) as ws:
        seat = PlaySeat(ws, args.slot)

        # (1) Say hello and collect the seat's context.
        for _ in range(40):
            seat.pump()
            seat.drain(0.5)
            if seat.context is not None:
                break
        if seat.context is None:
            log("FAILED: no 0xB0 PlayContext from the server")
            return 1

        # (2) First model call: lobby line plus the opening ladder.
        summary = summarize(seat, "lobby, before the drop")
        log("model input:\n" + summary)
        decision = engine.decide(summary)
        log(f"model output: {json.dumps(decision, sort_keys=True)}")

        # (3) Lobby chat, and wait for our own broadcast back.
        chat_text = str(decision.get("chat", "")).strip() or "gl hf"
        log(f"0xA3 chat: {chat_text!r}")
        seat.send(wire.encode_lobby_chat(chat_text))
        echo = seat.await_chat(chat_text)
        if echo is None:
            failures.append("no 0xB2 broadcast echo for our chat line")
        else:
            log(f"chat echoed at ordinal {echo['ordinal']}")

        # (4) Upload the whole playbook. One upload per seat per tick, so pump
        #     between modules.
        for name, blob in playbook:
            if not seat.upload(name, blob):
                failures.append(f"module {name} never reached module_ready")
            seat.pump()
            seat.drain(0.3)

        # (5) The opening call.
        payload, _ = build_call(decision)
        opening = seat.call(payload, "opening call")
        if opening is None or opening["kind"] != "call_accepted":
            failures.append("opening call was not accepted")

        # (6) Let the match run, then re-call off a second model decision.
        log(f"holding for {args.recall_seconds:.0f}s before the mid-match re-call")
        held = time.monotonic() + args.recall_seconds
        while time.monotonic() < held:
            seat.pump()
            seat.drain(0.5)

        summary = summarize(seat, "mid-match, the zone is closing",
                            standing=payload)
        log("model input:\n" + summary)
        decision = engine.decide(summary)
        log(f"model output: {json.dumps(decision, sort_keys=True)}")

        recall_text = str(decision.get("chat", "")).strip()
        if recall_text:
            seat.send(wire.encode_lobby_chat(recall_text))
        payload, _ = build_call(decision)
        recall = seat.call(payload, "mid-match re-call")
        if recall is None or recall["kind"] != "call_accepted":
            failures.append("mid-match re-call was not accepted")

        seat.drain(1.0)

    log("---- PoC summary ----")
    log(f"model backend: {engine.name}")
    log(f"real model calls: {getattr(engine, 'calls', 0)}")
    log(f"statuses received: {len(seat.statuses)}")
    log(f"chat broadcasts received: {len(seat.chat)}")
    if failures:
        for failure in failures:
            log(f"FAILURE: {failure}")
        return 1
    log("all PoC steps passed")
    return 0


def _hosted_ws_defaults() -> dict:
    """The platform's connection contract: `coworld run-episode`/`play` (and
    the hosted Kubernetes runner) start every player pod with
    COWORLD_PLAYER_WS_URL (ws://host:port/player?slot=N&token=T) instead of
    the POC_* localhost vars this PoC originally only understood. Parse it
    when present so the PoC connects under the CLI the same way the
    `policies/starters/` harness already does (see
    `policies/starters/common/starter_harness.py:_hosted_ws_defaults`) --
    the exact miss that made this image fail with "connection refused" under
    `coworld run-episode` (POC_HOST/PORT/SLOT/TOKEN were never set, so it fell
    back to its own 127.0.0.1:21815 defaults instead of the CLI's real URL).
    """
    url = os.environ.get("COWORLD_PLAYER_WS_URL", "")
    if not url:
        return {}
    from urllib.parse import urlsplit, parse_qs
    parts = urlsplit(url)
    query = parse_qs(parts.query)
    out = {}
    if parts.hostname:
        out["host"] = parts.hostname
    if parts.port:
        out["port"] = parts.port
    if query.get("slot"):
        out["slot"] = int(query["slot"][0])
    if query.get("token"):
        out["token"] = query["token"][0]
    return out


def main(argv=None) -> int:
    hosted = _hosted_ws_defaults()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host",
                        default=hosted.get("host",
                                           os.environ.get("POC_HOST",
                                                          "127.0.0.1")))
    parser.add_argument("--port", type=int,
                        default=hosted.get("port",
                                           int(os.environ.get("POC_PORT",
                                                              "21815"))))
    parser.add_argument("--slot", type=int,
                        default=hosted.get("slot",
                                           int(os.environ.get("POC_SLOT",
                                                              "0"))))
    parser.add_argument("--token",
                        default=hosted.get("token",
                                           os.environ.get("POC_TOKEN", "")))
    parser.add_argument("--playbook",
                        default=os.environ.get("POC_PLAYBOOK", "playbook"))
    parser.add_argument("--model",
                        default=os.environ.get("POC_MODEL", brain.DEFAULT_MODEL))
    parser.add_argument("--canned", action="store_true",
                        default=os.environ.get("POC_CANNED", "") == "1",
                        help="substitute a fixed model response (offline/CI)")
    parser.add_argument("--recall-seconds", type=float,
                        default=float(os.environ.get("POC_RECALL_SECONDS", "6")))
    parser.add_argument("--connect-timeout", type=float, default=30.0)
    args = parser.parse_args(argv)

    try:
        return run(args)
    except (WebSocketException, OSError) as error:
        log(f"FAILED: transport error: {error}")
        return 1
    except (wire.WireError, brain.BrainError) as error:
        log(f"FAILED: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
