import base64
import contextlib
import csv
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import adf_compare as app


ROOT = Path(__file__).resolve().parents[1]
RESOURCE = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/group/providers/Microsoft.DataFactory/factories/factory1"
ARM = "https://management.azure.com" + RESOURCE
REPO = "https://github.com/example/pipelines"
API = "https://api.github.com/repos/example/pipelines"
SHA = "a" * 40
TREE = "b" * 40
UI = b'{"name":"p","properties":{"activities":[]}}'
EXPORT = (b'\xef\xbb\xbf{\r\n "id":"other","name":"p","type":"Microsoft.DataFactory/factories/pipelines",'
          b'"etag":"v","properties":{"activities":[],"lastPublishTime":"2030-01-01",'
          b'"policy":{"elapsedTimeMetric":{}}}}\r\n')


class FakeHttp:
    def __init__(self):
        self.calls = []
        self.pipeline_data = {"p": EXPORT, "second": UI.replace(b'"p"', b'"second"')}
        self.github_data = {"p.json": UI, "folder one/second.json": self.pipeline_data["second"]}
        self.export_failure = False
        self.truncated = False
        self.next_link = ""
        self.empty = False

    def json(self, url, headers):
        self.calls.append(url)
        if url.startswith(ARM):
            if headers["Authorization"] != "Bearer arm-token":
                raise AssertionError("Wrong ARM credential")
            return {"value": [] if self.empty else [{"name": name} for name in self.pipeline_data],
                    "nextLink": self.next_link}
        if headers["Authorization"] != "Bearer github-token":
            raise AssertionError("ARM token leaked to GitHub")
        if url == API:
            return {"default_branch": "feature/test"}
        if url in (API + "/commits/feature%2Ftest", API + "/commits/" + SHA):
            return {"sha": SHA, "commit": {"tree": {"sha": TREE}}}
        if url == API + f"/git/trees/{TREE}?recursive=1":
            return {"truncated": self.truncated, "tree": [
                {"path": path, "type": "blob", "mode": "100644"} for path in self.github_data
            ]}
        raise AssertionError(f"Unexpected JSON request: {url}")

    def get(self, url, headers):
        self.calls.append(url)
        if url.startswith(ARM + "/pipelines/"):
            if headers["Authorization"] != "Bearer arm-token":
                raise AssertionError("Wrong ARM credential")
            name = app.unquote(url.split("/pipelines/")[1].split("?")[0])
            if self.export_failure and name == "p":
                raise OSError("HTTP 403: export denied")
            return self.pipeline_data[name], "application/json"
        if headers["Authorization"] != "Bearer github-token":
            raise AssertionError("ARM token leaked to GitHub")
        path = app.unquote(url.split("/contents/")[1].split("?")[0])
        return self.github_data[path], "application/vnd.github.raw+json"


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.http = FakeHttp()
        self.environment = patch.dict(os.environ, {"GH_TOKEN": "github-token", "GITHUB_TOKEN": "other"})
        self.environment.start()
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stderr = contextlib.redirect_stderr(io.StringIO())
        self.stdout.__enter__()
        self.stderr.__enter__()

    def tearDown(self):
        self.stderr.__exit__(None, None, None)
        self.stdout.__exit__(None, None, None)
        self.environment.stop()
        self.temp.cleanup()

    def file(self, name, data):
        path = self.root / name
        path.write_bytes(data)
        return path

    def test_ui_api_normalization_and_file_evidence(self):
        first = self.file("p [1].json", EXPORT)
        second = self.file("copy.json", UI)
        result = app.compare(str(first), git_path=str(second), mode="PipelineDefinition")
        self.assertEqual(result["Result"], "MATCH")
        self.assertFalse(result["BytesIdentical"])
        self.assertTrue(result["DefinitionIdentical"])
        self.assertEqual(result["NormalizationVersion"], "PipelineDefinition-v2")
        self.assertEqual(result["AdfSHA256"], app.sha256(EXPORT))
        self.assertNotEqual(result["AdfSHA256"], result["GitSHA256"])
        self.assertEqual(first.read_bytes(), EXPORT)
        self.assertEqual(second.read_bytes(), UI)
        self.assertEqual(app.compare(str(first), git_path=str(second))["Result"], "DIFFERENT")

    def test_normalization_preserves_real_changes(self):
        pairs = [
            ('{"x":1}', '{"x":2}'),
            ('{"activities":[{"type":"Wait"}]}', '{"activities":[{"type":"Copy"}]}'),
            ('{"a":[1,2]}', '{"a":[2,1]}'),
            ('{"a":[]}', '{"a":[null]}'),
            ('{"a":null}', '{}'),
            ('{"sql":"select  1"}', '{"sql":"select 1"}'),
            ('{"a":"1"}', '{"a":1}'),
            ('{"a":{}}', '{"a":[]}'),
            ('{"A":1,"a":2}', '{"A":2,"a":1}'),
            ('{"nested":{"id":"a","lastPublishTime":"x"}}', '{"nested":{"id":"b","lastPublishTime":"x"}}'),
            ('{"policy":{"elapsedTimeMetric":{"duration":"x"}}}', '{}'),
            ('{"policy":{"future":1,"elapsedTimeMetric":{}}}', '{}'),
            ('{"policy":null}', '{}'),
            ('{"policy":{"elapsedTimeMetric":null}}', '{}'),
            ('{"activities":[{"policy":{"elapsedTimeMetric":{}}}]}', '{"activities":[{}]}'),
            ('{"x":9007199254740992}', '{"x":9007199254740993}'),
            ('{"x":0.1234567890123456789012345678901}', '{"x":0.1234567890123456789012345678902}'),
        ]
        for first, second in pairs:
            with self.subTest(first=first):
                make = lambda props: ('{"name":"p","properties":' + props + '}').encode()
                self.assertNotEqual(app.definition_hash(make(first)), app.definition_hash(make(second)))
        self.assertNotEqual(app.definition_hash(UI), app.definition_hash(UI.replace(b'"p"', b'"q"')))
        self.assertNotEqual(app.definition_hash(UI), app.definition_hash(UI[:-1] + b',"future":true}'))

    def test_equivalent_representations(self):
        pairs = [
            (b'{"name":"p","properties":{"a":1.00,"b":1e3,"c":-0}}',
             b'{"properties":{"c":0.0,"b":1000,"a":1},"name":"p"}'),
            (b'{"name":"p","properties":{"s":"\\u0061\\/\\n"}}',
             b'{"name":"p","properties":{"s":"a/\\u000a"}}'),
            (UI, b'{"name":"p","properties":{"activities":[],"policy":{}}}'),
            (b'{"name":"p","properties":{"policy":{"future":1}}}',
             b'{"name":"p","properties":{"policy":{"elapsedTimeMetric":{},"future":1}}}'),
        ]
        for first, second in pairs:
            with self.subTest(first=first):
                self.assertEqual(app.definition_hash(first), app.definition_hash(second))

    def test_invalid_definitions_fail_explicitly(self):
        for data in (
            b'{bad', b'{"name":"p","properties":[]}', b'{"properties":{}}',
            b'{"name":"p","properties":{},"type":"Other"}',
            b'{"name":"p","properties":{"a":1,"\\u0061":2}}',
            b'{"name":"p","properties":{"a":NaN}}',
            b'{"name":"p","properties":{"a":Infinity}}',
            b'{"name":"p","properties":{"a":01}}',
            b'{"name":"p","properties":{},}',
            b'{"name":"p","properties":{}} true',
            b'{"name":"p","properties":{"x":1e9223372036854775808}}',
        ):
            with self.subTest(data=data), self.assertRaises((ValueError, RecursionError)):
                app.definition_hash(data)
        invalid = self.file("invalid.json", b"{bad")
        good = self.file("good.json", UI)
        result = app.compare(str(good), git_path=str(invalid), mode="PipelineDefinition")
        self.assertEqual(result["Result"], "ERROR")
        self.assertEqual(result["GitSHA256"], app.sha256(b"{bad"))
        self.assertIsNone(result["Identical"])

    def test_repository_search_and_url_encoding(self):
        repository = app.Repository(REPO + ".git/", "", self.http)
        self.assertEqual(repository.file_url("second.json"), REPO + f"/blob/{SHA}/folder%20one/second.json")
        self.assertEqual(repository.commit, SHA)
        self.assertEqual(sum("/git/trees/" in call for call in self.http.calls), 1)
        with self.assertRaisesRegex(ValueError, "case-sensitive"):
            repository.file_url("SECOND.json")
        self.http.github_data["duplicate/p.json"] = UI
        with self.assertRaisesRegex(ValueError, "Multiple"):
            app.Repository(REPO, SHA, self.http).file_url("p.json")
        self.http.truncated = True
        with self.assertRaisesRegex(ValueError, "truncated"):
            app.Repository(REPO, SHA, self.http)

    def test_url_restrictions_and_redirects(self):
        for url in (
            "http://github.com/example/pipelines", "https://example.com/example/pipelines",
            "https://token@github.com/example/pipelines", REPO + "?token=secret", REPO + "#fragment",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                app.Repository(url, "", self.http)
        with self.assertRaises(ValueError):
            app.github_file(REPO, self.http)
        self.assertIsNone(app.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.com"))

    def test_http_errors_do_not_expose_headers_or_body(self):
        client = app.HttpClient()
        for error in (
            HTTPError("https://example.com", 403, "denied", {}, io.BytesIO(b"secret body")),
            URLError("unavailable"),
        ):
            with patch.object(client.opener, "open", side_effect=error):
                with self.assertRaises(OSError) as caught:
                    client.get("https://example.com", {"Authorization": "Bearer secret-token"})
                self.assertNotIn("secret", str(caught.exception))

    def test_batch_continues_and_protects_sources(self):
        path = self.file("p.json", EXPORT)
        manifest = self.root / "input.csv"
        report = self.root / "report.csv"
        app.write_csv(manifest, [
            {"AdfPath": "p.json"}, {"AdfPath": "missing.json"}, {"AdfPath": ""},
            {"AdfPath": str(path)},
        ], ["AdfPath"], ";")
        results = app.batch(str(manifest), str(report), repo_url=REPO, delimiter=";",
                            mode="PipelineDefinition", http=self.http)
        self.assertEqual([row["Result"] for row in results], ["MATCH", "ERROR", "ERROR", "MATCH"])
        self.assertEqual(app.exit_code(results), 2)
        self.assertEqual([row["Row"] for row in results], [2, 3, 4, 5])
        with report.open(encoding="utf-8-sig", newline="") as stream:
            saved = list(csv.DictReader(stream, delimiter=";"))
        self.assertEqual(saved[0]["DefinitionIdentical"], "True")
        self.assertEqual(saved[0]["BytesIdentical"], "False")
        for output in (path, manifest):
            with self.assertRaises(ValueError):
                app.batch(str(manifest), str(output), repo_url=REPO, delimiter=";", http=self.http)
        self.assertEqual(path.read_bytes(), EXPORT)

    def test_explicit_urls_and_csv_errors(self):
        path = self.file("source.json", EXPORT)
        manifest = self.root / "input.csv"
        report = self.root / "report.csv"
        app.write_csv(manifest, [{"AdfPath": str(path), "GitUrl": REPO + "/blob/feature%2Ftest/p.json"}],
                      ["AdfPath", "GitUrl"], ",")
        result = app.batch(str(manifest), str(report), mode="PipelineDefinition", http=self.http)
        self.assertEqual(app.exit_code(result), 0)
        for content in (b"", b"AdfPath\n", b"Other\nx\n", b"AdfPath;GitUrl\nx;y\n"):
            manifest.write_bytes(content)
            with self.subTest(content=content), self.assertRaises(ValueError):
                app.batch(str(manifest), str(report), repo_url=REPO, http=self.http)
        with self.assertRaises(ValueError):
            app.batch(str(manifest), str(report), git_ref="main", http=self.http)

    @patch("adf_compare.shutil.which", return_value="az")
    @patch("adf_compare.subprocess.run")
    def test_arm_token_renewal_and_errors(self, run, which):
        token = json.dumps({"accessToken": "arm-token", "expires_on": int(time.time()) + 3600}).encode()
        run.return_value = subprocess.CompletedProcess([], 0, token, b"")
        arm = app.ArmClient("subscription", self.http)
        self.assertEqual(arm.headers()["Authorization"], "Bearer arm-token")
        arm.headers()
        self.assertEqual(run.call_count, 1)
        arm.expiry = time.time() + 10
        arm.headers()
        self.assertEqual(run.call_count, 2)
        self.assertIn("subscription", run.call_args.args[0])
        run.return_value = subprocess.CompletedProcess([], 1, b"", b"sensitive error")
        arm.expiry = 0
        with self.assertRaisesRegex(ValueError, "authentication"):
            arm.headers()
        run.return_value = subprocess.CompletedProcess([], 0, b'{"accessToken":"x","expires_on":1}', b"")
        with self.assertRaisesRegex(ValueError, "expired"):
            arm.headers()
        which.return_value = None
        with self.assertRaises(OSError):
            arm.headers()

    def run_factory(self):
        with patch.object(app.ArmClient, "headers", return_value={"Authorization": "Bearer arm-token"}):
            return app.factory(RESOURCE, REPO, output_directory=str(self.root / "runs"),
                               mode="PipelineDefinition", http=self.http)

    def test_factory_end_to_end_and_preserved_bytes(self):
        results, run = self.run_factory()
        self.assertEqual(app.exit_code(results), 0)
        self.assertEqual((run / "exports" / "p.json").read_bytes(), EXPORT)
        self.assertTrue((run / "pipelines.csv").is_file())
        self.assertTrue((run / "export-status.csv").is_file())
        self.assertTrue((run / "comparison-results.csv").is_file())
        self.assertEqual(results[0]["NormalizationVersion"], app.VERSION)
        self.assertFalse(results[0]["BytesIdentical"])
        self.assertTrue(results[0]["DefinitionIdentical"])
        _, second = self.run_factory()
        self.assertNotEqual(run, second)
        self.assertEqual((run / "exports" / "p.json").read_bytes(), EXPORT)

    def test_factory_export_failure_continues(self):
        self.http.export_failure = True
        results, run = self.run_factory()
        self.assertEqual([row["Result"] for row in results], ["ERROR", "MATCH"])
        self.assertIn("ADF export failed", results[0]["Error"])
        self.assertFalse((run / "exports" / "p.json").exists())
        self.assertEqual(list(run.rglob("*.partial")), [])
        self.assertTrue((run / "exports" / "second.json").is_file())

    def test_factory_pagination(self):
        original = self.http.json
        second_page = ARM + "/pipelines?api-version=2018-06-01&page=2"
        self.http.next_link = second_page

        def pages(url, headers):
            if url == second_page:
                self.http.calls.append(url)
                return {"value": [{"name": "second"}]}
            result = original(url, headers)
            if url.startswith(ARM):
                result["value"] = [{"name": "p"}]
            return result

        with patch.object(self.http, "json", side_effect=pages):
            results, _ = self.run_factory()
        self.assertEqual(len(results), 2)
        self.assertEqual(app.exit_code(results), 0)

    def test_factory_rejects_bad_list_pagination_and_names(self):
        for next_link in ("https://example.com/collect", ARM + "/pipelines?api-version=2018-06-01",
                          ARM.replace("factory1", "other") + "/pipelines?x=1"):
            self.http.next_link = next_link
            with self.subTest(next_link=next_link), self.assertRaisesRegex(ValueError, "pagination"):
                self.run_factory()
        self.http.next_link = ""
        self.http.empty = True
        with self.assertRaisesRegex(ValueError, "No published"):
            self.run_factory()
        self.http.empty = False
        self.http.pipeline_data["P"] = EXPORT
        with self.assertRaisesRegex(ValueError, "collision"):
            self.run_factory()
        for name in ("..\\escape", "CON", "a/b", "trailing.", "", "x\x00"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                app.safe_filename(name)
        with self.assertRaises(ValueError):
            app.factory("/invalid", REPO)

    def test_cli_exit_codes_and_help(self):
        source = self.file("p.json", EXPORT)
        target = self.file("copy.json", UI)
        script = ROOT / "compare_adf_pipeline.py"
        for mode, expected in (("ExactBytes", 1), ("PipelineDefinition", 0)):
            result = subprocess.run([sys.executable, str(script), "--adf-path", str(source),
                                     "--git-path", str(target), "--comparison-mode", mode],
                                    capture_output=True, check=False)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual(json.loads(result.stdout)["ComparisonMode"], mode)
        for name in ("compare_adf_factory.py", "compare_adf_pipelines.py", "compare_adf_pipeline.py"):
            help_result = subprocess.run([sys.executable, str(ROOT / name), "--help"],
                                         capture_output=True, check=False)
            self.assertEqual(help_result.returncode, 0)

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 needed for cross-language hash parity")
    def test_hash_parity_with_powershell_v2(self):
        paths = []
        for index, value in enumerate((
            EXPORT,
            b'{"name":"p","properties":{"z":"\\n\\u0001\\b","a":1.00,"n":1e3}}',
            '{"name":"p","properties":{"😀":"á","\\ue000":1,"\\ud800":2}}'.encode("utf-8"),
            b'{"name":"p","properties":{"x":9007199254740993,"y":0.12345678901234567890123456789}}',
        )):
            paths.append(self.file(f"parity{index}.json", value))
        cs_path = ROOT.parent / "powershell" / "PipelineDefinition.cs"
        script = "Add-Type -Path '" + str(cs_path).replace("'", "''") + "';"
        for path in paths:
            script += "[AdfCompare.PipelineDefinition]::HashFile('" + str(path).replace("'", "''") + "');"
        result = subprocess.run(["pwsh", "-NoProfile", "-EncodedCommand",
                                 base64.b64encode(script.encode("utf-16-le")).decode("ascii")],
                                capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode().splitlines(),
                         [app.definition_hash(path.read_bytes()) for path in paths])


if __name__ == "__main__":
    unittest.main()
