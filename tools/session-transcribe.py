#!/usr/bin/python3
"""Local Russian ASR for Podbor's leased voice jobs.

Default: read {"job_id": ..., "lease": ...} from stdin. POST once to the
fixed session-voice endpoint, transcribe locally, print only the transcript.
Local check: /usr/bin/python3 SCRIPT --file /absolute/path/to/recording.ogg

No Telegram token, API key, model download, or outgoing message is used.
Input is capped at 8 MiB and 120 seconds. A run is capped at 240 seconds.
Temporary copies, decoded audio and recognition output are removed on exit,
including handled signals/timeouts. The original --file recording is kept.
"""

import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave


ENDPOINT = "https://lobzdwuqyylthmhsgucd.supabase.co/functions/v1/telegram-bot/session-voice"
MODEL = Path(os.environ.get("PODBOR_WHISPER_MODEL", "~/Library/Application Support/Podbor/ggml-medium-q5_0.bin")).expanduser()
WHISPER = "/opt/homebrew/bin/whisper-cli"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
MAX_BYTES = 8 * 1024 * 1024
MAX_SECONDS = 120
MAX_JSON_BYTES = 4096
MAX_TRANSCRIPT_BYTES = 128 * 1024
RUN_TIMEOUT = 240


class TranscriptionError(Exception):
    """Only fixed, non-sensitive error codes may be displayed."""


def interrupted(signum, frame):
    raise TranscriptionError("time_limit_exceeded" if signum == signal.SIGALRM else "interrupted")


@contextlib.contextmanager
def time_limit(seconds):
    """Bound a stage without extending the surrounding overall deadline."""
    previous, interval = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()
    signal.setitimer(signal.ITIMER_REAL, min(seconds, previous) if previous else seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        if previous:
            signal.setitimer(signal.ITIMER_REAL, max(0.000001, previous - (time.monotonic() - started)), interval)


def reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise TranscriptionError("invalid_job_json")
        value[key] = item
    return value


def read_job():
    with time_limit(10):
        raw = sys.stdin.buffer.read(MAX_JSON_BYTES + 1)
    if not raw or len(raw) > MAX_JSON_BYTES:
        raise TranscriptionError("invalid_job_json")
    try:
        job = json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except (ValueError, UnicodeError, RecursionError):
        raise TranscriptionError("invalid_job_json") from None
    if not isinstance(job, dict) or set(job) != {"job_id", "lease"}:
        raise TranscriptionError("invalid_job_json")
    job_id, lease = job["job_id"], job["lease"]
    valid_id = (type(job_id) is int and 0 < job_id < 2 ** 63) or (
        isinstance(job_id, str) and re.fullmatch(r"[0-9]{1,15}", job_id)
    )
    if not valid_id or not isinstance(lease, str) or not re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", lease):
        raise TranscriptionError("invalid_job_json")
    return job


def bounded_copy(source, destination):
    count = 0
    with destination.open("xb") as target:
        while True:
            chunk = source.read(min(65536, MAX_BYTES + 1 - count))
            if not chunk:
                break
            count += len(chunk)
            if count > MAX_BYTES:
                raise TranscriptionError("audio_too_large")
            target.write(chunk)
    if count == 0:
        raise TranscriptionError("empty_audio")
    return count


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise TranscriptionError("redirect_rejected")


def download(job, destination):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(job, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "audio/*, application/ogg, application/octet-stream", "Accept-Encoding": "identity"},
        method="POST",
    )
    try:
        with time_limit(30), opener.open(request, timeout=10) as response:
            if response.status != 200:
                raise TranscriptionError("download_rejected")
            mime = response.headers.get_content_type()
            if not (mime.startswith("audio/") or mime in ("application/ogg", "application/octet-stream")):
                raise TranscriptionError("unexpected_content_type")
            if response.headers.get("Content-Encoding", "identity").lower() != "identity":
                raise TranscriptionError("unexpected_content_encoding")
            expected = response.headers.get("Content-Length")
            if expected is not None:
                if not expected.isdecimal() or len(expected) > 12:
                    raise TranscriptionError("invalid_content_length")
                expected = int(expected)
                if expected > MAX_BYTES:
                    raise TranscriptionError("audio_too_large")
            count = bounded_copy(response, destination)
            if expected is not None and count != expected:
                raise TranscriptionError("incomplete_audio")
    except urllib.error.HTTPError as exc:
        code = "lease_rejected" if exc.code in (401, 403, 404, 409, 410) else "download_http_error"
        exc.close()
        raise TranscriptionError(code) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise TranscriptionError("download_failed") from None


