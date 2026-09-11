"""Launch the canonical native indexer/KS/KB initializer from a private runner.

This is deliberately not an independent REST writer. PowerShell owns the builders,
the two shared JSON contracts, IMDS authentication and every read-back gate.
Tradeoff: Windows needs PowerShell 5.1 or 7; Linux/macOS need PowerShell 7 installed.
There is no SDK, Azure CLI credential or alternative REST writer. This launcher uses
the runner's managed identity, not the caller's interactive Azure login.

Use --help for the required output-derived endpoints, resource IDs and deployments.
Legacy --foundry-endpoint/--chat-deployment/--chat-model aliases still mean the
primary KB planner. Ingestion model arguments always refer to the secondary account.
Successful stdout is one JSON object with the PowerShell result keys and full hashes.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import cast

INITIALIZER = Path(__file__).with_name("Initialize-KnowledgeBase.ps1").resolve()
PARAMETERS = {
    "search_endpoint": "SearchEndpoint",
    "foundry_openai_endpoint": "FoundryOpenAIEndpoint",
    "planner_deployment": "PlannerDeployment",
    "planner_model": "PlannerModel",
    "storage_resource_id": "StorageResourceId",
    "ingestion_identity_resource_id": "IngestionIdentityResourceId",
    "ingestion_foundry_endpoint": "IngestionFoundryEndpoint",
    "ingestion_openai_endpoint": "IngestionOpenAIEndpoint",
    "ingestion_chat_deployment": "IngestionChatDeployment",
    "ingestion_chat_model": "IngestionChatModel",
    "embedding_deployment": "EmbeddingDeployment",
    "embedding_model": "EmbeddingModel",
    "staging_container": "StagingContainer",
    "folder_path": "FolderPath",
}


def validate_openai_endpoint(endpoint: str) -> str:
    if not re.fullmatch(r"https://[a-zA-Z0-9-]+\.openai\.azure\.com/?", endpoint):
        raise ValueError("resourceUri must be https://<account>.openai.azure.com")
    return endpoint.rstrip("/")


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    aliases = {
        "foundry_openai_endpoint": "--foundry-endpoint",
        "planner_deployment": "--chat-deployment",
        "planner_model": "--chat-model",
    }
    for name in PARAMETERS:
        if name in ("staging_container", "folder_path"):
            continue
        flags = ["--" + name.replace("_", "-")]
        if name in aliases:
            flags.append(aliases[name])
        parser.add_argument(*flags, dest=name, required=True)
    parser.add_argument("--staging-container", default="spo-staging")
    parser.add_argument("--folder-path", default="native/")
    return parser


def build_command(options: argparse.Namespace, executable: str) -> list[str]:
    command = [executable, "-NoProfile", "-NonInteractive", "-File", str(INITIALIZER), "-AsJson"]
    for name, parameter in PARAMETERS.items():
        value = getattr(options, name)
        if not isinstance(value, str) or not value or value.startswith("-") or any(character in value for character in "\r\n\0"):
            raise ValueError("Invalid initializer argument; expected a nonempty literal value.")
        if name in ("foundry_openai_endpoint", "ingestion_openai_endpoint"):
            value = validate_openai_endpoint(value)
        command.extend(["-" + parameter, value])
    return command


def main(argv: list[str] | None = None) -> int:
    options = argument_parser().parse_args(argv)
    executable = shutil.which("pwsh")
    if executable is None and os.name == "nt":
        executable = shutil.which("powershell.exe")
    if executable is None:
        print("Native initialization requires PowerShell 7, or Windows PowerShell 5.1. No fallback writer is available.", file=sys.stderr)
        return 1
    try:
        command = build_command(options, executable)
        completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=1800)
        if completed.returncode:
            print("Native initialization blocked or failed. Run Initialize-KnowledgeBase.ps1 with the same inputs for the sanitized contract and HTTP-status diagnostic. Existing definitions are never overwritten.", file=sys.stderr)
            return 1
        decoded: object = json.loads(completed.stdout)
        if not isinstance(decoded, dict):
            raise ValueError("Unexpected initializer result.")
        result = cast(dict[str, object], decoded)
        if result.get("status") != "succeeded" or result.get("indexing_verified") is not False:
            raise ValueError("Unexpected initializer result.")
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError):
        print("Native initialization failed validation or execution; process output is suppressed. No automatic retry or fallback was attempted.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
