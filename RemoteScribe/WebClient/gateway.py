#!/usr/bin/env python3
"""Private HTTPS bridge from Safari to the existing Remote Scribe TCP protocol."""

import argparse
import hashlib
import hmac
import json
import mimetypes
import os
import secrets
import socket
import sqlite3
import ssl
import struct
import sys
import threading
import time
import unicodedata
import uuid
from http.cookies import SimpleCookie
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import parse_qs, urlparse

PAIR = 1
START_SESSION = 2
AUDIO_CHUNK = 3
STOP_SESSION = 4
SESSION_STATUS = 5
PING = 6
ERROR = 7
NO_SESSION = "00000000-0000-0000-0000-000000000000"
MAX_BODY = 1_048_576


def encode_frame(kind, session_id=NO_SESSION, sequence=0, payload=b""):
    session = str(uuid.UUID(session_id)).upper().encode("ascii")
    body = bytes([kind]) + session + struct.pack("!Q", int(sequence)) + payload
    if len(body) > MAX_BODY:
        raise ValueError("Trame Remote Scribe trop volumineuse")
    return struct.pack("!I", len(body)) + body


def read_exact(sock, size):
    result = bytearray()
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise ConnectionError("Le serveur Remote Scribe a fermé la connexion.")
        result.extend(chunk)
    return bytes(result)


class RemoteCoreConnection:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.sock = None
        self.send_lock = threading.Lock()
        self.condition = threading.Condition()
        self.pair_response = None
        self.statuses = {}
        self.errors = {}
        self.connection_error = None
        self.status_observer = None

    def connect(self, device_id="web-client", device_name="Remote Scribe WebClient"):
        with self.condition:
            if self.sock is not None and self.connection_error is None:
                return self.pair_response
            self.close()
            self.pair_response = None
            self.connection_error = None
            self.sock = socket.create_connection((self.host, self.port), timeout=5)
            self.sock.settimeout(None)
            threading.Thread(target=self._read_loop, daemon=True).start()
            request = {
                "protocolVersion": 1,
                "deviceID": "web-" + device_id,
                "deviceName": device_name,
            }
            self.send_json(PAIR, NO_SESSION, request)
            deadline = time.monotonic() + 6
            while self.pair_response is None and self.connection_error is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Le Mac ne répond pas à PAIR.")
                self.condition.wait(remaining)
            if self.connection_error:
                raise ConnectionError(self.connection_error)
            return self.pair_response

    def close(self):
        sock, self.sock = self.sock, None
        if sock:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass

    def send(self, kind, session_id=NO_SESSION, sequence=0, payload=b""):
        if self.sock is None:
            raise ConnectionError("La passerelle n’est pas connectée au serveur Mac.")
        data = encode_frame(kind, session_id, sequence, payload)
        with self.send_lock:
            self.sock.sendall(data)

    def send_json(self, kind, session_id, value):
        self.send(kind, session_id, payload=json.dumps(value, separators=(",", ":")).encode("utf-8"))

    def start_session(self, session_id, language):
        self.connect()
        with self.condition:
            self.statuses.pop(session_id, None)
            self.errors.pop(session_id, None)
        payload = {
            "format": {"sampleRate": 16000, "channels": 1, "bitsPerSample": 16, "codec": "pcm_s16le"},
            "modeIdentifier": None,
            "language": language or "fr",
        }
        self.send_json(START_SESSION, session_id, payload)
        return self.wait_for_state(session_id, {"recording", "failed"}, 8)

    def send_chunk(self, session_id, sequence, data):
        if len(data) % 2:
            raise ValueError("Chunk PCM de taille impaire.")
        self.send(AUDIO_CHUNK, session_id, sequence, data)

    def stop_session(self, session_id, frames_sent):
        self.send_json(STOP_SESSION, session_id, {"framesSent": int(frames_sent)})
        return self.wait_for_state(session_id, {"processing", "completed", "failed"}, 10)

    def status(self, session_id):
        with self.condition:
            if session_id in self.errors:
                return {"state": "failed", "message": self.errors[session_id]}
            return self.statuses.get(session_id, {"state": "processing", "message": "Traitement sur le Mac…"})

    def wait_for_state(self, session_id, states, timeout):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                status = self.status(session_id)
                if status.get("state") in states:
                    return status
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Réponse du Mac trop lente.")
                self.condition.wait(remaining)

    def _read_loop(self):
        try:
            while self.sock is not None:
                length = struct.unpack("!I", read_exact(self.sock, 4))[0]
                if length < 45 or length > MAX_BODY:
                    raise ValueError("Trame Remote Scribe invalide.")
                body = read_exact(self.sock, length)
                kind = body[0]
                session_id = str(uuid.UUID(body[1:37].decode("ascii"))).upper()
                payload = body[45:]
                value = json.loads(payload.decode("utf-8")) if payload else {}
                value = self._complete_superwhisper_result(value)
                observed_status = None
                with self.condition:
                    if kind == PAIR:
                        self.pair_response = value
                    elif kind == SESSION_STATUS:
                        self.statuses[session_id] = value
                        observed_status = dict(value)
                    elif kind == ERROR:
                        self.errors[session_id] = value.get("message", "Erreur Remote Scribe")
                    self.condition.notify_all()
                if observed_status is not None and self.status_observer is not None:
                    self.status_observer(session_id, observed_status)
        except Exception as error:
            with self.condition:
                self.connection_error = str(error)
                self.condition.notify_all()
            self.close()

    @staticmethod
    def _complete_superwhisper_result(value):
        """Recover the exact raw/LLM pair from completed Superwhisper metadata."""
        if value.get("state") != "completed":
            return value
        location = value.get("resultLocation")
        if not location or Path(location).name != "meta.json":
            return value
        def non_empty(candidate):
            return candidate.strip() if isinstance(candidate, str) and candidate.strip() else None

        deadline = time.monotonic() + 30
        while True:
            try:
                metadata = json.loads(Path(location).read_text(encoding="utf-8"))
            except (OSError, ValueError, TypeError):
                return value
            llm = non_empty(metadata.get("llmResult"))
            mode_name = non_empty(metadata.get("modeName"))
            expects_llm = bool(
                llm
                or non_empty(metadata.get("languageModelName"))
                or non_empty(metadata.get("prompt"))
                or (mode_name and mode_name != "Default")
            )
            if not expects_llm or llm or time.monotonic() >= deadline:
                break
            time.sleep(0.25)

        raw = non_empty(metadata.get("rawResult"))
        final = llm or non_empty(metadata.get("result")) or raw
        if raw:
            value["rawTranscription"] = raw
        if final:
            value["finalText"] = final
            value["transcription"] = final
        return value