def run(command, timeout, error_code):
    # A separate process group lets cancellation reap our own child processes.
    with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, start_new_session=True) as process:
        try:
            result = process.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
    if result != 0:
        raise TranscriptionError(error_code)


def transcribe(source, directory):
    decoded = directory / "decoded.wav"
    # Restrict demuxers/protocols so an uploaded playlist cannot fetch URLs or
    # reference other files. Decode just past the cap to reject excess duration.
    run([FFMPEG, "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe",
         "-format_whitelist", "ogg,mp3,wav,flac,aiff,mov", "-i", str(source),
         "-map", "0:a:0", "-t", str(MAX_SECONDS + 0.1), "-vn", "-sn", "-dn",
         "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(decoded)],
        20, "audio_decode_failed")
    with wave.open(str(decoded), "rb") as recording:
        frames = recording.getnframes()
        if recording.getframerate() != 16000 or recording.getnchannels() != 1 or recording.getsampwidth() != 2:
            raise TranscriptionError("invalid_decoded_audio")
        if frames > MAX_SECONDS * 16000:
            raise TranscriptionError("audio_too_long")
        if frames < 1600:
            raise TranscriptionError("audio_too_short")
    output = directory / "recognition"
    run([WHISPER, "-ng", "-m", str(MODEL), "-f", str(decoded), "-l", "ru", "-t", "4",
         "-np", "-nt", "-otxt", "-of", str(output)], 180, "recognition_failed")
    text_file = output.with_suffix(".txt")
    if not text_file.is_file() or text_file.stat().st_size > MAX_TRANSCRIPT_BYTES:
        raise TranscriptionError("invalid_recognition_output")
    transcript = text_file.read_text(encoding="utf-8").strip()
    if not transcript:
        raise TranscriptionError("no_speech_recognized")
    return transcript


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--file", type=Path, help="Local test recording; no HTTP request is made and the original is kept")
    args = parser.parse_args()
    os.umask(0o077)
    for signum in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    signal.setitimer(signal.ITIMER_REAL, RUN_TIMEOUT)
    try:
        job = None if args.file is not None else read_job()
        if not all(os.access(binary, os.X_OK) for binary in (WHISPER, FFMPEG)):
            raise TranscriptionError("local_runtime_missing")
        if not MODEL.is_file() or MODEL.stat().st_size < 1000000:
            raise TranscriptionError("local_model_missing")
        with tempfile.TemporaryDirectory(prefix="podbor-session-audio-", dir="/tmp") as temporary:
            directory = Path(temporary)
            source = directory / "input.audio"
            if args.file is None:
                download(job, source)
            else:
                # Nonblocking open prevents a mistaken FIFO/device from hanging.
                fd = os.open(str(args.file), os.O_RDONLY | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as recording:
                    info = os.fstat(recording.fileno())
                    if not stat.S_ISREG(info.st_mode):
                        raise TranscriptionError("local_recording_not_regular_file")
                    if info.st_size > MAX_BYTES:
                        raise TranscriptionError("audio_too_large")
                    bounded_copy(recording, source)
            transcript = transcribe(source, directory)
        # Emit after cleanup, once, without diagnostics, IDs or lease data.
        print(transcript, flush=True)
        return 0
    except TranscriptionError as exc:
        print("podbor_asr: " + str(exc), file=sys.stderr)
    except subprocess.TimeoutExpired:
        print("podbor_asr: recognition_or_decode_timeout", file=sys.stderr)
    except (OSError, ValueError, wave.Error):
        print("podbor_asr: local_processing_failed", file=sys.stderr)
    except Exception:
        print("podbor_asr: processing_failed", file=sys.stderr)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    return 1


if __name__ == "__main__":
    sys.exit(main())
