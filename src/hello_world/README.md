# Native Retrieval Runtime And Sample Client

Run the sample only from a runner with private access to the Foundry project. The runtime
remains `python main.py`, hosted by `ResponsesHostServer` with Responses protocol `2.0.0`.

**2026-09-11 baseline:** the explicit S1 native-indexer pipeline passed the full
local release gate, fixture-backed live acceptance and two normal Verify runs.
Agent 3/toolbox 2 remain active with the unchanged runtime principal; the Verify
runs did not redeploy the agent. Actual SharePoint integration is deferred because
no sample is available, not considered validated or consented. Historical
Function/v1 results do not validate current bindings; do not assume this
client/runtime is compatible with the old index/toolbox. Read the
[migration and ownership guide](../../docs/native-ingestion.md) before deployment.

## Runtime Configuration

| Variable | Contract |
| --- | --- |
| `FOUNDRY_PROJECT_ENDPOINT` | Required Foundry project HTTPS endpoint. |
| `SEARCH_ENDPOINT` | Required HTTPS Search service endpoint for IQ. |
| `TOOLBOX_NAME` | Required deployed toolbox name/version identifier accepted by the SDK. Must resolve to exactly the approved read-only `azure_ai_search` tool, not a general MCP/action toolbox. |
| `SEARCH_TOOL_NAME` | Exact approved Search function name. If omitted, derive the service label from `https://<service>.search.windows.net`. Set explicitly for other clouds or connection/tool names that differ from the service name. |
| `FOUNDRY_IQ_KNOWLEDGE_BASE` | IQ knowledge base name; local default `spo-native-knowledge-base`, referencing `spo-native`. |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | Project synthesis model deployment; default `gpt-4o`. |
| `RETRIEVAL_TIMEOUT_SECONDS` | Per-tool and synthesis deadline, greater than 0 and at most 900 seconds; default 120. |

The Search function must expose exactly one string parameter named `query`, `search`, or
`question`, with no other required parameters. The application supplies only the full current
question. Startup rejects missing, duplicate, or additional toolbox tools. The operator must
publish the expected tool as read-only Azure AI Search: a name allowlist does not authenticate
the implementation behind a name. Keep the toolbox version fixed for the deployment.

The local toolbox requests `vector_semantic_hybrid` over the explicit
`spo-native-index`. The `spo-native` KS is kind `searchIndex`, not an auto-generated
Blob KS. Native Azure Search executes the explicit CU skill with semantic 500-token/
zero-overlap chunks, `gpt-5.2`, images/location metadata, 3072-dimensional embeddings
and child projections. Live fixture indexing and hybrid retrieval passed; the
3072-dimensional schema was verified, not a direct vector-array readback. All
connections/endpoints must come from this environment's outputs; never bind to IDs
copied from a different sample.

Each text request runs IQ, validates its actual output, runs Search, validates its actual
output, then either synthesizes or returns `FAILED:`. Failure of either retrieval prevents
synthesis. Prior-turn results cannot satisfy a current call. IQ requires nonempty answer text
and source references. Tool traces retain real call IDs, names, arguments and outputs.

Native Search can return a text block ending in a Blob URL and matching
UrlToken-encoded parent. The runtime normalizes that source metadata into JSON
content before the Responses host flattens the block. Framework `lc_` message IDs
are not citations; strict source and call/output validation remains required.

The Function only stages raw bytes and returns `202 staged`. An answer test requires
separate native indexing proof: blob HEAD/provenance, fresh native indexer success
and child chunks associated with the staged blob. Generated child `doc_url` is the
staged blob URL from `metadata_storage_path`, not the original SharePoint URL.
Original source identity/hash/URL are blob metadata; child references alone do not prove
a digest or carry end-user SharePoint ACLs. Use a uniformly authorized test corpus.

Manual Blob staging can test the native indexer without a Function call. Neither
that test nor fixture success validates SharePoint connector access or permissions.
Actual SharePoint cross-region ingestion remains a separate required proof for that goal.

