"""Query from a private-network runner; accept only completed, dual-retrieval responses."""

import argparse
from collections.abc import Sequence
import json
import re
from typing import Any, cast
from urllib.parse import quote, urlparse

AZURE_AI_SCOPE = "https://ai.azure.com/.default"
IQ_TOOL_NAME = "retrieve_foundry_iq"


def validate_output(value: Any) -> None:
    """Validate tool payloads without trusting call presence or top-level HTTP status."""
    def decode(item: Any) -> Any:
        if isinstance(item, str):
            try:
                return json.loads(item)
            except json.JSONDecodeError:
                return item
        return item

    def check_errors(item: Any) -> None:
        item = decode(item)
        if isinstance(item, dict):
            item = cast(dict[str, Any], item)
            if (item.get("error") or item.get("errors") or item.get("isError")
                    or item.get("status") in ("error", "failed", "incomplete", "cancelled")
                    or item.get("success") is False or item.get("ok") is False):
                raise ValueError("A required tool reported failure.")
            for child in item.values():
                check_errors(child)
        elif isinstance(item, list):
            for child in cast(list[Any], item):
                check_errors(child)
        elif isinstance(item, str) and re.match(
            r"(?is)^\s*(error\s*:|exception\s*:|failed\s*:|no (results|documents|matches)\b)", item
        ):
            raise ValueError("A required tool reported failure.")

    def has_content(item: Any) -> bool:
        item = decode(item)
        if isinstance(item, str):
            return bool(item.strip())
        if isinstance(item, list):
            return any(has_content(child) for child in cast(list[Any], item))
        if isinstance(item, dict):
            item = cast(dict[str, Any], item)
            return any(has_content(item[key]) for key in (
                "answer", "content", "text", "snippet", "value", "results", "documents", "response",
                "output", "structuredContent", "data",
            ) if key in item)
        return False

    def has_source(item: Any, reference: bool = False) -> bool:
        item = decode(item)
        if isinstance(item, list):
            return any(has_source(child, reference) for child in cast(list[Any], item))
        if not isinstance(item, dict):
            return False
        item = cast(dict[str, Any], item)
        identity_keys = ("document_id", "docKey", "source_id", "url", "source_url", "web_url", "webUrl",
                         "snippet_id", "snippet_parent_id", "doc_url")
        if not reference and not isinstance(item.get("sourceData"), dict):
            identity_keys += ("id",)
        return (any(isinstance(item.get(key), str) and item[key].strip() for key in identity_keys)
                or any(has_source(child, key == "references") for key, child in item.items()))

    check_errors(value)
    if not has_content(value) or not has_source(value):
        raise ValueError("A required tool returned no usable content with source references.")


