"""Create the search index, knowledge source, and Foundry IQ knowledge base.

Knowledge bases are not modelled by azurerm, so this runs post-deploy. It must be
executed from inside the VNet (the jumpbox), because the search service has public
network access disabled.

Usage:
    python New-FoundryIqKnowledgeBase.py --search-endpoint https://<name>.search.windows.net \
        --foundry-endpoint https://<account>.openai.azure.com \
        --chat-deployment <terraform-planner-deployment> --chat-model <planner-model>
"""

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

SEARCH_SCOPE = "https://search.azure.com/.default"

# Knowledge bases and knowledge sources are only available on the preview surface.
DATA_API_VERSION = "2024-07-01"
AGENTIC_API_VERSION = "2026-05-01-preview"


def token(credential) -> str:
    return credential.get_token(SEARCH_SCOPE).token


def put(endpoint: str, path: str, api_version: str, body: dict, credential) -> dict:
    import requests

    url = f"{endpoint}/{path}?api-version={api_version}"
    resp = requests.put(
        url,
        headers={
            "Authorization": f"Bearer {token(credential)}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=60,
    )
    if resp.status_code >= 400:
        print(f"FAILED {resp.status_code} PUT {url}", file=sys.stderr)
        resp.raise_for_status()
    print(f"OK {resp.status_code} {path}")
    return resp.json() if resp.text else {}


def build_index(name: str, embedding_deployment: str = "", foundry_endpoint: str = "") -> dict:
    """Load the canonical Function-compatible schema; legacy vector arguments are ignored."""
    schema_path = Path(__file__).resolve().parents[1] / "src" / "shared" / "search-index.json"
    definition = json.loads(schema_path.read_text(encoding="utf-8"))
    definition["name"] = name
    return definition


def validate_openai_endpoint(endpoint: str) -> str:
    parsed = urlsplit(endpoint)
    if (parsed.scheme != "https" or not parsed.hostname
            or not parsed.hostname.endswith(".openai.azure.com")
            or parsed.username or parsed.password or parsed.port
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("Planner resourceUri must be https://<account>.openai.azure.com")
    return endpoint.rstrip("/")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--search-endpoint", required=True)
    p.add_argument("--foundry-endpoint", required=True)
    p.add_argument("--chat-deployment", required=True)
    p.add_argument("--chat-model", required=True)
    p.add_argument("--embedding-deployment", help=argparse.SUPPRESS)
    p.add_argument("--index", default="spo-docs")
    p.add_argument("--knowledge-source", default="spo-knowledge-source")
    p.add_argument("--knowledge-base", default="spo-knowledge-base")
    args = p.parse_args()

    try:
        args.foundry_endpoint = validate_openai_endpoint(args.foundry_endpoint)
    except ValueError as error:
        p.error(str(error))
    from azure.identity import DefaultAzureCredential

    credential = DefaultAzureCredential()
    endpoint = args.search_endpoint.rstrip("/")

    put(
        endpoint,
        f"indexes/{args.index}",
        DATA_API_VERSION,
        build_index(args.index),
        credential,
    )

    # Wraps the index the ingestion Function writes into.
    put(
        endpoint,
        f"knowledgeSources/{args.knowledge_source}",
        AGENTIC_API_VERSION,
        {
            "name": args.knowledge_source,
            "kind": "searchIndex",
            "description": "SharePoint documents processed by Content Understanding.",
            "searchIndexParameters": {"searchIndexName": args.index},
        },
        credential,
    )

    put(
        endpoint,
        f"knowledgeBases/{args.knowledge_base}",
        AGENTIC_API_VERSION,
        {
            "name": args.knowledge_base,
            "description": "Foundry IQ knowledge base over ingested SharePoint content.",
            # 'alwaysQuery' is NOT accepted on this API version and causes a bare 400.
            "knowledgeSources": [{"name": args.knowledge_source}],
            "models": [
                {
                    "kind": "azureOpenAI",
                    "azureOpenAIParameters": {
                        "resourceUri": args.foundry_endpoint,
                        "deploymentId": args.chat_deployment,
                        "modelName": args.chat_model,
                    },
                }
            ],
        },
        credential,
    )

    print("\nKnowledge base ready.")
    print("Retrieval also requires, on the Foundry account:")
    print("  - 'Cognitive Services OpenAI User' for the SEARCH service managed identity")
    print("  - an approved shared private link (groupId 'openai_account') from Search")
    print(json.dumps({"index": args.index, "knowledgeBase": args.knowledge_base}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
