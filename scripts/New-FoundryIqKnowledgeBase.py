"""Create the search index, knowledge source, and Foundry IQ knowledge base.

Knowledge bases are not modelled by azurerm, so this runs post-deploy. It must be
executed from inside the VNet (the jumpbox), because the search service has public
network access disabled.

Usage:
    python New-FoundryIqKnowledgeBase.py --search-endpoint https://<name>.search.windows.net \
        --foundry-endpoint https://<account>.services.ai.azure.com \
        --chat-deployment gpt-5.2 --embedding-deployment text-embedding-3-large
"""

import argparse
import json
import sys

import requests
from azure.identity import DefaultAzureCredential

SEARCH_SCOPE = "https://search.azure.com/.default"

# Knowledge bases and knowledge sources are only available on the preview surface.
DATA_API_VERSION = "2024-07-01"
AGENTIC_API_VERSION = "2026-05-01-preview"


def token(credential) -> str:
    return credential.get_token(SEARCH_SCOPE).token


def put(endpoint: str, path: str, api_version: str, body: dict, credential) -> dict:
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
        print(resp.text, file=sys.stderr)
        resp.raise_for_status()
    print(f"OK {resp.status_code} {path}")
    return resp.json() if resp.text else {}


def build_index(name: str, embedding_deployment: str, foundry_endpoint: str) -> dict:
    return {
        "name": name,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
            {"name": "title", "type": "Edm.String", "searchable": True},
            {
                "name": "content",
                "type": "Edm.String",
                "searchable": True,
                "analyzer": "standard.lucene",
            },
            {
                "name": "contentVector",
                "type": "Collection(Edm.Single)",
                "searchable": True,
                "dimensions": 3072,
                "vectorSearchProfile": "default-profile",
            },
        ],
        "vectorSearch": {
            "algorithms": [{"name": "default-algo", "kind": "hnsw"}],
            "profiles": [
                {
                    "name": "default-profile",
                    "algorithm": "default-algo",
                    "vectorizer": "default-vectorizer",
                }
            ],
            "vectorizers": [
                {
                    "name": "default-vectorizer",
                    "kind": "azureOpenAI",
                    "azureOpenAIParameters": {
                        "resourceUri": foundry_endpoint,
                        "deploymentId": embedding_deployment,
                        "modelName": "text-embedding-3-large",
                    },
                }
            ],
        },
        # Agentic retrieval requires the semantic ranker.
        "semantic": {
            "defaultConfiguration": "default-semantic",
            "configurations": [
                {
                    "name": "default-semantic",
                    "prioritizedFields": {
                        "titleField": {"fieldName": "title"},
                        "prioritizedContentFields": [{"fieldName": "content"}],
                    },
                }
            ],
        },
    }


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--search-endpoint", required=True)
    p.add_argument("--foundry-endpoint", required=True)
    p.add_argument("--chat-deployment", default="gpt-5.2")
    p.add_argument("--embedding-deployment", default="text-embedding-3-large")
    p.add_argument("--index", default="spo-docs")
    p.add_argument("--knowledge-source", default="spo-knowledge-source")
    p.add_argument("--knowledge-base", default="spo-knowledge-base")
    args = p.parse_args()

    credential = DefaultAzureCredential()
    endpoint = args.search_endpoint.rstrip("/")

    put(
        endpoint,
        f"indexes/{args.index}",
        DATA_API_VERSION,
        build_index(args.index, args.embedding_deployment, args.foundry_endpoint),
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
                        "modelName": args.chat_deployment,
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
