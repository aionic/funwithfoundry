# Native Retrieval Runtime And Sample Client

Run the sample only from a runner with private access to the Foundry project. The runtime
remains `python main.py`, hosted by `ResponsesHostServer` with Responses protocol `2.0.0`.

## Runtime Configuration

| Variable | Contract |
| --- | --- |
| `FOUNDRY_PROJECT_ENDPOINT` | Required Foundry project HTTPS endpoint. |
| `SEARCH_ENDPOINT` | Required HTTPS Search service endpoint for IQ. |
| `TOOLBOX_NAME` | Required deployed toolbox name/version identifier accepted by the SDK. Must resolve to exactly the approved read-only `azure_ai_search` tool, not a general MCP/action toolbox. |
| `SEARCH_TOOL_NAME` | Exact approved Search function name. If omitted, derive the service label from `https://<service>.search.windows.net`. Set explicitly for other clouds or connection/tool names that differ from the service name. |
| `FOUNDRY_IQ_KNOWLEDGE_BASE` | IQ knowledge base name; default `spo-knowledge-base`. |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | Project synthesis model deployment; default `gpt-4o`. |
| `RETRIEVAL_TIMEOUT_SECONDS` | Per-tool and synthesis deadline, greater than 0 and at most 900 seconds; default 120. |

The Search function must expose exactly one string parameter named `query`, `search`, or
`question`, with no other required parameters. The application supplies only the full current
question. Startup rejects missing, duplicate, or additional toolbox tools. The operator must
publish the expected tool as read-only Azure AI Search: a name allowlist does not authenticate
the implementation behind a name. Keep the toolbox version fixed for the deployment.

Each text request runs IQ, validates its actual output, runs Search, validates its actual
output, then either synthesizes or returns `FAILED:`. Failure of either retrieval prevents
synthesis. Prior-turn results cannot satisfy a current call. IQ requires nonempty answer text
and source references. Tool traces retain real call IDs, names, arguments and outputs.

Retrieved text and source metadata are untrusted data. Synthesis receives no callable tools,
and retrieved instructions cannot choose tools or skip the result gates. Prompt instructions,
JSON serialization, and result validation do not guarantee immunity to prompt injection or
prove answer correctness. Do not use generated answers as authorization for downstream actions.

## Local Tests And Client

Use the existing project virtual environment; never install globally:

```powershell
uv pip install --python .\.venv\Scripts\python.exe -r .\src\foundry_native_agent\requirements.txt
& .\.venv\Scripts\python.exe -m unittest discover -s tests -p test_retrieval.py -v
uv pip install --python .\.venv\Scripts\python.exe -r .\src\hello_world\requirements.txt
& .\.venv\Scripts\python.exe .\src\hello_world\ask_agent.py --project-endpoint $env:FOUNDRY_PROJECT_ENDPOINT --search-tool-name $env:SEARCH_TOOL_NAME --question "Your full question"
```

The client requires an explicit `--search-tool-name`, defaults to model `gpt-4o`, and accepts
`--timeout` in seconds (default 900, maximum 900). It requires a completed response, IQ then the
exact Search call with the full question, unique matching nonempty successful outputs, and a
non-failure final answer. HTTP/auth/timeout/JSON/trace failures return nonzero; clients and
credentials close on both success and failure. Error output does not print response bodies.

Pure helper/client tests run without SDKs. Graph tests skip explicitly if LangGraph is missing;
a skip is not runtime or hosting validation. All tests use mocks and make no Azure calls.

## Deployment Follow-Up

Redeploy the permitted runtime source and dependencies using the existing hosting configuration.
No hosting/protocol change is required. Add `SEARCH_TOOL_NAME` to the service environment when
the fallback service name is not the toolbox function name; optionally expose the timeout.
The current service environment already supplies the other required variables. These deployment
files were intentionally not edited in this slice.

The root `.agentignore` excludes `.foundry`, evaluation configuration/data, fixtures, tests,
datasets, benchmarks, results, and coverage artifacts. Inspect the actual deployment archive
before publishing; do not ship benchmark material into the runtime image. Runtime dependencies
use pinned integration packages plus bounded framework ranges, not a fully resolved lockfile.
Resolve and test the full set before deployment when package downloads are available.