def validate_response(response: Any, question: str, search_tool_name: str) -> tuple[list[str], str]:
    if not isinstance(response, dict):
        raise ValueError("The agent returned an invalid response.")
    response = cast(dict[str, Any], response)
    if (response.get("status") != "completed"
            or response.get("error") or response.get("incomplete_details")):
        raise ValueError("The agent response did not complete successfully.")
    expected = [IQ_TOOL_NAME, search_tool_name]
    if search_tool_name == IQ_TOOL_NAME or not search_tool_name:
        raise ValueError("An explicit, distinct Search tool name is required.")
    output = response.get("output")
    if not isinstance(output, list):
        raise ValueError("The agent returned no output trace.")
    calls: dict[str, str] = {}
    names: list[str] = []
    successful: set[str] = set()
    answers: list[str] = []
    for item in cast(list[Any], output):
        if not isinstance(item, dict):
            raise ValueError("Malformed output trace.")
        item = cast(dict[str, Any], item)
        kind = item.get("type")
        if not isinstance(kind, str):
            raise ValueError("Malformed output item type.")
        if kind in {"function_call", "function_call_output"} and item.get("status") not in (None, "completed"):
            raise ValueError("A tool trace item did not complete.")
        if kind == "function_call":
            name = item.get("name")
            call_id = item.get("call_id")
            if (len(names) >= 2 or not isinstance(name, str) or name != expected[len(names)] or not isinstance(call_id, str)
                    or not call_id or call_id in calls or len(successful) != len(names)):
                raise ValueError("Expected exactly IQ then the configured Search tool, with matched outputs.")
            arguments = item.get("arguments")
            if not isinstance(arguments, str):
                raise ValueError("Tool arguments must be a JSON object.")
            arguments = json.loads(arguments)
            allowed = {"question"} if name == IQ_TOOL_NAME else {"query", "search", "question"}
            if not isinstance(arguments, dict):
                raise ValueError("Tool arguments must be a JSON object.")
            arguments = cast(dict[str, Any], arguments)
            if (len(arguments) != 1
                    or not set(arguments) <= allowed or list(arguments.values()) != [question]):
                raise ValueError("A tool did not receive the full current question.")
            calls[call_id] = name
            names.append(name)
        elif kind == "function_call_output":
            call_id = item.get("call_id")
            if not isinstance(call_id, str) or call_id not in calls or call_id in successful:
                raise ValueError("A tool output has no unique matching call.")
            if item.get("name") not in (None, calls[call_id]) or item.get("isError") or item.get("error"):
                raise ValueError("A tool output is mismatched or failed.")
            validate_output(item.get("output"))
            successful.add(call_id)
        elif kind == "message":
            if (len(successful) != 2 or item.get("status") not in (None, "completed")
                    or item.get("role") != "assistant"):
                raise ValueError("An answer arrived without both successful retrieval results.")
            content = item.get("content", [])
            if not isinstance(content, list):
                raise ValueError("Malformed answer content.")
            for part in cast(list[Any], content):
                if isinstance(part, dict):
                    part = cast(dict[str, Any], part)
                    if part.get("type") == "output_text" and isinstance(part.get("text"), str):
                        answers.append(part["text"])
        elif kind != "reasoning":
            raise ValueError("Unexpected output type in the retrieval-only response.")
    answer = "\n".join(answers)
    if names != expected or successful != set(calls) or not answer.strip() or answer.lstrip().startswith("FAILED:"):
        raise ValueError("Expected both successful tool outputs and a non-failure answer.")
    return names, answer


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-endpoint", required=True)
    parser.add_argument("--agent-name", default="funwithfoundry-rag-agent")
    parser.add_argument("--model", default="gpt-4o")
    parser.add_argument("--search-tool-name", required=True)
    parser.add_argument("--question", required=True)
    parser.add_argument("--timeout", type=float, default=900)
    args = parser.parse_args(argv)
    project_endpoint: str = args.project_endpoint
    endpoint = urlparse(project_endpoint)
    if (endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.password
            or endpoint.query or endpoint.fragment or not args.question.strip()
            or not 0 < args.timeout <= 900 or args.search_tool_name == IQ_TOOL_NAME
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.search_tool_name)):
        parser.error("Require an HTTPS project endpoint, text question, distinct Search tool name, and 0 < timeout <= 900.")
    try:
        import httpx
        from azure.core.exceptions import AzureError
        from azure.identity import DefaultAzureCredential
    except ImportError:
        print("FAILED: install src/hello_world/requirements.txt into an isolated environment with uv.")
        return 2
    try:
        with DefaultAzureCredential() as credential, httpx.Client(timeout=args.timeout) as client:
            token = credential.get_token(AZURE_AI_SCOPE).token
            url = (f"{args.project_endpoint.rstrip('/')}/agents/{quote(args.agent_name, safe='')}"
                   "/endpoint/protocols/openai/responses?api-version=v1")
            result = client.post(
                url, headers={"Authorization": f"Bearer {token}"},
                json={"input": args.question, "model": args.model, "stream": False},
            )
            result.raise_for_status()
            names, answer = validate_response(result.json(), args.question, args.search_tool_name)
    except (httpx.HTTPError, AzureError, ValueError) as error:
        print(f"FAILED: request or response validation failed ({type(error).__name__}).")
        return 1

    print("\n=== Tool trace ===")
    for name in names:
        print(f"  - {name}: matched nonempty successful output")
    print("\n=== Answer ===")
    print(answer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
