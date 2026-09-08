"""Query the Foundry IQ knowledge base and print the grounded answer with citations.

Run from the jumpbox - the search service is private.

Usage:
    python ask_agent.py --search-endpoint https://<name>.search.windows.net \
        --question "What does the document say about X?"
"""

import argparse
import json

import requests
from azure.identity import DefaultAzureCredential

SEARCH_SCOPE = "https://search.azure.com/.default"
AGENTIC_API_VERSION = "2026-05-01-preview"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--search-endpoint", required=True)
    p.add_argument("--knowledge-base", default="spo-knowledge-base")
    p.add_argument("--question", required=True)
    args = p.parse_args()

    credential = DefaultAzureCredential()
    token = credential.get_token(SEARCH_SCOPE).token
    endpoint = args.search_endpoint.rstrip("/")

    url = (
        f"{endpoint}/knowledgeBases/{args.knowledge_base}/retrieve"
        f"?api-version={AGENTIC_API_VERSION}"
    )
    payload = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": args.question}]}]
    }

    resp = requests.post(
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
        timeout=120,
    )
    if resp.status_code >= 400:
        print(f"FAILED {resp.status_code}")
        print(resp.text)
        return 1

    body = resp.json()

    print("\n=== Answer ===")
    for message in body.get("response", []):
        for part in message.get("content", []):
            print(part.get("text", ""))

    refs = body.get("references", [])
    if refs:
        print("\n=== Citations ===")
        for ref in refs:
            source = ref.get("sourceData") or {}
            print(f"  - {source.get('title') or ref.get('docKey') or json.dumps(ref)[:120]}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
