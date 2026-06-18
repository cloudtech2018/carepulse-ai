#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import argparse
import hashlib
import hmac
import json
import os
import secrets
import socket
import tempfile
import threading
import time
import uuid


DEFAULT_DATA_PATH = Path(__file__).with_name("data").joinpath("carepulse.json")
DATA_PATH = Path(os.environ.get("CAREPULSE_DATA_PATH", DEFAULT_DATA_PATH))
TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30
MAX_BODY_BYTES = 1024 * 1024
MAX_SENSOR_RECORDS_PER_USER = 2_000
ACTIVITY_LABELS = {"Walking", "Sitting", "Standing", "Inactivity", "Unknown"}
STORE_LOCK = threading.RLock()


def empty_store():
    return {"users": {}, "tokens": {}, "sensor_records": []}


def normalize_store(store):
    store.setdefault("users", {})
    store.setdefault("tokens", {})
    store.setdefault("sensor_records", [])

    for token, value in list(store["tokens"].items()):
        if isinstance(value, str):
            store["tokens"][token] = {
                "userId": value,
                "createdAt": time.time(),
                "expiresAt": time.time() + TOKEN_TTL_SECONDS,
            }

    return store


def load_store():
    with STORE_LOCK:
        if not DATA_PATH.exists():
            return empty_store()

        with DATA_PATH.open("r", encoding="utf-8") as file:
            return normalize_store(json.load(file))


def save_store(store):
    with STORE_LOCK:
        DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
        normalize_store(store)

        with tempfile.NamedTemporaryFile(
            "w",
            delete=False,
            dir=DATA_PATH.parent,
            encoding="utf-8",
        ) as file:
            json.dump(store, file, indent=2, sort_keys=True)
            file.write("\n")
            temp_path = Path(file.name)

        temp_path.replace(DATA_PATH)


def hash_password(password, salt):
    value = f"{salt}:{password}".encode("utf-8")
    return hashlib.sha256(value).hexdigest()


def public_user(user):
    return {"id": user["id"], "name": user["name"], "email": user["email"]}


def create_token(store, user_id):
    token = secrets.token_urlsafe(32)
    now = time.time()
    store["tokens"][token] = {
        "userId": user_id,
        "createdAt": now,
        "expiresAt": now + TOKEN_TTL_SECONDS,
    }
    return token


def coerce_float(value, default=0.0, minimum=None, maximum=None):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default

    if minimum is not None:
        number = max(minimum, number)
    if maximum is not None:
        number = min(maximum, number)
    return number


def compact_user_records(store, user_id):
    user_records = [record for record in store["sensor_records"] if record.get("userId") == user_id]
    overflow = len(user_records) - MAX_SENSOR_RECORDS_PER_USER
    if overflow <= 0:
        return

    remove_ids = {record["id"] for record in user_records[:overflow]}
    store["sensor_records"] = [
        record for record in store["sensor_records"] if record.get("id") not in remove_ids
    ]


class RequestError(Exception):
    def __init__(self, message, status=400):
        self.message = message
        self.status = status
        super().__init__(message)


class CarePulseServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class CarePulseHandler(BaseHTTPRequestHandler):
    server_version = "CarePulseBackend/1.1"

    def do_OPTIONS(self):
        self.send_response(204)
        self.add_common_headers()
        self.end_headers()

    def do_GET(self):
        path, query = self.parsed_request_target()

        try:
            if path == "/health":
                store = load_store()
                self.send_json(
                    {
                        "ok": True,
                        "service": "CarePulse backend",
                        "version": "1.1",
                        "users": len(store["users"]),
                        "sensorRecords": len(store["sensor_records"]),
                    }
                )
                return

            if path == "/":
                self.send_homepage()
                return

            if path == "/auth/me":
                user = self.require_user()
                self.send_json({"user": public_user(user)})
                return

            if path == "/sensor-records":
                user_id = self.require_user_id()
                limit = int(coerce_float(query.get("limit", ["100"])[0], default=100, minimum=1, maximum=500))
                store = load_store()
                records = [item for item in store["sensor_records"] if item.get("userId") == user_id]
                self.send_json({"records": records[-limit:]})
                return

            if path == "/sensor-summary":
                user_id = self.require_user_id()
                store = load_store()
                records = [item for item in store["sensor_records"] if item.get("userId") == user_id]
                self.send_json({"summary": self.build_sensor_summary(records)})
                return

            self.send_json({"error": "Not found"}, status=404)
        except RequestError as error:
            self.send_json({"error": error.message}, status=error.status)
        except Exception as error:
            print(f"GET {path} failed: {error}", flush=True)
            self.send_json({"error": "Server error"}, status=500)

    def do_POST(self):
        path, _ = self.parsed_request_target()

        try:
            if path == "/auth/register":
                self.handle_register()
                return

            if path == "/auth/login":
                self.handle_login()
                return

            if path == "/auth/logout":
                self.handle_logout()
                return

            if path == "/sensor-records":
                self.handle_sensor_record()
                return

            self.send_json({"error": "Not found"}, status=404)
        except RequestError as error:
            self.send_json({"error": error.message}, status=error.status)
        except Exception as error:
            print(f"POST {path} failed: {error}", flush=True)
            self.send_json({"error": "Server error"}, status=500)

    def handle_register(self):
        payload = self.read_json()
        name = str(payload.get("name", "")).strip()
        email = str(payload.get("email", "")).strip().lower()
        password = str(payload.get("password", ""))

        if not name:
            raise RequestError("Name is required.")
        if "@" not in email or "." not in email.rsplit("@", 1)[-1]:
            raise RequestError("A valid email is required.")
        if len(password) < 4:
            raise RequestError("Password must be at least 4 characters.")

        store = load_store()
        if email in store["users"]:
            raise RequestError("This email is already registered.", status=409)

        user_id = str(uuid.uuid4())
        salt = secrets.token_hex(16)
        store["users"][email] = {
            "id": user_id,
            "name": name,
            "email": email,
            "salt": salt,
            "passwordHash": hash_password(password, salt),
            "createdAt": time.time(),
        }
        token = create_token(store, user_id)
        save_store(store)

        self.send_json({"token": token, "user": public_user(store["users"][email])}, status=201)

    def handle_login(self):
        payload = self.read_json()
        email = str(payload.get("email", "")).strip().lower()
        password = str(payload.get("password", ""))
        store = load_store()
        user = store["users"].get(email)

        if not user:
            raise RequestError("Invalid email or password.", status=401)

        password_hash = hash_password(password, user["salt"])
        if not hmac.compare_digest(user["passwordHash"], password_hash):
            raise RequestError("Invalid email or password.", status=401)

        token = create_token(store, user["id"])
        save_store(store)
        self.send_json({"token": token, "user": public_user(user)})

    def handle_logout(self):
        token = self.bearer_token()
        if token:
            store = load_store()
            store["tokens"].pop(token, None)
            save_store(store)

        self.send_json({"ok": True})

    def handle_sensor_record(self):
        user_id = self.require_user_id()
        payload = self.read_json()
        samples = payload.get("samples", [])
        features = payload.get("features", {})

        if not isinstance(samples, list):
            raise RequestError("Samples must be a list.")
        if not isinstance(features, dict):
            raise RequestError("Features must be an object.")

        activity = str(payload.get("activity", "Unknown")).strip()
        if activity not in ACTIVITY_LABELS:
            activity = "Unknown"

        record = {
            "id": str(uuid.uuid4()),
            "userId": user_id,
            "recordedAt": coerce_float(payload.get("recordedAt"), default=time.time()),
            "activity": activity,
            "confidence": coerce_float(payload.get("confidence"), default=0, minimum=0, maximum=1),
            "features": {
                "meanMagnitude": coerce_float(features.get("meanMagnitude")),
                "standardDeviation": coerce_float(features.get("standardDeviation")),
                "magnitudeRange": coerce_float(features.get("magnitudeRange")),
                "verticalMean": coerce_float(features.get("verticalMean")),
            },
            "samples": [self.normalize_sample(sample) for sample in samples[:120]],
            "createdAt": time.time(),
        }

        store = load_store()
        store["sensor_records"].append(record)
        compact_user_records(store, user_id)
        save_store(store)

        self.send_json({"ok": True, "recordId": record["id"]}, status=201)

    def authenticated_user_id(self):
        token = self.bearer_token()
        if not token:
            return None

        store = load_store()
        token_record = store["tokens"].get(token)
        if not token_record:
            return None

        if token_record.get("expiresAt", 0) < time.time():
            store["tokens"].pop(token, None)
            save_store(store)
            return None

        return token_record.get("userId")

    def require_user_id(self):
        user_id = self.authenticated_user_id()
        if not user_id:
            raise RequestError("Unauthorized", status=401)
        return user_id

    def require_user(self):
        user_id = self.require_user_id()
        store = load_store()
        for user in store["users"].values():
            if user["id"] == user_id:
                return user
        raise RequestError("Unauthorized", status=401)

    def bearer_token(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return None
        return header.removeprefix("Bearer ").strip()

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise RequestError("Invalid Content-Length header.")

        if length > MAX_BODY_BYTES:
            raise RequestError("Request body is too large.", status=413)
        if length == 0:
            return {}

        raw_body = self.rfile.read(length).decode("utf-8")
        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError:
            raise RequestError("Request body must be valid JSON.")

        if not isinstance(payload, dict):
            raise RequestError("Request body must be a JSON object.")
        return payload

    def normalize_sample(self, sample):
        if not isinstance(sample, dict):
            return {"x": 0.0, "y": 0.0, "z": 0.0}
        return {
            "x": coerce_float(sample.get("x")),
            "y": coerce_float(sample.get("y")),
            "z": coerce_float(sample.get("z")),
        }

    def build_sensor_summary(self, records):
        counts = {label: 0 for label in ACTIVITY_LABELS if label != "Unknown"}
        latest_record = records[-1] if records else None

        for record in records:
            activity = record.get("activity", "Unknown")
            if activity in counts:
                counts[activity] += 1

        average_confidence = 0
        if records:
            average_confidence = sum(record.get("confidence", 0) for record in records) / len(records)

        return {
            "totalRecords": len(records),
            "activityCounts": counts,
            "averageConfidence": round(average_confidence, 4),
            "latestActivity": latest_record.get("activity") if latest_record else None,
            "latestRecordedAt": latest_record.get("recordedAt") if latest_record else None,
        }

    def parsed_request_target(self):
        parsed = urlparse(self.path)
        return parsed.path, parse_qs(parsed.query)

    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.add_common_headers()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_homepage(self):
        store = load_store()
        endpoints = [
            ("GET", "/health", "Backend status and record counts"),
            ("POST", "/auth/register", "Create an account"),
            ("POST", "/auth/login", "Sign in and receive a bearer token"),
            ("POST", "/auth/logout", "Revoke the current bearer token"),
            ("GET", "/auth/me", "Return the signed-in user"),
            ("POST", "/sensor-records", "Save an accelerometer/SVM sensor window"),
            ("GET", "/sensor-records?limit=100", "Fetch recent sensor records"),
            ("GET", "/sensor-summary", "Fetch activity counts and latest activity"),
        ]
        endpoint_rows = "\n".join(
            f"<tr><td><code>{method}</code></td><td><code>{path}</code></td><td>{description}</td></tr>"
            for method, path, description in endpoints
        )
        body = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CarePulse Backend</title>
  <style>
    :root {{
      color-scheme: light;
      --ink: #071a33;
      --muted: #596579;
      --line: #d8e3ef;
      --panel: #ffffff;
      --page: #f4f8fc;
      --blue: #0b5fb3;
      --teal: #10a79d;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
      background: var(--page);
    }}
    main {{
      width: min(940px, calc(100% - 32px));
      margin: 0 auto;
      padding: 44px 0;
    }}
    header {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
      margin-bottom: 24px;
    }}
    h1 {{
      margin: 0 0 8px;
      font-size: clamp(32px, 6vw, 54px);
      line-height: 1;
      letter-spacing: 0;
    }}
    p {{
      margin: 0;
      color: var(--muted);
      font-size: 17px;
      line-height: 1.5;
    }}
    .badge {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border: 1px solid rgba(16, 167, 157, 0.3);
      border-radius: 999px;
      background: rgba(16, 167, 157, 0.1);
      color: #08746f;
      font-weight: 700;
      white-space: nowrap;
    }}
    .dot {{
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: var(--teal);
    }}
    section {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 22px;
      margin-top: 16px;
      box-shadow: 0 12px 30px rgba(7, 26, 51, 0.06);
    }}
    .stats {{
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 12px;
    }}
    .stat {{
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      background: #fbfdff;
    }}
    .stat strong {{
      display: block;
      font-size: 30px;
      line-height: 1.1;
      color: var(--blue);
    }}
    .stat span {{
      color: var(--muted);
      font-size: 14px;
      font-weight: 650;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      margin-top: 14px;
    }}
    th, td {{
      padding: 12px 10px;
      border-top: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
    }}
    th {{
      color: var(--muted);
      font-size: 13px;
      text-transform: uppercase;
      letter-spacing: 0;
    }}
    code {{
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      color: #084b90;
      font-size: 14px;
    }}
    a {{
      color: var(--blue);
      font-weight: 700;
    }}
    @media (max-width: 720px) {{
      header {{
        align-items: flex-start;
        flex-direction: column;
      }}
      .stats {{
        grid-template-columns: 1fr;
      }}
      th:nth-child(3), td:nth-child(3) {{
        display: none;
      }}
    }}
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>CarePulse Backend</h1>
        <p>Local API for CarePulse AI authentication and sensor-window recording.</p>
      </div>
      <div class="badge"><span class="dot"></span> Running</div>
    </header>

    <section class="stats" aria-label="Backend stats">
      <div class="stat"><strong>1.1</strong><span>Version</span></div>
      <div class="stat"><strong>{len(store["users"])}</strong><span>Registered users</span></div>
      <div class="stat"><strong>{len(store["sensor_records"])}</strong><span>Sensor records</span></div>
    </section>

    <section>
      <h2>Quick Check</h2>
      <p>Use <a href="/health">/health</a> to confirm JSON status. In the iOS app, keep the Backend URL set to this server root.</p>
    </section>

    <section>
      <h2>Endpoints</h2>
      <table>
        <thead><tr><th>Method</th><th>Path</th><th>Purpose</th></tr></thead>
        <tbody>{endpoint_rows}</tbody>
      </table>
    </section>
  </main>
</body>
</html>
"""
        encoded_body = body.encode("utf-8")
        self.send_response(200)
        self.add_common_headers()
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded_body)))
        self.end_headers()
        self.wfile.write(encoded_body)

    def add_common_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type")

    def log_message(self, format, *args):
        print("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), format % args))


def main():
    parser = argparse.ArgumentParser(description="CarePulse backend")
    parser.add_argument("--host", default=os.environ.get("HOST", "0.0.0.0"))
    parser.add_argument("--port", default=int(os.environ.get("PORT", "8765")), type=int)
    args = parser.parse_args()

    server = CarePulseServer((args.host, args.port), CarePulseHandler)
    print(f"CarePulse backend running at http://{args.host}:{args.port}")
    for address in local_ipv4_addresses():
        print(f"Try on iPhone: http://{address}:{args.port}/health")
    print(f"Data file: {DATA_PATH}")
    server.serve_forever()


def local_ipv4_addresses():
    addresses = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET, socket.SOCK_STREAM):
            address = info[4][0]
            if not address.startswith("127.") and address not in addresses:
                addresses.append(address)
    except OSError:
        pass
    return addresses


if __name__ == "__main__":
    main()