class ClientLease:
    def __init__(self, machine_name, timeout=20):
        self.machine_name = machine_name
        self.timeout = timeout
        self.lock = threading.Lock()
        self.client_id = None
        self.profile_id = None
        self.profile_name = None
        self.last_seen = 0

    @staticmethod
    def normalize(value):
        value = str(value or "").strip()
        if value.lower().endswith(".local"):
            value = value[:-6]
        value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
        return "".join(character.lower() for character in value if character.isalnum())

    def matches_machine(self, requested_machine):
        return self.normalize(requested_machine) == self.normalize(self.machine_name)

    def claim(self, client_id, profile_id, profile_name, requested_machine):
        if not client_id or not profile_id or not profile_name:
            return False, False, HTTPStatus.BAD_REQUEST, "Profil incomplet."
        if not self.matches_machine(requested_machine):
            return False, False, HTTPStatus.CONFLICT, "Le nom du PC ne correspond pas."
        now = time.monotonic()
        with self.lock:
            if self.client_id and now - self.last_seen > self.timeout:
                self.client_id = None
                self.profile_id = None
                self.profile_name = None
            if self.client_id and self.client_id != client_id:
                return False, False, HTTPStatus.LOCKED, "Ce PC est déjà utilisé par une autre personne."
            changed = self.client_id != client_id or self.profile_id != profile_id or self.profile_name != profile_name
            self.client_id = client_id
            self.profile_id = profile_id
            self.profile_name = profile_name
            self.last_seen = now
            return True, changed, HTTPStatus.OK, ""

    def authorized_profile(self, client_id):
        now = time.monotonic()
        with self.lock:
            if self.client_id and now - self.last_seen > self.timeout:
                self.client_id = None
                self.profile_id = None
                self.profile_name = None
            if not self.client_id or self.client_id != client_id:
                return None
            self.last_seen = now
            return self.profile_id

    def release(self, client_id):
        with self.lock:
            if self.client_id != client_id:
                return False
            self.client_id = None
            self.profile_id = None
            self.profile_name = None
            self.last_seen = 0
            return True

    def available(self):
        now = time.monotonic()
        with self.lock:
            return not self.client_id or now - self.last_seen > self.timeout


