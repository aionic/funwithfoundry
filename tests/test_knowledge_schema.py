"""Cloud-free native contract and launcher tests. Fixtures are not provider evidence."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
from io import StringIO
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("knowledge_init", ROOT / "scripts" / "New-FoundryIqKnowledgeBase.py")
assert SPEC is not None and SPEC.loader is not None
INITIALIZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INITIALIZER)


class KnowledgeSchemaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = json.loads((ROOT / "src/shared/search-index.json").read_text(encoding="utf-8"))
        self.contract = json.loads((ROOT / "src/shared/native-ingestion.json").read_text(encoding="utf-8"))

    def test_explicit_native_index(self) -> None:
        for contract in (self.schema, self.contract):
            self.assertEqual(contract["contractVersion"], 2)
            self.assertEqual(contract["owner"], "accelerator-native-indexer")
        self.assertEqual(self.schema["name"], "spo-native-index")
        fields = {field["name"]: field for field in self.schema["fields"]}
        self.assertEqual(set(fields), {"snippet_id", "snippet", "snippet_vector", "snippet_parent_id", "doc_url"})
        self.assertEqual(fields["snippet_vector"]["dimensions"], 3072)
        self.assertFalse(fields["snippet_vector"]["retrievable"])
        self.assertTrue(fields["snippet_parent_id"]["filterable"])
        self.assertTrue(fields["snippet_parent_id"]["retrievable"])
        self.assertTrue(fields["doc_url"]["filterable"])
        self.assertTrue(fields["snippet_id"]["key"])
        self.assertEqual(fields["snippet_id"]["analyzer"], "keyword")
        self.assertTrue(fields["snippet_id"]["searchable"])

    def test_vector_and_semantic_templates(self) -> None:
        vector_search = self.schema["vectorSearch"]
        profile = vector_search["profiles"][0]
        algorithm = vector_search["algorithms"][0]
        vectorizer = vector_search["vectorizers"][0]
        self.assertEqual(profile["algorithm"], algorithm["name"])
        self.assertEqual(profile["vectorizer"], vectorizer["name"])
        self.assertEqual(algorithm["kind"], "hnsw")
        self.assertEqual(algorithm["hnswParameters"]["metric"], "cosine")
        self.assertEqual(vectorizer["kind"], "azureOpenAI")
        self.assertEqual(vectorizer["azureOpenAIParameters"], {"modelName": "text-embedding-3-large"})
        semantic = self.schema["semantic"]
        configuration = semantic["configurations"][0]
        self.assertEqual(semantic["defaultConfiguration"], configuration["name"])
        self.assertEqual(configuration["prioritizedFields"]["prioritizedContentFields"], [{"fieldName": "snippet"}])

    def test_document_projection_is_child_only_not_legacy_metadata(self) -> None:
        projection = self.schema["projection"]
        self.assertEqual(projection["projectionMode"], "skipIndexingParentDocuments")
        self.assertEqual(projection["parentKeyFieldName"], "snippet_parent_id")
        self.assertEqual(projection["sourceContext"], "/document/text_sections/*")
        self.assertEqual(projection["mappings"], [
            {"name": "snippet", "source": "/document/text_sections/*/content"},
            {"name": "snippet_vector", "source": "/document/text_sections/*/text_vector"},
            {"name": "doc_url", "source": "/document/metadata_storage_path"},
        ])
        self.assertIn("not the original SharePoint URL", self.schema["documentSemantics"]["doc_url"])

    def test_direct_private_pipeline_has_no_generated_source_options(self) -> None:
        self.assertEqual(self.contract["apiVersion"], "2026-08-01-preview")
        self.assertEqual(self.contract["knowledgeSourceName"], "spo-native")
        self.assertEqual(self.contract["knowledgeBaseName"], "spo-native-knowledge-base")
        self.assertEqual(self.contract["pipeline"], {
            "datasource": "spo-native-datasource", "indexer": "spo-native-indexer",
            "skillset": "spo-native-skillset", "index": "spo-native-index",
        })
        self.assertNotIn("networkAccessMode", json.dumps(self.contract))
        self.assertNotIn("ingestionParameters", self.contract)
        self.assertEqual(self.contract["indexerParameters"], {
            "maxFailedItems": 0,
            "configuration": {"executionEnvironment": "private", "allowSkillsetToReadFileData": True,
                              "parsingMode": "default", "dataToExtract": "storageMetadata"},
        })
        self.assertEqual(self.contract["schedule"], {"interval": "PT5M"})

    def test_native_skill_templates(self) -> None:
        content = self.contract["expectedContentUnderstanding"]
        self.assertEqual(content["modelName"], "gpt-5.2")
        self.assertEqual(content["@odata.type"], "#Microsoft.Skills.Util.ContentUnderstandingSkill")
        self.assertEqual(content["chunkingProperties"], {
            "method": "semantic", "unit": "tokens", "maximumLength": 500, "overlapLength": 0,
        })
        self.assertEqual(content["extractionOptions"], ["images", "locationMetadata"])
        self.assertEqual(content["inputs"], [{"name": "file_data", "source": "/document/file_data"}])
        embedding = self.contract["expectedEmbedding"]
        self.assertEqual(embedding["modelName"], "text-embedding-3-large")
        self.assertEqual(embedding["dimensions"], 3072)
        self.assertEqual(embedding["context"], "/document/text_sections/*")
        self.assertEqual(embedding["inputs"], [{"name": "text", "source": "/document/text_sections/*/content"}])
        self.assertEqual(embedding["outputs"], [{"name": "embedding", "targetName": "text_vector"}])

    def test_planner_requires_exact_openai_hostname(self) -> None:
        self.assertEqual(INITIALIZER.validate_openai_endpoint("https://account.openai.azure.com/"), "https://account.openai.azure.com")
        for endpoint in ("https://account.cognitiveservices.azure.com", "https://account.services.ai.azure.com",
                         "http://account.openai.azure.com", "https://account.openai.azure.com.evil.test",
                         "https://user@account.openai.azure.com", "https://account.openai.azure.com/path",
                         "https://account.openai.azure.com:443", "https://account.openai.azure.com?key=secret"):
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                INITIALIZER.validate_openai_endpoint(endpoint)


class LauncherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.values = {
            "search_endpoint": "https://search.search.windows.net",
            "foundry_openai_endpoint": "https://primary.openai.azure.com",
            "planner_deployment": "planner", "planner_model": "gpt-5.2",
            "storage_resource_id": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/staging",
            "ingestion_identity_resource_id": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ingestion",
            "ingestion_foundry_endpoint": "https://secondary.services.ai.azure.com",
            "ingestion_openai_endpoint": "https://secondary.openai.azure.com",
            "ingestion_chat_deployment": "gpt52-ingest", "ingestion_chat_model": "gpt-5.2",
            "embedding_deployment": "embed", "embedding_model": "text-embedding-3-large",
        }
        self.arguments = [part for name, value in self.values.items() for part in ("--" + name.replace("_", "-"), value)]

    def test_exact_powershell_handoff(self) -> None:
        options = INITIALIZER.argument_parser().parse_args(self.arguments)
        command = INITIALIZER.build_command(options, "pwsh")
        self.assertEqual(command[:6], ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(INITIALIZER.INITIALIZER), "-AsJson"])
        for name, value in self.values.items():
            self.assertEqual(command[command.index("-" + INITIALIZER.PARAMETERS[name]) + 1], value)
        self.assertEqual(command[command.index("-StagingContainer") + 1], "spo-staging")
        self.assertEqual(command[command.index("-FolderPath") + 1], "native/")
        self.assertFalse(hasattr(INITIALIZER, "put"))
        self.assertFalse(hasattr(INITIALIZER, "build_index"))

    def test_legacy_aliases_only_select_primary_planner(self) -> None:
        aliases = {"--foundry-openai-endpoint": "--foundry-endpoint", "--planner-deployment": "--chat-deployment", "--planner-model": "--chat-model"}
        options = INITIALIZER.argument_parser().parse_args([aliases.get(item, item) for item in self.arguments])
        self.assertEqual(options.foundry_openai_endpoint, self.values["foundry_openai_endpoint"])
        self.assertEqual(options.ingestion_chat_deployment, "gpt52-ingest")

    def test_no_shell_or_argument_injection(self) -> None:
        options = INITIALIZER.argument_parser().parse_args(self.arguments)
        for value in ("-Command", "foo\nbar", "\0", ""):
            options.planner_deployment = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                INITIALIZER.build_command(options, "pwsh")

    def test_success_preserves_complete_output(self) -> None:
        result: dict[str, object] = {
            "status": "succeeded", "indexing_verified": False, "schema_sha256": "a" * 64,
            "contract_sha256": "b" * 64, "indexer": "spo-native-indexer", "datasource": "spo-native-datasource",
            "index": "spo-native-index", "skillset": "spo-native-skillset", "knowledge_source": "spo-native",
            "knowledge_base": "spo-native-knowledge-base", "contract_version": 2, "owner": "accelerator-native-indexer",
        }
        stdout = StringIO()
        with patch.object(INITIALIZER.shutil, "which", return_value="pwsh"), \
                patch.object(INITIALIZER.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(result), "")) as run, \
                redirect_stdout(stdout):
            self.assertEqual(INITIALIZER.main(self.arguments), 0)
        self.assertEqual(json.loads(stdout.getvalue()), result)
        self.assertNotIn("shell", run.call_args.kwargs)
        self.assertTrue(run.call_args.kwargs["capture_output"])

    def test_failures_suppress_process_bodies(self) -> None:
        for response in (subprocess.CompletedProcess([], 1, "SECRET", "SECRET"),
                         subprocess.CompletedProcess([], 0, "SECRET", "SECRET"),
                         subprocess.CompletedProcess([], 0, '{"status":"succeeded"}', "SECRET")):
            output = StringIO()
            with self.subTest(response=response), patch.object(INITIALIZER.shutil, "which", return_value="pwsh"), \
                    patch.object(INITIALIZER.subprocess, "run", return_value=response), redirect_stdout(output), redirect_stderr(output):
                self.assertEqual(INITIALIZER.main(self.arguments), 1)
            self.assertNotIn("SECRET", output.getvalue())

    def test_no_implicit_install_or_fallback(self) -> None:
        with patch.object(INITIALIZER.shutil, "which", return_value=None), \
                patch.object(INITIALIZER.subprocess, "run") as run, redirect_stderr(StringIO()):
            self.assertEqual(INITIALIZER.main(self.arguments), 1)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
