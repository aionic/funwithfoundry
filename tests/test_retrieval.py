"""Cloud-free retrieval regression tests: unittest discover -s tests -p test_retrieval.py."""

import asyncio
import base64
import importlib
import importlib.util
import json
import os
import sys
import unittest
from copy import deepcopy
from types import SimpleNamespace
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch


NATIVE_URL = (
    "https://fwfaw5p5stage.blob.core.windows.net/spo-staging/native/"
    "49c28093cd800efbac9eb23a4725cec146063ad0ae45ef41a7fd24ee2fb3baa8/source.pdf"
)
NATIVE_PARENT = (
    "aHR0cHM6Ly9md2ZhdzVwNXN0YWdlLmJsb2IuY29yZS53aW5kb3dzLm5ldC9zcG8tc3RhZ2luZy9uYXRpdmUv"
    "NDljMjgwOTNjZDgwMGVmYmFjOWViMjNhNDcyNWNlYzE0NjA2M2FkMGFlNDVlZjQxYTdmZDI0ZWUyZmIzYmFhOC9zb3VyY2UucGRm0"
)
NATIVE_TEXT = (
    "Fun with Foundry - synthetic accelerator fixture v1\n"
    "Project Cedar is a fictional internal knowledge assistant.\n"
    "The fictional launch date is 15 October 2026.\n"
    "The fictional project owner is Morgan Example.\n\n"
    "The retention period for Project Cedar documents is 30 days.\n"
    + NATIVE_URL + "\n" + NATIVE_PARENT + "\n"
)


class RetrievalHelpersTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = importlib.import_module("src.foundry_native_agent.main")

    def test_search_name_comes_from_configuration(self) -> None:
        self.assertEqual(
            self.runtime.resolve_search_tool_name({"SEARCH_TOOL_NAME": "approved_search"}),
            "approved_search",
        )
        self.assertEqual(
            self.runtime.resolve_search_tool_name({"SEARCH_ENDPOINT": "https://demo.search.windows.net/"}),
            "demo",
        )
        with self.assertRaises(ValueError):
            self.runtime.resolve_search_tool_name({})

    def test_import_requires_no_environment_or_cloud_dependencies(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            importlib.reload(self.runtime)

    def test_nontext_and_missing_current_requests_are_rejected(self) -> None:
        for messages in ([], [{"role": "user", "content": " "}], [{"role": "assistant", "content": "old"}],
                         [{"role": "user", "content": [{"type": "text", "text": "question"},
                                                       {"type": "image_url", "image_url": "https://example.test/image"}]}]):
            with self.subTest(messages=messages), self.assertRaises(ValueError):
                self.runtime.current_question(messages)

    def test_search_source_mapping_keeps_ids_titles_and_urls(self) -> None:
        document = {"id": "search-doc", "title": "Error handling guide", "source_url": "https://example.test/doc",
                    "content": "Error handling uses retries."}
        wrapped = [{"type": "text", "text": json.dumps({"value": [document]})}]
        self.runtime.validate_tool_result(wrapped)
        sources = self.runtime.collect_sources(wrapped)
        self.assertIn({"id": "search-doc", "title": "Error handling guide", "source_url": "https://example.test/doc"}, sources)

    def test_toolbox_requires_exactly_the_expected_tool(self) -> None:
        self.runtime.validate_tool_names(["approved_search"], "approved_search")
        for names in ([], ["other"], ["approved_search", "write"], ["approved_search"] * 2):
            with self.subTest(names=names), self.assertRaises(ValueError):
                self.runtime.validate_tool_names(names, "approved_search")

    def test_transport_and_text_block_ids_are_not_sources(self) -> None:
        for payload in (
            [{"type": "text", "id": "lc_8fbd0c0e-7e00-4a1a-827c-956930cb8c67", "text": "Evidence"}],
            [{"type": "text", "id": "block-1", "text": "Evidence"}],
            {"content": "Evidence", "id": "lc_transport"},
            {"content": "Evidence", "source_id": "lc_transport"},
            {"content": "Evidence", "references": [{"id": "lc_transport", "docKey": "lc_transport"}]},
        ):
            with self.subTest(payload=payload):
                self.assertEqual(self.runtime.collect_sources(payload), [])
                with self.assertRaises(ValueError):
                    self.runtime.validate_tool_result(payload)
        document = {"id": "real-source", "snippet": "Evidence"}
        wrapped = [{"type": "text", "id": "lc_transport", "text": json.dumps({"value": [document]})}]
        self.assertEqual(self.runtime.collect_sources(wrapped), [{"id": "real-source"}])
        self.runtime.validate_tool_result(wrapped)

    def test_generated_chunk_result_preserves_source_and_document_ids(self) -> None:
        document = {"snippet": "ABC-42", "snippet_id": "chunk-1", "snippet_parent_id": "parent-1",
                    "doc_url": "https://example.test/doc"}
        wrapped = [{"type": "text", "text": json.dumps({"value": [document]})}]
        self.runtime.validate_tool_result(wrapped)
        self.assertEqual(self.runtime.collect_sources(wrapped), [{
            "snippet_id": "chunk-1", "snippet_parent_id": "parent-1", "doc_url": "https://example.test/doc",
            "source_id": "chunk-1", "document_id": "parent-1", "url": "https://example.test/doc",
        }])

    def test_generated_iq_reference_preserves_chunk_parent_and_reference_ids(self) -> None:
        result = self.runtime.normalize_iq_result({
            "response": [{"content": [{"type": "text", "text": "ABC-42 [ref-1]"}]}],
            "references": [{"id": "ref-1", "docKey": "chunk-1", "sourceData": {
                "snippet": "ABC-42", "snippet_id": "chunk-1", "snippet_parent_id": "parent-1",
                "doc_url": "https://example.test/doc", "source_id": "legacy-id",
                "document_id": "legacy-parent", "url": "https://example.test/legacy",
            }}],
        })
        source = result["sources"][0]
        self.assertEqual(source["reference_id"], "ref-1")
        self.assertEqual(source["docKey"], "chunk-1")
        self.assertEqual(source["source_id"], "chunk-1")
        self.assertEqual(source["document_id"], "parent-1")
        self.assertEqual(source["url"], "https://example.test/doc")

    def test_native_and_legacy_metadata_aliases_remain_usable(self) -> None:
        for metadata in (
            {"snippet_id": "chunk-1", "snippet_parent_id": "parent-1", "doc_url": "https://example.test/doc"},
            {"source_id": "chunk-1", "document_id": "parent-1", "url": "https://example.test/doc"},
            {"id": "legacy-doc", "title": "Runbook", "source_url": "https://example.test/doc"},
            {"docKey": "legacy-doc", "webUrl": "https://example.test/doc"},
        ):
            with self.subTest(metadata=metadata):
                payload = {"value": [{"snippet": "ABC-42", **metadata}]}
                self.runtime.validate_tool_result(payload)
                self.assertTrue(self.runtime.collect_sources(payload))

    def test_iq_chunk_reference_without_source_data_preserves_reference_context(self) -> None:
        result = self.runtime.normalize_iq_result({
            "response": [{"content": [{"type": "text", "text": "ABC-42 [ref-1]"}]}],
            "references": [{"id": "ref-1", "docKey": "chunk-1", "snippet_id": "chunk-1",
                            "snippet_parent_id": "parent-1", "doc_url": "https://example.test/doc"}],
        })
        source = result["sources"][0]
        self.assertNotIn("id", source)
        self.assertEqual(source["reference_id"], "ref-1")
        self.assertEqual(source["source_id"], "chunk-1")
        self.assertEqual(source["document_id"], "parent-1")
        self.assertEqual(source["url"], "https://example.test/doc")

    def test_content_without_usable_source_metadata_fails_in_both_validators(self) -> None:
        client = importlib.import_module("src.hello_world.ask_agent")
        for metadata in ({}, {"title": "Runbook"}, {"reference_id": "ref-1"},
                         {"snippet_id": " ", "snippet_parent_id": None, "doc_url": ""},
                         {"snippet_id": [], "snippet_parent_id": {}, "doc_url": 42}):
            for wrapper in ("value", "structuredContent", "results"):
                payload = [{"type": "text", "text": json.dumps({wrapper: [{"snippet": "ABC-42", **metadata}]})}]
                with self.subTest(metadata=metadata, wrapper=wrapper):
                    with self.assertRaises(ValueError):
                        self.runtime.validate_tool_result(payload)
                    with self.assertRaises(ValueError):
                        client.validate_output(payload)

    def test_iq_missing_empty_and_malformed_references_fail(self) -> None:
        for references in (None, [], {}, [{"id": "ref-only"}], [{"id": "ref-only", "sourceData": {"snippet": "ABC-42"}}]):
            with self.subTest(references=references), self.assertRaises(ValueError):
                self.runtime.normalize_iq_result({
                    "response": [{"content": [{"type": "text", "text": "ABC-42"}]}], "references": references,
                })

    def test_current_question_preserves_every_text_part(self) -> None:
        messages: list[dict[str, Any]] = [
            {"role": "user", "content": "Old question"},
            {"role": "assistant", "content": "Old answer"},
            {"role": "user", "content": [
                {"type": "text", "text": "Full question?"},
                {"type": "input_text", "text": "Include exact code ABC-42."},
            ]},
        ]
        self.assertEqual(self.runtime.current_question(messages), "Full question?\nInclude exact code ABC-42.")

    def test_errors_and_empty_results_fail_closed(self) -> None:
        for result in (None, "", "  ", "{}", "[]", '{"value": []}',
                       '{"error": "denied"}', '{"isError": true, "content": "denied"}',
                       json.dumps([{"type": "text", "text": json.dumps({"isError": True})}])):
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.runtime.validate_tool_result(result)

    def test_iq_source_mapping_preserves_provenance(self) -> None:
        result = self.runtime.normalize_iq_result({
            "response": [{"content": [{"type": "text", "text": "ABC-42"}]}],
            "references": [{"id": "ref-1", "docKey": "doc-9", "sourceData": {
                "id": "source-8", "title": "Runbook", "url": "https://example.com/runbook",
            }}],
        })
        self.assertEqual(result["answer"], "ABC-42")
        self.assertEqual(result["sources"][0]["reference_id"], "ref-1")
        self.assertEqual(result["sources"][0]["document_id"], "doc-9")
        self.assertEqual(result["sources"][0]["id"], "source-8")
        self.assertEqual(result["sources"][0]["title"], "Runbook")
        self.assertEqual(result["sources"][0]["url"], "https://example.com/runbook")
        self.runtime.validate_tool_result(json.dumps(result))

    def test_exchange_requires_current_matching_successful_output(self) -> None:
        messages: list[dict[str, Any]] = [
            {"type": "ai", "tool_calls": [{"id": "current", "name": "approved_search", "args": {"query": "Full question?"}}]},
            {"type": "tool", "tool_call_id": "current", "name": "approved_search", "status": "success",
             "content": '{"value":[{"id":"doc-1","content":"Evidence"}]}', "artifact": {"structured_content": None}},
        ]
        self.runtime.validate_tool_exchange(messages, "current", "approved_search", "Full question?")
        for change in ("missing", "stale", "wrong_name", "failed", "error_artifact", "short_question", "duplicate"):
            modified = deepcopy(messages)
            if change == "missing":
                modified.pop()
            elif change == "stale":
                modified[1]["tool_call_id"] = "previous"
            elif change == "wrong_name":
                modified[1]["name"] = "other_tool"
            elif change == "failed":
                modified[1]["status"] = "error"
            elif change == "error_artifact":
                modified[1]["artifact"] = {"isError": True}
            elif change == "short_question":
                modified[0]["tool_calls"][0]["args"]["query"] = "Full"
            else:
                modified.append(deepcopy(modified[1]))
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.runtime.validate_tool_exchange(modified, "current", "approved_search", "Full question?")

    def test_search_schema_is_read_only_query_shape(self) -> None:
        schema: dict[str, Any] = {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}
        self.assertEqual(self.runtime.search_arguments(SimpleNamespace(args_schema=schema), "Full question?"),
                         {"query": "Full question?"})
        schema["required"].append("command")
        with self.assertRaises(ValueError):
            self.runtime.search_arguments(SimpleNamespace(args_schema=schema), "Full question?")


class ResponseValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = importlib.import_module("src.hello_world.ask_agent")
        self.response: dict[str, Any] = {"status": "completed", "output": [
            {"type": "function_call", "name": "retrieve_foundry_iq", "call_id": "iq-1",
             "arguments": json.dumps({"question": "Full question?"})},
            {"type": "function_call_output", "call_id": "iq-1",
             "output": json.dumps({"answer": "Evidence", "sources": [{"id": "doc-1"}]})},
            {"type": "function_call", "name": "approved_search", "call_id": "search-1",
             "arguments": json.dumps({"query": "Full question?"})},
            {"type": "function_call_output", "call_id": "search-1",
             "output": json.dumps([{"type": "text", "text": json.dumps({"value": [{
                 "snippet": "Evidence", "snippet_id": "chunk-1", "snippet_parent_id": "doc-1",
                 "doc_url": "https://example.test/doc",
             }]})}])},
            {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Grounded answer"}]},
        ]}

    def test_completed_response_has_two_matched_successful_outputs(self) -> None:
        names, answer = self.client.validate_response(self.response, "Full question?", "approved_search")
        self.assertEqual(names, ["retrieve_foundry_iq", "approved_search"])
        self.assertEqual(answer, "Grounded answer")

    def test_invalid_status_names_ids_arguments_and_outputs_fail(self) -> None:
        for change in ("incomplete", "missing", "wrong_tool", "wrong_id", "duplicate", "short_question",
                   "iq_error", "search_error", "empty", "fake_answer", "out_of_order", "bad_type", "wrong_role",
                   "iq_missing_refs", "search_missing_refs", "malformed_args", "extra_args", "wrong_query_type"):
            response = deepcopy(self.response)
            output = response["output"]
            if change == "incomplete":
                response["status"] = "in_progress"
            elif change == "missing":
                output.pop(3)
            elif change == "wrong_tool":
                output[2]["name"] = "unrelated_tool"
            elif change == "wrong_id":
                output[3]["call_id"] = "unmatched"
            elif change == "duplicate":
                output.insert(4, deepcopy(output[3]))
            elif change == "short_question":
                output[2]["arguments"] = json.dumps({"query": "Full"})
            elif change == "iq_error":
                output[1]["output"] = json.dumps({"error": "denied"})
            elif change == "search_error":
                output[3]["output"] = json.dumps({"isError": True, "content": "denied"})
            elif change == "empty":
                output[3]["output"] = json.dumps({"value": []})
            elif change == "fake_answer":
                output[4]["content"][0]["text"] = "FAILED: retrieval unavailable."
            elif change == "bad_type":
                output[4]["type"] = []
            elif change == "wrong_role":
                output[4]["role"] = "user"
            elif change == "iq_missing_refs":
                output[1]["output"] = json.dumps({"answer": "Evidence", "sources": []})
            elif change == "search_missing_refs":
                output[3]["output"] = json.dumps({"value": [{"snippet": "Evidence"}]})
            elif change == "malformed_args":
                output[2]["arguments"] = json.dumps(["Full question?"])
            elif change == "extra_args":
                output[2]["arguments"] = json.dumps({"query": "Full question?", "index": "other"})
            elif change == "wrong_query_type":
                output[2]["arguments"] = json.dumps({"query": ["Full question?"]})
            else:
                output[1], output[2] = output[2], output[1]
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.client.validate_response(response, "Full question?", "approved_search")


    def test_client_timeout_auth_and_bad_json_close_resources(self) -> None:
        class FakeHttpError(Exception):
            pass

        class FakeAzureError(Exception):
            pass

        for outcome in ("success", "timeout", "auth", "bad_json"):
            credential_manager = MagicMock()
            credential = credential_manager.__enter__.return_value
            credential.get_token.return_value.token = "test-only-token"
            http_manager = MagicMock()
            http_client = http_manager.__enter__.return_value
            http_client.post.return_value.json.return_value = self.response
            if outcome == "timeout":
                http_client.post.side_effect = FakeHttpError()
            elif outcome == "auth":
                credential.get_token.side_effect = FakeAzureError()
            elif outcome == "bad_json":
                http_client.post.return_value.json.side_effect = ValueError()
            http_module = SimpleNamespace(Client=MagicMock(return_value=http_manager), HTTPError=FakeHttpError)
            identity_module = SimpleNamespace(DefaultAzureCredential=MagicMock(return_value=credential_manager))
            modules = {"httpx": http_module, "azure": SimpleNamespace(), "azure.core": SimpleNamespace(),
                       "azure.core.exceptions": SimpleNamespace(AzureError=FakeAzureError), "azure.identity": identity_module}
            with self.subTest(outcome=outcome), patch.dict(sys.modules, modules), patch("builtins.print"):
                result = self.client.main([
                    "--project-endpoint", "https://example.test/api/projects/test",
                    "--search-tool-name", "approved_search", "--question", "Full question?", "--timeout", "5",
                ])
                self.assertEqual(result, 0 if outcome == "success" else 1)
                credential_manager.__exit__.assert_called_once()
                http_manager.__exit__.assert_called_once()
                http_module.Client.assert_called_once_with(timeout=5)


@unittest.skipUnless(importlib.util.find_spec("langgraph") and importlib.util.find_spec("langchain_core"),
                     "LangGraph dependencies unavailable; install runtime requirements with uv.")
class RetrievalGraphTests(unittest.IsolatedAsyncioTestCase):
    async def make_graph(self, iq_result: Any = None, search_result: Any = None,
                         search_artifact: Any = None) -> tuple[Any, Any, list[tuple[str, str]]]:
        from langchain_core.messages import AIMessage
        from langchain_core.tools import StructuredTool

        runtime = importlib.import_module("src.foundry_native_agent.main")
        invoked: list[tuple[str, str]] = []

        async def retrieve(question: str) -> Any:
            invoked.append(("retrieve_foundry_iq", question))
            if isinstance(iq_result, Exception):
                raise iq_result
            return iq_result if iq_result is not None else json.dumps({
                "answer": "ABC-42", "sources": [{"source_id": "chunk-1", "document_id": "doc-1",
                                                "doc_url": "https://example.test/doc"}],
            })

        async def search(query: str) -> Any:
            invoked.append(("approved_search", query))
            if isinstance(search_result, Exception):
                raise search_result
            content = search_result if search_result is not None else json.dumps({
                "value": [{"snippet_id": "chunk-1", "snippet_parent_id": "doc-1", "snippet": "ABC-42",
                           "doc_url": "https://example.test/doc"}],
            })
            return content, search_artifact

        model = SimpleNamespace(ainvoke=AsyncMock(return_value=AIMessage(content="ABC-42 [chunk-1]")))
        graph = await runtime.create_graph(
            config={"SEARCH_TOOL_NAME": "approved_search"}, model=model,
            iq_tool=StructuredTool.from_function(coroutine=retrieve, name="retrieve_foundry_iq", description="Mock IQ"),
            toolbox_tools=[StructuredTool.from_function(coroutine=search, name="approved_search", description="Mock Search",
                                                        response_format="content_and_artifact")],
        )
        return graph, model, invoked

    async def emitted_response(self, graph: Any, *, streaming: bool) -> dict[str, Any]:
        from azure.ai.agentserver.responses import ResponseEventStream
        from langchain_azure_ai.agents.hosting._converters._final import state_to_events
        from langchain_azure_ai.agents.hosting._converters._stream import stream_graph_to_events
        from langchain_core.messages import HumanMessage

        stream = ResponseEventStream(response_id="resp-test", model="test")
        stream.emit_created()
        stream.emit_in_progress()
        state = {"messages": [HumanMessage(content="Current question?")]}
        if streaming:
            events = stream_graph_to_events(
                graph.astream(state, stream_mode=["updates", "messages", "checkpoints"]), stream,
                cancellation_signal=asyncio.Event(),
            )
        else:
            events = state_to_events(await graph.ainvoke(state), stream)
        async for _ in events:
            pass
        return stream.emit_completed()["response"]

    async def test_native_toolbox_text_survives_final_and_streaming_responses(self) -> None:
        from langchain_mcp_adapters.tools import _convert_call_tool_result
        from mcp.types import CallToolResult, TextContent

        runtime = importlib.import_module("src.foundry_native_agent.main")
        client = importlib.import_module("src.hello_world.ask_agent")
        blocks, artifact = _convert_call_tool_result(CallToolResult(content=[TextContent(type="text", text=NATIVE_TEXT)]))
        for content in (NATIVE_TEXT, blocks):
            for streaming in (False, True):
                with self.subTest(blocks=isinstance(content, list), streaming=streaming):
                    graph, model, invoked = await self.make_graph(search_result=content, search_artifact=artifact)
                    response = await self.emitted_response(graph, streaming=streaming)
                    names, answer = client.validate_response(response, "Current question?", "approved_search")
                    self.assertEqual(names, ["retrieve_foundry_iq", "approved_search"])
                    self.assertEqual(invoked, [(name, "Current question?") for name in names])
                    model.ainvoke.assert_awaited_once()
                    output = json.loads(response["output"][3]["output"])
                    self.assertEqual(output["content"], content)
                    self.assertEqual(output["sources"], [{
                        "doc_url": NATIVE_URL, "snippet_parent_id": NATIVE_PARENT,
                        "url": NATIVE_URL, "document_id": NATIVE_PARENT,
                    }])
                    self.assertEqual(runtime.collect_sources(output), output["sources"])
                    self.assertIn(NATIVE_PARENT, answer)
                    self.assertNotIn("lc_", json.dumps(output["sources"]))

    async def test_structured_artifact_metadata_is_preferred_and_emitted(self) -> None:
        from langchain_mcp_adapters.tools import _convert_call_tool_result
        from mcp.types import CallToolResult, TextContent

        client = importlib.import_module("src.hello_world.ask_agent")
        structured = {"value": [{"snippet": "Evidence", "snippet_id": "actual-chunk",
                                  "snippet_parent_id": "actual-parent", "doc_url": "https://example.test/actual"}]}
        content, artifact = _convert_call_tool_result(CallToolResult(
            content=[TextContent(type="text", text=NATIVE_TEXT)], structuredContent=structured,
        ))
        for streaming in (False, True):
            with self.subTest(streaming=streaming):
                graph, model, _ = await self.make_graph(search_result=content, search_artifact=artifact)
                response = await self.emitted_response(graph, streaming=streaming)
                client.validate_response(response, "Current question?", "approved_search")
                output = json.loads(response["output"][3]["output"])
                self.assertEqual(output["content"], content)
                self.assertEqual(output["structuredContent"], structured)
                self.assertEqual(output["sources"][0]["source_id"], "actual-chunk")
                self.assertEqual(output["sources"][0]["document_id"], "actual-parent")
                self.assertNotIn(NATIVE_PARENT, json.dumps(output["sources"]))
                model.ainvoke.assert_awaited_once()

    async def test_existing_structured_content_keeps_all_returned_metadata(self) -> None:
        runtime = importlib.import_module("src.foundry_native_agent.main")
        client = importlib.import_module("src.hello_world.ask_agent")
        for document in (
            {"id": "legacy-id", "title": "Runbook", "source_url": "https://example.test/legacy", "content": "ABC-42"},
            {"snippet_id": "chunk-1", "snippet_parent_id": "parent-1", "doc_url": "https://example.test/native",
             "snippet": "ABC-42"},
        ):
            payload = json.dumps({"value": [document]})
            for content in (payload, [{"type": "text", "id": "lc_transport", "text": payload}]):
                for streaming in (False, True):
                    with self.subTest(document=document, blocks=isinstance(content, list), streaming=streaming):
                        graph, model, _ = await self.make_graph(search_result=content)
                        response = await self.emitted_response(graph, streaming=streaming)
                        client.validate_response(response, "Current question?", "approved_search")
                        output = json.loads(response["output"][3]["output"])
                        self.assertEqual(output["content"], content)
                        self.assertEqual(output["sources"], runtime.collect_sources(content))
                        model.ainvoke.assert_awaited_once()

    async def test_ungrounded_or_failed_toolbox_outputs_fail_in_emitted_responses(self) -> None:
        client = importlib.import_module("src.hello_world.ask_agent")
        failures: list[tuple[Any, Any]] = [
            ([{"type": "text", "id": "lc_transport", "text": "Evidence"}], None),
            ([{"type": "text", "id": "block-1", "text": "Evidence"}], None),
            ("Evidence links to " + NATIVE_URL, None),
            ("Evidence\n" + NATIVE_URL + "\n", None),
            (NATIVE_TEXT.replace(NATIVE_PARENT, "unrelated-parent"), None),
            (NATIVE_TEXT + "More prose after the footer", None),
            (NATIVE_TEXT + NATIVE_TEXT, None),
            (NATIVE_TEXT, {"structured_content": {}}),
            (NATIVE_TEXT, {"structured_content": []}),
            (NATIVE_TEXT, {"structured_content": {"sources": [{"snippet_id": [], "doc_url": 42}]}}),
            (NATIVE_TEXT, {"structured_content": {"value": [{"id": "lc_transport", "snippet": "Evidence"}]}}),
            (NATIVE_TEXT, {"structured_content": {"isError": True}}),
            (NATIVE_TEXT, {"isError": True}),
            ("Error: denied\n" + NATIVE_TEXT, None),
            (json.dumps({"value": [{"snippet": "Evidence", "id": "actual-source"}], "error": "denied"}), None),
        ]
        for url in (
            NATIVE_URL.replace("https://", "http://"),
            NATIVE_URL.replace("https://", "https://user:password@"),
            NATIVE_URL + "?sig=untrusted", NATIVE_URL + "#fragment", NATIVE_URL + "?", NATIVE_URL + "#",
            NATIVE_URL.replace(".net/", ".net:443/"), NATIVE_URL.replace(".net/", ".net.evil.test/"),
            NATIVE_URL.replace("/native/", "/other/"), NATIVE_URL.replace("/spo-staging/", "/other-container/"),
            NATIVE_URL.replace("49c28093", "short"), NATIVE_URL.replace("/source.pdf", "/document.pdf"),
            NATIVE_URL.replace("/source.pdf", "/../source.pdf"), NATIVE_URL.replace("/source.pdf", "/%73ource.pdf"),
            "https://example.test/document",
        ):
            encoded = base64.urlsafe_b64encode(url.encode()).decode("ascii")
            unpadded = encoded.rstrip("=")
            failures.append(("Evidence\n" + url + "\n" + unpadded + str(len(encoded) - len(unpadded)) + "\n", None))
        for content, artifact in failures:
            for streaming in (False, True):
                with self.subTest(content=content, artifact=artifact, streaming=streaming):
                    graph, model, invoked = await self.make_graph(search_result=content, search_artifact=artifact)
                    response = await self.emitted_response(graph, streaming=streaming)
                    self.assertEqual(len(invoked), 2)
                    model.ainvoke.assert_not_awaited()
                    with self.assertRaises(ValueError):
                        client.validate_response(response, "Current question?", "approved_search")
                    with self.assertRaises(ValueError):
                        client.validate_output(response["output"][3]["output"])

    async def test_each_turn_invokes_iq_then_search_with_full_question(self) -> None:
        from langchain_core.messages import HumanMessage, ToolMessage

        graph, model, invoked = await self.make_graph()
        first = await graph.ainvoke({"messages": [HumanMessage(content="First question?")]})
        question = "Second question?\nInclude exact code ABC-42."
        result = await graph.ainvoke({**first, "messages": first["messages"] + [HumanMessage(content=question)]})
        self.assertEqual(invoked, [("retrieve_foundry_iq", "First question?"), ("approved_search", "First question?"),
                                   ("retrieve_foundry_iq", question), ("approved_search", question)])
        current = result["messages"][len(first["messages"]) + 1:]
        calls = [call for message in current for call in getattr(message, "tool_calls", [])]
        outputs = [message for message in current if isinstance(message, ToolMessage)]
        self.assertEqual([call["name"] for call in calls], ["retrieve_foundry_iq", "approved_search"])
        self.assertEqual([call["id"] for call in calls], [message.tool_call_id for message in outputs])
        self.assertTrue(all(message.status == "success" for message in outputs))
        self.assertEqual(model.ainvoke.await_count, 2)
        self.assertIn("nostream", model.ainvoke.await_args.args[1]["tags"])
        self.assertIn("https://example.test/doc", result["messages"][-1].content)
        sources = json.loads(result["messages"][-1].content.split("Sources (retrieved metadata):\n")[1])
        self.assertTrue(any(source.get("source_id") == "chunk-1" and source.get("document_id") == "doc-1"
                    and source.get("url") == "https://example.test/doc" for source in sources))

    async def test_either_tool_failure_or_empty_result_prevents_synthesis(self) -> None:
        from langchain_core.messages import HumanMessage

        for tool_name in ("iq", "search"):
            for failure in (RuntimeError("test"), '{"isError":true,"content":"denied"}', '{"value":[]}', "",
                            '{"value":[{"snippet":"ABC-42"}]}', '{"answer":"ABC-42","sources":[]}'):
                with self.subTest(tool=tool_name, failure=failure):
                    graph, model, invoked = await self.make_graph(**{tool_name + "_result": failure})
                    result = await graph.ainvoke({"messages": [HumanMessage(content="Current question?")]})
                    self.assertEqual(len(invoked), 2)
                    model.ainvoke.assert_not_awaited()
                    self.assertTrue(result["messages"][-1].content.startswith("FAILED:"))

    async def test_synthesis_tool_calls_are_rejected(self) -> None:
        from langchain_core.messages import AIMessage, HumanMessage

        graph, model, _ = await self.make_graph()
        model.ainvoke.return_value = AIMessage(content="ABC-42", tool_calls=[{
            "name": "unapproved_tool", "args": {}, "id": "unexpected-call",
        }])
        result = await graph.ainvoke({"messages": [HumanMessage(content="Current question?")]})
        self.assertTrue(result["messages"][-1].content.startswith("FAILED:"))

    async def test_synthesis_error_returns_failure(self) -> None:
        from langchain_core.messages import HumanMessage

        graph, model, _ = await self.make_graph()
        model.ainvoke.side_effect = RuntimeError("test")
        result = await graph.ainvoke({"messages": [HumanMessage(content="Current question?")]})
        self.assertTrue(result["messages"][-1].content.startswith("FAILED:"))

    async def test_message_stream_preserves_real_calls_and_outputs(self) -> None:
        from langchain_core.messages import HumanMessage, ToolMessage

        graph, _, invoked = await self.make_graph()
        streamed = [message async for message, _ in graph.astream(
            {"messages": [HumanMessage(content="Current question?")]}, stream_mode="messages",
        )]
        calls = [call for message in streamed for call in getattr(message, "tool_calls", [])]
        outputs = [message for message in streamed if isinstance(message, ToolMessage)]
        self.assertEqual([call["name"] for call in calls], ["retrieve_foundry_iq", "approved_search"])
        self.assertEqual([call["id"] for call in calls], [message.tool_call_id for message in outputs])
        self.assertEqual([name for name, _ in invoked], [call["name"] for call in calls])


if __name__ == "__main__":
    unittest.main()