Retrieved text and source metadata are untrusted data. Synthesis receives no callable tools,
and retrieved instructions cannot choose tools or skip the result gates. Prompt instructions,
JSON serialization, and result validation do not guarantee immunity to prompt injection or
prove answer correctness. Do not use generated answers as authorization for downstream actions.

## Local Tests And Client

For cloud-free tests, follow [the testing guide](../../docs/TESTING.md) to prepare
isolated locked environments and set the explicit interpreter paths:

```powershell
& $env:FWF_PYTHON .github/scripts/run-python-checks.py retrieval --release
```

For a live question, use a caller with private DNS/routes and an authorized identity.
See [the staged jumpbox example](../../docs/deployment.md#complete-demo) for values
from the actual deployment manifest. In a separate approved private checkout, create
a dedicated client environment using uv and
[the client lock](requirements.lock), then populate the current project endpoint
and exact toolbox function name before invoking:

```powershell
uv venv --python 3.13.7 .\.venv-client
$ClientPython = (Resolve-Path .\.venv-client\Scripts\python.exe).Path
uv pip sync --python $ClientPython --require-hashes -r .\src\hello_world\requirements.lock
& $ClientPython .\src\hello_world\ask_agent.py --project-endpoint $env:FOUNDRY_PROJECT_ENDPOINT --search-tool-name $env:SEARCH_TOOL_NAME --question 'Your full question'
```

Run commands from the repository root; keep environments outside the deployed source
directories. The network must permit the reviewed package/interpreter sources or use
approved offline artifacts. Never install globally, copy a login cache or open the
project publicly to run the client. Local test setup does not grant private access.

The client requires an explicit `--search-tool-name`, defaults to model `gpt-4o`, and accepts
`--timeout` in seconds (default 900, maximum 900). It requires a completed response, IQ then the
exact Search call with the full question, unique matching nonempty successful outputs, and a
non-failure final answer. HTTP/auth/timeout/JSON/trace failures return nonzero; clients and
credentials close on both success and failure. Error output does not print response bodies.

Pure helper/client tests run without SDKs. Graph tests skip explicitly if LangGraph is missing;
a skip is not runtime or hosting validation. All tests use mocks and make no Azure calls.

## Deployment Follow-Up

After separate deployment approval, deploy compatible
native definitions, toolbox and runtime bindings together. Contract version 2,
owner `accelerator-native-indexer`, uses `spo-native-datasource`, `spo-native-index`,
`spo-native-skillset`, `spo-native-indexer`, `spo-native` and
`spo-native-knowledge-base`. The required
order is Function publish, fixture staging, Knowledge setup, then native binding
and verification. The initializer refuses existing-definition mismatches, including
an old `azureBlob` KS, and performs no automatic migration or deletion. The
datasource-only reviewed rebind and guarded stale-ETag refresh exceptions follow
the [receipt contract](../../docs/native-ingestion.md#datasource-receipt-and-resume).
Creating the enabled indexer starts indexing, but successful configuration read-back
does not verify it. S1 eligibility depends on service creation date and, for
embeddings, a high-capacity region; see the migration guide. The generated private
Blob KS S2 path is not used. Private links, identity and security boundaries are unchanged.

No hosting/protocol change is claimed here. Add `SEARCH_TOOL_NAME` to the service environment when
the fallback service name is not the toolbox function name; optionally expose the timeout.
The current service environment already supplies the other required variables. Use the
[staged deployment guidance](../../docs/deployment.md), with its integration caveat and plan/version checks,
for reviewed changes; a source edit does not update the running agent.

The hosted source's `.agentignore` excludes `.foundry`, evaluation configuration/data, fixtures, tests,
datasets, benchmarks, results, and coverage artifacts. Inspect the actual deployment archive
before publishing; do not ship benchmark material into the runtime image. Direct requirements
are resolver inputs; the [native lock](../foundry_native_agent/requirements.lock) and
client lock pin the full resolved dependency sets and hashes. Preserve both during
review and run the affected tests before any approved redeployment.