class HistoryStore:
    def __init__(self, database_path, sessions_directory):
        self.database_path = Path(database_path)
        self.sessions_directory = Path(sessions_directory).resolve()
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self.database_path.parent.chmod(0o700)
        self.lock = threading.RLock()
        self.database = sqlite3.connect(str(self.database_path), check_same_thread=False)
        self.database.row_factory = sqlite3.Row
        with self.lock:
            self.database.execute("PRAGMA journal_mode=WAL")
            self.database.execute("PRAGMA foreign_keys=ON")
            self.database.execute("""
                CREATE TABLE IF NOT EXISTS profiles (
                    profile_id TEXT PRIMARY KEY,
                    token_hash TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)
            self.database.execute("""
                CREATE TABLE IF NOT EXISTS dictations (
                    session_id TEXT PRIMARY KEY,
                    profile_id TEXT NOT NULL REFERENCES profiles(profile_id),
                    started_at REAL NOT NULL,
                    completed_at REAL NOT NULL,
                    duration_seconds REAL NOT NULL,
                    bytes_received INTEGER NOT NULL,
                    backend TEXT,
                    raw_text TEXT,
                    final_text TEXT,
                    audio_path TEXT,
                    audio_bytes INTEGER NOT NULL DEFAULT 0
                )
            """)
            self.database.execute("""
                CREATE INDEX IF NOT EXISTS idx_dictations_profile_completed
                ON dictations(profile_id, completed_at DESC)
            """)
            self.database.execute("PRAGMA optimize")
            self.database.commit()
        self.database_path.chmod(0o600)

    @staticmethod
    def token_hash(profile_token):
        return hashlib.sha256(profile_token.encode("utf-8")).hexdigest()

    @staticmethod
    def valid_identity(profile_id, profile_token):
        try:
            uuid.UUID(str(profile_id))
        except (ValueError, TypeError, AttributeError):
            return False
        return isinstance(profile_token, str) and 32 <= len(profile_token) <= 128 and all(
            character in "0123456789abcdefABCDEF" for character in profile_token
        )

    def ensure_profile(self, profile_id, profile_token, display_name):
        if not self.valid_identity(profile_id, profile_token):
            return False
        digest = self.token_hash(profile_token)
        now = time.time()
        with self.lock:
            existing = self.database.execute(
                "SELECT token_hash FROM profiles WHERE profile_id = ?", (profile_id,)
            ).fetchone()
            if existing is None:
                self.database.execute(
                    "INSERT INTO profiles(profile_id, token_hash, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                    (profile_id, digest, display_name, now, now),
                )
            elif not hmac.compare_digest(existing["token_hash"], digest):
                return False
            else:
                self.database.execute(
                    "UPDATE profiles SET display_name = ?, updated_at = ? WHERE profile_id = ?",
                    (display_name, now, profile_id),
                )
            self.database.commit()
        return True

    def _safe_audio_path(self, session_id, candidate=None):
        path = Path(candidate) if candidate else self.sessions_directory / session_id / "remote.wav"
        try:
            resolved = path.resolve()
            resolved.relative_to(self.sessions_directory)
        except (OSError, ValueError):
            return None
        return resolved if resolved.is_file() else None

    def record(self, profile_id, session_id, status, started_at):
        if status.get("state") != "completed":
            return
        audio = self._safe_audio_path(session_id, status.get("audioLocation"))
        audio_bytes = audio.stat().st_size if audio else 0
        received = max(0, int(status.get("bytesReceived") or max(0, audio_bytes - 44)))
        duration = received / 32000.0
        raw = status.get("rawTranscription")
        final = status.get("finalText") or status.get("transcription")
        completed = time.time()
        with self.lock:
            self.database.execute("""
                INSERT INTO dictations(
                    session_id, profile_id, started_at, completed_at, duration_seconds,
                    bytes_received, backend, raw_text, final_text, audio_path, audio_bytes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    raw_text = excluded.raw_text,
                    final_text = excluded.final_text,
                    audio_path = excluded.audio_path,
                    audio_bytes = excluded.audio_bytes,
                    bytes_received = excluded.bytes_received,
                    duration_seconds = excluded.duration_seconds
            """, (
                session_id, profile_id, started_at, completed, duration, received,
                status.get("backend"), raw, final, str(audio) if audio else None, audio_bytes,
            ))
            self.database.commit()

    def list_for_profile(self, profile_id, limit=25, offset=0):
        limit = max(1, min(int(limit), 100))
        offset = max(0, int(offset))
        with self.lock:
            total = self.database.execute(
                "SELECT COUNT(*) AS total FROM dictations WHERE profile_id = ?", (profile_id,)
            ).fetchone()["total"]
            rows = self.database.execute("""
                SELECT session_id, started_at, completed_at, duration_seconds, backend,
                       raw_text, final_text, audio_bytes
                FROM dictations
                WHERE profile_id = ?
                ORDER BY completed_at DESC
                LIMIT ? OFFSET ?
            """, (profile_id, limit, offset)).fetchall()
        items = [{
            "sessionID": row["session_id"],
            "startedAt": row["started_at"],
            "completedAt": row["completed_at"],
            "durationSeconds": row["duration_seconds"],
            "backend": row["backend"],
            "rawTranscription": row["raw_text"],
            "finalText": row["final_text"],
            "hasAudio": row["audio_bytes"] > 44,
            "audioBytes": row["audio_bytes"],
        } for row in rows]
        return {"items": items, "total": total, "offset": offset, "limit": limit}

    def audio_for_profile(self, profile_id, session_id):
        with self.lock:
            row = self.database.execute(
                "SELECT audio_path FROM dictations WHERE profile_id = ? AND session_id = ?",
                (profile_id, session_id),
            ).fetchone()
        return self._safe_audio_path(session_id, row["audio_path"]) if row and row["audio_path"] else None


class GatewayState:
    def __init__(self, public_directory, data_directory, access_key, machine_name, core):
        self.public_directory = public_directory
        self.data_directory = data_directory
        self.access_key = access_key
        self.machine_name = machine_name
        self.lease = ClientLease(machine_name)
        self.core = core
        application_directory = data_directory.parent
        self.history = HistoryStore(application_directory / "history" / "history.sqlite3", application_directory / "sessions")
        self.session_lock = threading.Lock()
        self.session_profiles = {}
        self.session_started_at = {}
        self.core.status_observer = self.observe_status

    def register_session(self, session_id, profile_id):
        with self.session_lock:
            self.session_profiles[session_id] = profile_id
            self.session_started_at[session_id] = time.time()

    def observe_status(self, session_id, status):
        with self.session_lock:
            profile_id = self.session_profiles.get(session_id)
            started_at = self.session_started_at.get(session_id, time.time())
        if profile_id and status.get("state") == "completed":
            self.history.record(profile_id, session_id, status, started_at)


class WebHandler(BaseHTTPRequestHandler):
    server_version = "RemoteScribeWeb/1"

    @property
    def state(self):
        return self.server.gateway_state

    def log_message(self, fmt, *args):
        if args and str(args[1]).startswith("5"):
            super().log_message(fmt, *args)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Robots-Tag", "noindex, nofollow, noarchive")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self'; frame-ancestors 'none'")
        super().end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/info":
            return self.json_response(HTTPStatus.OK, {
                "machineName": self.state.machine_name,
                "available": self.state.lease.available(),
            })
        if path == "/api/history":
            if not self.authorized():
                return
            query = parse_qs(urlparse(self.path).query)
            try:
                limit = int(query.get("limit", ["25"])[0])
                offset = int(query.get("offset", ["0"])[0])
            except ValueError:
                return self.json_response(HTTPStatus.BAD_REQUEST, {"message": "Pagination invalide."})
            return self.json_response(
                HTTPStatus.OK, self.state.history.list_for_profile(self.profile_id, limit, offset)
            )
        if path.startswith("/api/history/") and path.endswith("/audio"):
            if not self.authorized():
                return
            parts = path.strip("/").split("/")
            if len(parts) != 4:
                return self.json_response(HTTPStatus.NOT_FOUND, {"message": "Audio inconnu."})
            try:
                session_id = str(uuid.UUID(parts[2])).upper()
            except ValueError:
                return self.json_response(HTTPStatus.BAD_REQUEST, {"message": "UUID invalide."})
            audio = self.state.history.audio_for_profile(self.profile_id, session_id)
            if audio is None:
                return self.json_response(HTTPStatus.NOT_FOUND, {"message": "Audio indisponible."})
            return self.send_audio(audio)
        if path.startswith("/api/session/") and path.endswith("/status"):
            if not self.authorized():
                return
            session_id = path.split("/")[3]
            try:
                session_id = str(uuid.UUID(session_id)).upper()
                self.json_response(HTTPStatus.OK, self.state.core.status(session_id))
            except ValueError:
                self.json_response(HTTPStatus.BAD_REQUEST, {"message": "UUID invalide."})
            return
        if path == "/ca.cer":
            return self.send_file(self.state.data_directory / "remote-scribe-ca.cer", "application/x-x509-ca-cert")
        relative = "index.html" if path == "/" else path.lstrip("/")
        if ".." in Path(relative).parts:
            return self.send_error(HTTPStatus.NOT_FOUND)
        return self.send_file(self.state.public_directory / relative)

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            if path == "/api/connect":
                if not self.valid_access_key():
                    return self.json_response(HTTPStatus.FORBIDDEN, {"message": "Accès non reconnu. Scannez le QR code du Mac."})
                request = self.read_json()
                client_id = self.headers.get("X-Remote-Scribe-Client-ID", "")
                profile_name = str(request.get("profileName", "")).strip()[:60]
                profile_id = str(request.get("profileID", "")).strip()
                profile_token = str(request.get("profileToken", "")).strip()
                if not client_id or not profile_name:
                    return self.json_response(HTTPStatus.BAD_REQUEST, {"message": "Profil incomplet."})
                if not self.state.lease.matches_machine(request.get("machineName", "")):
                    return self.json_response(HTTPStatus.CONFLICT, {
                        "message": "Le nom du PC ne correspond pas.", "machineName": self.state.machine_name,
                    })
                if not self.state.history.ensure_profile(profile_id, profile_token, profile_name):
                    return self.json_response(HTTPStatus.FORBIDDEN, {
                        "code": "profile_access_denied", "message": "Ce profil n’est pas reconnu par ce téléphone."
                    })
                allowed, changed, status, message = self.state.lease.claim(
                    client_id, profile_id, profile_name, request.get("machineName", "")
                )
                if not allowed:
                    return self.json_response(status, {"message": message, "machineName": self.state.machine_name})
                if changed:
                    self.state.core.close()
                info = dict(self.state.core.connect(client_id, "Remote Scribe · " + profile_name) or {})
                info.update({"machineName": self.state.machine_name, "profileName": profile_name, "profileID": profile_id})
                return self.json_response(HTTPStatus.OK, info, {"Set-Cookie": self.session_cookie(client_id)})
            if path == "/api/heartbeat":
                if not self.authorized():
                    return
                return self.empty_response(HTTPStatus.NO_CONTENT)
            if path == "/api/disconnect":
                request = self.read_json()
                supplied_key = self.headers.get("X-Remote-Scribe-Key", "") or str(request.get("accessKey", ""))
                client_id = self.headers.get("X-Remote-Scribe-Client-ID", "") or str(request.get("clientID", ""))
                if not self.valid_access_key(supplied_key):
                    return self.json_response(HTTPStatus.FORBIDDEN, {"message": "Accès non reconnu."})
                if self.state.lease.release(client_id):
                    self.state.core.close()
                return self.empty_response(HTTPStatus.NO_CONTENT)
            if not self.authorized():
                return
            if path == "/api/session/start":
                request = self.read_json()
                session_id = str(uuid.UUID(request["sessionID"])).upper()
                self.state.register_session(session_id, self.profile_id)
                status = self.state.core.start_session(session_id, request.get("language"))
                return self.json_response(HTTPStatus.OK, status)
            if path.startswith("/api/session/") and path.endswith("/chunk"):
                session_id = str(uuid.UUID(path.split("/")[3])).upper()
                sequence = int(parse_qs(urlparse(self.path).query).get("sequence", ["-1"])[0])
                data = self.read_body(MAX_BODY - 45)
                self.state.core.send_chunk(session_id, sequence, data)
                return self.empty_response(HTTPStatus.NO_CONTENT)
            if path.startswith("/api/session/") and path.endswith("/stop"):
                session_id = str(uuid.UUID(path.split("/")[3])).upper()
                request = self.read_json()
                status = self.state.core.stop_session(session_id, request.get("framesSent", 0))
                return self.json_response(HTTPStatus.OK, status)
            return self.json_response(HTTPStatus.NOT_FOUND, {"message": "Route inconnue."})
        except (ConnectionError, TimeoutError, OSError) as error:
            self.state.core.close()
            return self.json_response(HTTPStatus.BAD_GATEWAY, {"message": str(error)})
        except (KeyError, ValueError, json.JSONDecodeError) as error:
            return self.json_response(HTTPStatus.BAD_REQUEST, {"message": str(error)})
        except Exception as error:
            return self.json_response(HTTPStatus.INTERNAL_SERVER_ERROR, {"message": str(error)})

    def do_OPTIONS(self):
        self.empty_response(HTTPStatus.NO_CONTENT)

    def authorized(self):
        client_id = self.headers.get("X-Remote-Scribe-Client-ID", "")
        if client_id:
            if not self.valid_access_key():
                self.json_response(HTTPStatus.FORBIDDEN, {"message": "Accès non reconnu. Scannez le QR code du Mac."})
                return False
        else:
            client_id = self.cookie_client_id()
            if not client_id:
                self.json_response(HTTPStatus.FORBIDDEN, {"message": "Accès audio non reconnu."})
                return False
        profile_id = self.state.lease.authorized_profile(client_id)
        if profile_id:
            self.profile_id = profile_id
            return True
        self.json_response(HTTPStatus.UNAUTHORIZED, {"message": "Profil déconnecté. Reconnexion nécessaire."})
        return False

    def session_cookie(self, client_id):
        signature = hmac.new(
            self.state.access_key.encode("utf-8"), client_id.encode("utf-8"), hashlib.sha256
        ).hexdigest()
        return f"RemoteScribeSession={client_id}.{signature}; Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Strict"

    def cookie_client_id(self):
        try:
            cookie = SimpleCookie(self.headers.get("Cookie", ""))
            value = cookie.get("RemoteScribeSession")
            if value is None:
                return None
            client_id, supplied = value.value.rsplit(".", 1)
            expected = hmac.new(
                self.state.access_key.encode("utf-8"), client_id.encode("utf-8"), hashlib.sha256
            ).hexdigest()
            return client_id if hmac.compare_digest(supplied, expected) else None
        except (ValueError, TypeError):
            return None

    def valid_access_key(self, supplied=None):
        supplied = self.headers.get("X-Remote-Scribe-Key", "") if supplied is None else supplied
        return bool(supplied) and hmac.compare_digest(supplied, self.state.access_key)

    def read_body(self, maximum=65536):
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > maximum:
            raise ValueError("Corps de requête trop volumineux.")
        return self.rfile.read(length)

    def read_json(self):
        return json.loads(self.read_body().decode("utf-8"))

    def send_file(self, path, content_type=None):
        try:
            data = path.read_bytes()
        except (FileNotFoundError, IsADirectoryError):
            return self.send_error(HTTPStatus.NOT_FOUND)
        mime = content_type or mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_audio(self, path):
        size = path.stat().st_size
        start, end, status = 0, size - 1, HTTPStatus.OK
        requested = self.headers.get("Range", "")
        if requested:
            try:
                unit, interval = requested.split("=", 1)
                first, last = interval.split("-", 1)
                if unit != "bytes" or "," in interval:
                    raise ValueError
                if first:
                    start = int(first)
                    end = int(last) if last else size - 1
                else:
                    suffix = int(last)
                    start = max(0, size - suffix)
                    end = size - 1
                if start < 0 or end < start or start >= size:
                    raise ValueError
                end = min(end, size - 1)
                status = HTTPStatus.PARTIAL_CONTENT
            except (ValueError, TypeError):
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with path.open("rb") as audio:
            audio.seek(start)
            remaining = length
            while remaining:
                chunk = audio.read(min(65536, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def json_response(self, status, value, headers=None):
        data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for name, header_value in (headers or {}).items():
            self.send_header(name, header_value)
        self.end_headers()
        self.wfile.write(data)

    def empty_response(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()


class OnboardingHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        state = self.server.gateway_state
        parsed = urlparse(self.path)
        if parsed.path == "/ca.cer":
            data = (state.data_directory / "remote-scribe-ca.cer").read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/x-x509-ca-cert")
            self.send_header("Content-Disposition", "attachment; filename=RemoteScribe-CA.cer")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        supplied_key = parse_qs(parsed.query).get("key", [""])[0]
        enrolled = bool(supplied_key) and hmac.compare_digest(supplied_key, state.access_key)
        secure_url = self.server.secure_url + ("?key=" + state.access_key if enrolled else "")
        html = ("<!doctype html><meta name=viewport content='width=device-width'><meta name=robots content=noindex>"
                "<style>body{font:17px -apple-system;padding:28px;line-height:1.5;background:#0b0c10;color:#fff}"
                "a{display:block;margin:20px 0;padding:16px;border-radius:14px;background:#7c52ef;color:#fff;text-align:center;text-decoration:none}</style>"
                "<h1>Installer Remote Scribe</h1><p>Cette étape ne se fait qu’une fois sur cet appareil.</p>"
                "<p>1. Téléchargez le certificat privé, puis installez le profil dans Réglages.</p>"
                "<a href='/ca.cer'>Télécharger le certificat</a>"
                "<p>2. Activez sa confiance dans Réglages → Général → Informations → Réglages des certificats.</p>"
                f"<a href='{secure_url}'>Ouvrir Remote Scribe</a>").encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Robots-Tag", "noindex, nofollow")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers(); self.wfile.write(html)


class LocalThreadingHTTPServer(ThreadingHTTPServer):
    """HTTP server without the slow reverse-DNS lookup done by HTTPServer."""

    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        if isinstance(error, (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


def make_server(address, handler, state):
    server = LocalThreadingHTTPServer(address, handler)
    server.daemon_threads = True
    server.gateway_state = state
    return server


class SecureThreadingHTTPServer(LocalThreadingHTTPServer):
    """Wrap accepted clients instead of the listening socket (Python 3.9 compatible)."""

    daemon_threads = True

    def __init__(self, address, handler, state, ssl_context):
        self.gateway_state = state
        self.ssl_context = ssl_context
        super().__init__(address, handler)

    def get_request(self):
        client, address = super().get_request()
        try:
            return self.ssl_context.wrap_socket(client, server_side=True), address
        except Exception:
            client.close()
            raise


def main():
    parser = argparse.ArgumentParser(description="Passerelle HTTPS privée Remote Scribe")
    parser.add_argument("--https-port", type=int, default=8443)
    parser.add_argument("--onboarding-port", type=int, default=8080)
    parser.add_argument("--core-host", default="127.0.0.1")
    parser.add_argument("--core-port", type=int, default=47365)
    parser.add_argument("--code", help=argparse.SUPPRESS)
    parser.add_argument("--name", default=os.environ.get("REMOTE_SCRIBE_LOCAL_NAME"))
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    data = Path(os.environ.get("REMOTE_SCRIBE_WEB_DATA_DIR", "~/Library/Application Support/RemoteScribe/web")).expanduser()
    certificate = data / "server.crt"
    key = data / "server.key"
    if not certificate.exists() or not key.exists():
        raise SystemExit("Certificat absent. Lancez d’abord ./setup-local-https.sh")
    local_name = args.name or socket.gethostname().split(".")[0]
    access_key_path = data / "web-access.key"
    if access_key_path.exists():
        access_key = access_key_path.read_text(encoding="utf-8").strip()
    else:
        access_key = secrets.token_hex(24)
        access_key_path.write_text(access_key + "\n", encoding="utf-8")
        access_key_path.chmod(0o600)
    secure_url = f"https://{local_name}.local:{args.https_port}/"
    onboarding_url = f"http://{local_name}.local:{args.onboarding_port}/"
    state = GatewayState(
        root / "public", data, access_key, local_name,
        RemoteCoreConnection(args.core_host, args.core_port)
    )

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    https_server = SecureThreadingHTTPServer(
        ("0.0.0.0", args.https_port), WebHandler, state, context
    )

    onboarding = make_server(("0.0.0.0", args.onboarding_port), OnboardingHandler, state)
    onboarding.secure_url = secure_url
    threading.Thread(target=onboarding.serve_forever, daemon=True).start()

    print("\nRemote Scribe WebClient est prêt")
    print("--------------------------------")
    print("Première installation :", onboarding_url)
    print("Page sécurisée       :", secure_url)
    print("Nom du PC            :", local_name)
    print("Profil iPhone        : mémorisé après le premier QR code")
    print("Ctrl-C pour arrêter.\n", flush=True)
    try:
        https_server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        state.core.close(); onboarding.shutdown(); https_server.server_close()


if __name__ == "__main__":
    main()
