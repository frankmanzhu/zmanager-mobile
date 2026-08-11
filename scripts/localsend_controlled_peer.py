#!/usr/bin/env python3
"""Send one deterministic LocalSend v2 upload to a test receiver."""

import hashlib
import json
import sys
import urllib.parse
import urllib.request


def request(url: str, body: bytes) -> tuple[int, bytes]:
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.read()
    except Exception as error:
        if hasattr(error, "code") and hasattr(error, "read"):
            return error.code, error.read()
        raise


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 53317
    payload = b"controlled LocalSend peer payload\n"
    file_id = "controlled-peer-file"
    digest = hashlib.sha256(payload).hexdigest()
    base = f"http://{host}:{port}"
    prepare = {
        "info": {
            "alias": "ZManager controlled test peer",
            "version": "2.0",
            "deviceModel": "test",
            "deviceType": "desktop",
            "fingerprint": "controlled-peer",
            "port": port,
            "protocol": "http",
            "download": False,
            "announce": False,
        },
        "files": {
            file_id: {
                "id": file_id,
                "fileName": "../controlled-peer.txt",
                "size": len(payload),
                "fileType": "text/plain",
                "sha256": digest,
            }
        },
    }
    status, response = request(
        f"{base}/api/localsend/v2/prepare-upload",
        json.dumps(prepare).encode(),
    )
    if status < 200 or status >= 300:
        raise SystemExit(f"prepare-upload failed: {status} {response.decode(errors='replace')}")
    session = json.loads(response)
    token = session["files"][file_id]
    query = urllib.parse.urlencode(
        {"sessionId": session["sessionId"], "fileId": file_id, "token": token}
    )
    status, response = request(f"{base}/api/localsend/v2/upload?{query}", payload)
    if status < 200 or status >= 300:
        raise SystemExit(f"upload failed: {status} {response.decode(errors='replace')}")
    print(json.dumps({"status": status, "file": "controlled-peer.txt", "sha256": digest}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
