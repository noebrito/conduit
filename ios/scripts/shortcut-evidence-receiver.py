#!/usr/bin/env python3
"""Loopback fixture for ShortcutEvidenceTests; never accepts personal data.

Run with --evidence-dir, then pass TEST_RUNNER_CONDUIT_TEST_WEBHOOK_URL as
http://127.0.0.1:18765/existing-destination to the focused XCTest.
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    args.evidence_dir.mkdir(parents=True, exist_ok=True)

    class Receiver(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            receipt = {
                "method": "POST", "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "content_type": self.headers.get("Content-Type"),
                "user_agent": self.headers.get("User-Agent"), "body": body,
            }
            (args.evidence_dir / "shortcut-receiver-request.json").write_text(
                json.dumps(receipt, indent=2, sort_keys=True) + "\n"
            )
            batches = body.get("batches", [])
            samples = [sample for batch in batches for sample in batch.get("samples", [])]
            valid = (
                self.path == "/existing-destination"
                and self.headers.get("Authorization") == "Bearer shortcut-evidence-token"
                and self.headers.get("Content-Type") == "application/json"
                and body.get("schemaVersion") == "v1"
                and len(batches) == 1
                and batches[0].get("hkTypeId") == "HKQuantityTypeIdentifierStepCount"
                and len(samples) == 1
                and samples[0].get("quantity") == {"value": 42, "unit": "count"}
            )
            response = {"accepted": 1, "deduped": 0} if valid else {"error": "Unexpected test payload"}
            (args.evidence_dir / "shortcut-receiver-response.json").write_text(
                json.dumps(response, indent=2) + "\n"
            )
            encoded = json.dumps(response).encode()
            self.send_response(200 if valid else 400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    print(f"Listening on http://127.0.0.1:{args.port}/existing-destination", flush=True)
    server = HTTPServer(("127.0.0.1", args.port), Receiver)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
