"""New Foundry hosted agent grounded by Foundry IQ and a Search toolbox."""

import asyncio
import json
import os
from typing import Any

import httpx
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from langchain.agents import create_agent
from langchain_core.tools import BaseTool, tool
from langchain_openai import ChatOpenAI
from langchain_azure_ai.agents.hosting import ResponsesHostServer
from langchain_azure_ai.tools import AzureAIProjectToolbox

SEARCH_SCOPE = "https://search.azure.com/.default"
AZURE_AI_SCOPE = "https://ai.azure.com/.default"
AGENTIC_API_VERSION = "2026-05-01-preview"

credential = DefaultAzureCredential()
project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
model_deployment = os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"]
search_endpoint = os.environ["SEARCH_ENDPOINT"].rstrip("/")
knowledge_base = os.getenv("FOUNDRY_IQ_KNOWLEDGE_BASE", "spo-knowledge-base")
toolbox_name = os.environ["TOOLBOX_NAME"]

project_client = AIProjectClient(
    endpoint=project_endpoint,
    credential=credential,
)
openai_client = project_client.get_openai_client()


@tool
def retrieve_foundry_iq(question: str) -> str:
    """Retrieve grounded content and citations from the Foundry IQ knowledge base."""
    token = credential.get_token(SEARCH_SCOPE).token
    url = (
        f"{search_endpoint}/knowledgeBases/{knowledge_base}/retrieve"
        f"?api-version={AGENTIC_API_VERSION}"
    )
    payload = {
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": question}]}
        ]
    }
    with httpx.Client(timeout=120) as client:
        response = client.post(
            url,
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )
        response.raise_for_status()
        result: dict[str, Any] = response.json()

    answer_parts = [
        part.get("text", "")
        for message in result.get("response", [])
        for part in message.get("content", [])
        if part.get("text")
    ]
    citations = []
    for reference in result.get("references", []):
        source = reference.get("sourceData") or {}
        citations.append(source.get("title") or reference.get("docKey") or "unknown")

    return json.dumps(
        {
            "answer": "\n".join(answer_parts),
            "citations": citations,
        },
        ensure_ascii=True,
    )


def build_chat_model() -> ChatOpenAI:
    """Create the project-scoped Responses model client."""
    token_provider = get_bearer_token_provider(credential, AZURE_AI_SCOPE)
    return ChatOpenAI(
        model=model_deployment,
        base_url=str(openai_client.base_url),
        api_key=token_provider,
        use_responses_api=True,
        output_version="responses/v1",
    )


def sanitize_tool_schema(tool_instance: BaseTool) -> None:
    """Normalize toolbox schemas that omit object properties."""
    schema = tool_instance.args_schema if isinstance(tool_instance.args_schema, dict) else None
    if schema is not None and schema.get("type") == "object":
        schema.setdefault("properties", {})


async def create_graph():
    """Load the project toolbox and create the hosted agent graph."""
    toolbox = AzureAIProjectToolbox(toolbox_name=toolbox_name)
    toolbox_tools = await toolbox.get_tools()
    if not toolbox_tools:
        raise RuntimeError(f"Foundry Toolbox '{toolbox_name}' returned no tools.")
    for toolbox_tool in toolbox_tools:
        sanitize_tool_schema(toolbox_tool)

    return create_agent(
        build_chat_model(),
        tools=[retrieve_foundry_iq, *toolbox_tools],
        system_prompt=(
            "You are the funwithfoundry validation agent. Before every answer, you MUST "
            "call retrieve_foundry_iq once with the user's full question AND call the "
            "fwf1wj5gsearch Foundry Toolbox tool once with the user's full question. "
            "Do not answer until both tool results are available. If either tool fails, "
            "report that failure instead of silently relying on the other result. Answer "
            "only from tool results, preserve exact codes and technical values, reconcile "
            "the two results, and end with a Sources section."
        ),
    )


def main() -> None:
    """Load managed tools and serve the graph over the Responses protocol."""
    graph = asyncio.run(create_graph())
    ResponsesHostServer(graph).run()


if __name__ == "__main__":
    main()