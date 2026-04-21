"""Scout: thinking vs token boundary.

Captures the ordered stream of `thinking_delta`, `thinking`, `token`
envelopes so we can tell whether the daemon mis-labels the transition
between reasoning and response.
"""
import sys
import time
import uuid

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402
from digitorn.testing.models import SessionHandle  # noqa: E402


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    # Pick an app that exposes thinking on the default model. chat +
    # builder are both good candidates. Override with CLI arg.
    app_id = sys.argv[1] if len(sys.argv) > 1 else "digitorn-builder"
    prompt = sys.argv[2] if len(sys.argv) > 2 else "Bonjour"
    sid = f"scout-th-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace="",
    )
    print(f"\n=== thinking scout app={app_id} prompt={prompt!r} ===\n")

    stream = client.send_live(session, prompt, total_timeout=60)
    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            if any(e.get("type") == "message_done"
                   for e in stream.events()):
                break
            time.sleep(0.2)
        envs = stream.events()

        # Reconstruct the boundary.
        thinking_buf = []
        token_buf = []
        state = "idle"  # idle → thinking → token
        transitions: list[str] = []
        for env in envs:
            t = env.get("type", "?")
            pl = env.get("payload") or env.get("data") or {}
            if t == "thinking_delta":
                delta = pl.get("delta", "")
                if state != "thinking":
                    transitions.append(f"[seq={env.get('seq')}] {state}→thinking")
                    state = "thinking"
                thinking_buf.append(delta)
            elif t == "thinking":
                text = pl.get("text", "")
                if text:
                    transitions.append(
                        f"[seq={env.get('seq')}] thinking (snapshot "
                        f"len={len(text)})")
            elif t == "token":
                delta = pl.get("delta", "")
                if state != "token":
                    transitions.append(f"[seq={env.get('seq')}] {state}→token")
                    state = "token"
                token_buf.append(delta)
            elif t == "stream_done":
                transitions.append(f"[seq={env.get('seq')}] stream_done")
            elif t == "result":
                # Compare what the daemon "officially" says.
                official = pl.get("content", "")
                transitions.append(
                    f"[seq={env.get('seq')}] result (content len={len(official)})")

        print("--- state transitions ---")
        for t in transitions:
            print(f"  {t}")

        print("\n--- accumulated thinking (from thinking_delta) ---")
        full_think = "".join(thinking_buf)
        print(repr(full_think[-300:]) if len(full_think) > 300 else repr(full_think))

        print("\n--- accumulated tokens ---")
        full_tok = "".join(token_buf)
        print(repr(full_tok[:300]))

        # Overlap check — does the tail of thinking equal the head of tokens?
        if full_think and full_tok:
            for k in (80, 40, 20, 10, 5):
                if len(full_think) >= k and full_think[-k:] in full_tok[: 2 * k + k]:
                    print(f"\n⚠️  OVERLAP: last {k} chars of thinking appear in tokens head")
                    break
            else:
                print("\n✓ no raw overlap between thinking tail and token head")

        # If a `thinking` snapshot is sent, does it match the accumulated deltas?
        for env in envs:
            if env.get("type") == "thinking":
                pl = env.get("payload") or env.get("data") or {}
                text = pl.get("text", "")
                if text and text != full_think:
                    print(
                        f"\n⚠️  DRIFT: thinking snapshot len={len(text)} "
                        f"but accumulated deltas len={len(full_think)}"
                    )
                    # Print the diff point.
                    for i, (a, b) in enumerate(zip(text, full_think)):
                        if a != b:
                            lo = max(0, i - 20)
                            hi = min(len(text), i + 20)
                            print(f"    first divergence at {i}:")
                            print(f"    snapshot: ...{text[lo:hi]}...")
                            print(f"    deltas:   ...{full_think[lo:hi]}...")
                            break

        # Deep dump of snapshots + result for manual inspection.
        for env in envs:
            t = env.get("type", "?")
            if t not in ("thinking", "assistant_stream_snapshot", "result"):
                continue
            pl = env.get("payload") or env.get("data") or {}
            print(f"\n=== RAW [seq={env.get('seq')}] {t} ===")
            if t == "thinking":
                print(pl.get("text", "")[:2000])
            elif t == "assistant_stream_snapshot":
                print(f"chars={pl.get('chars')}")
                print(pl.get("content", "")[:2000])
            elif t == "result":
                print(pl.get("content", "")[:2000])
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
