"""Cloud-free contracts for both knowledge initializers and the Function document shape."""

import ast
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("knowledge_init", ROOT / "scripts" / "New-FoundryIqKnowledgeBase.py")
assert SPEC is not None and SPEC.loader is not None
INITIALIZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INITIALIZER)


class KnowledgeSchemaTests(unittest.TestCase):
    def test_canonical_text_semantic_schema(self) -> None:
        schema = INITIALIZER.build_index("spo-docs", "ignored-embedding", "ignored-endpoint")
        expected = json.loads((ROOT / "src/shared/search-index.json").read_text(encoding="utf-8"))
        self.assertEqual(schema, expected)
        self.assertNotIn("vectorSearch", schema)
        self.assertEqual({field["name"] for field in schema["fields"]},
                         {"id", "title", "content", "source_url", "source_id", "content_hash"})
        self.assertEqual(schema["semantic"]["defaultConfiguration"], "default-semantic")

    def test_schema_matches_actual_function_document(self) -> None:
        tree = ast.parse((ROOT / "src/ingest_func/function_app.py").read_text(encoding="utf-8"))
        documents = [node.args[0] for node in ast.walk(tree)
                     if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                     and node.func.id == "_push_to_search" and node.args and isinstance(node.args[0], ast.Dict)]
        self.assertEqual(len(documents), 1)
        keys = {key.value for key in documents[0].keys if isinstance(key, ast.Constant)}
        self.assertEqual(keys, {field["name"] for field in INITIALIZER.build_index("spo-docs")["fields"]})

    def test_schema_calls_do_not_mutate_shared_state(self) -> None:
        INITIALIZER.build_index("alternate")["fields"].clear()
        self.assertEqual(len(INITIALIZER.build_index("spo-docs")["fields"]), 6)

    def test_planner_requires_openai_hostname(self) -> None:
        self.assertEqual(INITIALIZER.validate_openai_endpoint("https://account.openai.azure.com/"),
                         "https://account.openai.azure.com")
        for endpoint in ("https://account.cognitiveservices.azure.com", "https://account.services.ai.azure.com",
                         "http://account.openai.azure.com", "https://account.openai.azure.com.evil.test",
                         "https://user@account.openai.azure.com", "https://account.openai.azure.com/path"):
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                INITIALIZER.validate_openai_endpoint(endpoint)


if __name__ == "__main__":
    unittest.main()
