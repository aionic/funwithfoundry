"""Query the New Foundry native hosted agent and print its tool trace and answer.

Run from the jumpbox - the Foundry project endpoint is private.

Usage:
    python ask_agent.py --project-endpoint https://<name>.services.ai.azure.com/api/projects/<project> \
        --question "What does the document say about X?"
"""

import argparse

import requests
from azure.identity import DefaultAzureCredential

AZURE_AI_SCOPE = "https://ai.azure.com/.default"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--project-endpoint", required=True)
    p.add_argument("--agent-name", default="funwithfoundry-rag-agent")
    p.add_argument("--model", default="gpt-4o")
    p.add_argument("--question", required=True)
    args = p.parse_args()

    credential = DefaultAzureCredential()
    token = credential.get_token(AZURE_AI_SCOPE).token
    endpoint = args.project_endpoint.rstrip("/")
    url = f"{endpoint}/agents/{args.agent_name}/endpoint/protocols/openai/responses?api-version=v1"

    resp = requests.post(
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"input": args.question, "model": args.model},
        timeout=900,
    )
    if resp.status_code >= 400:
        print(f"FAILED {resp.status_code}")
        print(resp.text)
        return 1

    response = resp.json()
    tool_names: list[str] = []

    print("\n=== Tool trace ===")
    for item in response.get("output", []):
        if item.get("type") == "function_call":
            tool_names.append(item["name"])
            print(f"  - {item['name']}: {item.get('arguments', '{}')}")

    print("\n=== Answer ===")
    for item in response.get("output", []):
        if item.get("type") == "message":
            for part in item.get("content", []):
                if part.get("text"):
                    print(part["text"])

    if "retrieve_foundry_iq" not in tool_names or len(set(tool_names)) < 2:
        print("FAILED: expected both Foundry IQ and toolbox Search tool calls")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
