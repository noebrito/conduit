#!/usr/bin/env python3
"""Minimal Conduit webhook receiver: stores every sample in SQLite. Stdlib only.

  CONDUIT_TOKEN=<the token you set in the Conduit app> python3 receiver.py
"""
import hmac, json, os, sqlite3, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.environ.get("CONDUIT_TOKEN", "")
if not TOKEN:                                                 # published default: not a secret
    TOKEN = "change-me"
    print("WARNING: CONDUIT_TOKEN is unset, so this receiver accepts the default token "
          "published in this example file. Set CONDUIT_TOKEN before using it for anything "
          "beyond a quick local test.", file=sys.stderr)

db = sqlite3.connect("conduit.db", check_same_thread=False)
db.execute("""CREATE TABLE IF NOT EXISTS samples(
    uuid TEXT PRIMARY KEY, hk_type_id TEXT, start_ms INTEGER, end_ms INTEGER,
    shape TEXT, payload TEXT)""")

SHAPES = ("quantity", "category", "workout", "correlation", "route")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or not hmac.compare_digest(  # constant-time
                auth[len("Bearer "):].encode(), TOKEN.encode()):
            return self.reply(401, {"error": "unauthorized"})
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            env = json.loads(body)
        except ValueError:
            return self.reply(400, {"error": "invalid json"})     # permanent: app won't retry
        if env.get("schemaVersion") != "v1":
            return self.reply(400, {"error": "unsupported schemaVersion"})

        accepted = deduped = deleted = 0
        try:
            with db:                                              # one transaction per batch
                for batch in env.get("batches", []):              # absent on Test Connection
                    hk = batch.get("hkTypeId", "")
                    for s in batch.get("samples", []):
                        shape = next((k for k in SHAPES if k in s), None)
                        if shape is None:
                            continue                              # unknown future shape: skip, don't fail
                        cur = db.execute(
                            "INSERT OR IGNORE INTO samples VALUES (?,?,?,?,?,?)",
                            (s.get("uuid", ""), hk, int(s.get("startUnixMs", 0)),
                             int(s.get("endUnixMs", 0)), shape, json.dumps(s[shape])))
                        accepted += cur.rowcount
                        deduped += 1 - cur.rowcount               # idempotent on sample.uuid
                    for uuid in batch.get("deletedUuids", []):    # HealthKit tombstones
                        deleted += db.execute(
                            "DELETE FROM samples WHERE uuid=?", (uuid,)).rowcount
        except Exception as e:                                    # transient: 500 -> app retries
            return self.reply(500, {"error": str(e)})
        self.reply(200, {"accepted": accepted, "deduped": deduped, "deleted": deleted})

    def reply(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


if __name__ == "__main__":
    HTTPServer(("", int(os.environ.get("CONDUIT_PORT", "8099"))), Handler).serve_forever()
