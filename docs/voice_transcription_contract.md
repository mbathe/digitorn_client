# Voice transcription — daemon contract

The Flutter client can record audio on every platform (Android, iOS,
Web, Windows, macOS, Linux) and optionally ship that audio to the
daemon for transcription. Live on-device STT is preferred where
available (Android, iOS, Web, Windows) but the client falls back to
server transcription on:

1. Linux — no native STT stack.
2. Any platform when the user sets their voice preference to
   "always use the server" (e.g. for quality parity / privacy).
3. Any platform where the OS recogniser refuses (permission denial,
   kids-mode, enterprise policy, etc.).

The daemon exposes a **single optional endpoint**. A 404 is handled
gracefully by the client: the audio file is attached to the next
message as a fallback, so the feature keeps working even before the
daemon ships transcription.

## Endpoint

```
POST /api/transcribe
Content-Type: multipart/form-data
Authorization: Bearer <user token>
```

### Request fields

| Field      | Type      | Required | Notes |
|------------|-----------|----------|-------|
| `audio`    | file      | yes      | `.m4a` (AAC-LC) on mobile/desktop, `.webm` on web. ≤ 25 MB. |
| `language` | string    | no       | BCP-47 code (`fr`, `en-US`). If absent, daemon auto-detects. |
| `app_id`   | string    | no       | Active app id for context — daemon may use it to bias vocabulary (file names, tool names). |

### Response (200 OK)

```json
{
  "success": true,
  "data": {
    "text": "Create a function that reads the auth tokens",
    "language": "en",
    "duration_ms": 3200,
    "confidence": 0.96
  }
}
```

All fields inside `data` are optional except `text`. The client
ignores unknown extra fields — the daemon can add `segments`,
`word_timestamps`, etc. without breaking backward compatibility.

Alternatively, the daemon may skip the `{success, data}` envelope
and return the payload at the root — the client accepts both shapes.

### Errors

| Status | Meaning | Client behaviour |
|--------|---------|-----------------|
| 200    | Success | Text inserted into the chat input |
| 404    | Endpoint not implemented yet | Silent fallback: audio attached to the next message |
| 413    | File too large | Silent fallback, audio attached |
| 422    | Audio unreadable / empty | Silent fallback |
| 401    | Unauthorised | Handled by the auth interceptor — user re-auths |
| 5xx    | Daemon error | Silent fallback |

The client never shows raw HTTP errors for this endpoint. Failure
falls back to attachment so the user's voice message is not lost.

## Recommended implementations

### Whisper (local, recommended for privacy-first deployments)

```python
from whisper import load_model

model = load_model("base")  # ~150 MB, ~5x realtime on CPU

@app.post("/api/transcribe")
async def transcribe(audio: UploadFile, language: str | None = None):
    with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as f:
        f.write(await audio.read())
        path = f.name
    result = model.transcribe(path, language=language)
    return {
        "success": True,
        "data": {
            "text": result["text"].strip(),
            "language": result.get("language"),
        }
    }
```

Hardware: CPU-only works for `base`, `small`. `large-v3` needs a GPU
to stay responsive.

### OpenAI Whisper API (zero infra, pay-per-use)

```python
import openai

@app.post("/api/transcribe")
async def transcribe(audio: UploadFile, language: str | None = None):
    with tempfile.NamedTemporaryFile(suffix=".m4a") as f:
        f.write(await audio.read())
        f.seek(0)
        client = openai.OpenAI()
        result = client.audio.transcriptions.create(
            model="whisper-1",
            file=f,
            language=language,
        )
    return {"success": True, "data": {"text": result.text}}
```

Cost: ~$0.006 / minute of audio.

### Deepgram (streaming, lowest latency)

Recommended once the client supports streaming upload — not today.
The current client uploads the whole file after the user presses
stop; Deepgram's HTTP endpoint is fine for that.

## Client-side preference

Users can pick (via `VoiceInputService.setPreference`):

- `auto` (default) — live on-device where available, else server
- `alwaysServer` — upload every recording, regardless of native
  availability. Good for consistent quality and privacy audits.
- `nativeOnly` — never call the server. Falls back to attaching the
  raw audio file if the platform has no native STT (Linux).

The preference is persisted via `SharedPreferences`.

## Security

- Audio is uploaded once, transcribed, then discarded client-side.
  The client deletes its temp file immediately after a successful
  response.
- The daemon SHOULD NOT persist raw audio after returning a
  transcription, unless the user has explicitly opted in.
- Transport: HTTPS only in production — the same stack as the rest
  of the API.
