"""Shared ADF/GitHub comparison implementation. Python 3.10+, standard library only."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from decimal import Decimal, DecimalException
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import uuid4


VERSION = "PipelineDefinition-v2"
MODES = ("ExactBytes", "PipelineDefinition")
FIELDS = [
    "AdfPath", "GitPath", "GitUrl", "AdfSHA256", "GitSHA256",
    "ComparisonMode", "NormalizationVersion", "AdfDefinitionSHA256",
    "GitDefinitionSHA256", "BytesIdentical", "DefinitionIdentical",
    "Identical", "Result", "Error",
]
ERRORS = (OSError, ValueError, TypeError, RecursionError)
RESOURCE_ID = re.compile(
    r"/subscriptions/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
    r"/resourceGroups/([^/]+)/providers/Microsoft\.DataFactory/factories/"
    r"([a-z0-9][a-z0-9-]{1,61}[a-z0-9])/?", re.I,
)


def warn(message: str) -> None:
    print(message, file=sys.stderr)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON property: {key!r}.")
        result[key] = value
    return result


def invalid_constant(value: str) -> None:
    raise ValueError(f"Invalid JSON number: {value}.")


def parse_json(data: bytes) -> object:
    try:
        return json.loads(
            data, object_pairs_hook=unique_object, parse_int=Decimal,
            parse_float=Decimal, parse_constant=invalid_constant,
        )
    except DecimalException:
        raise ValueError("JSON number exceeds the supported Decimal range.") from None


def pipeline_object(data: bytes) -> dict:
    root = parse_json(data)
    if (not isinstance(root, dict) or not isinstance(root.get("name"), str)
            or not root["name"].strip() or not isinstance(root.get("properties"), dict)):
        raise ValueError("Expected a pipeline object with nonempty name and object properties.")
    if "type" in root and root["type"] != "Microsoft.DataFactory/factories/pipelines":
        raise ValueError("Unexpected root pipeline type.")
    return root


def quoted(value: str) -> str:
    # Match the PowerShell/C# v2 representation, including UTF-16 ordinal ordering.
    units = value.encode("utf-16-be", errors="surrogatepass")
    chars = []
    for index in range(0, len(units), 2):
        code = int.from_bytes(units[index:index + 2], "big")
        if code in (34, 92):
            chars.append("\\" + chr(code))
        elif code < 32 or code > 126:
            chars.append(f"\\u{code:04x}")
        else:
            chars.append(chr(code))
    return '"' + "".join(chars) + '"'


def canonical(value: object, depth: int = 0) -> str:
    if depth > 256:
        raise ValueError("JSON nesting exceeds 256 levels.")
    if isinstance(value, dict):
        keys = sorted(value, key=lambda key: key.encode("utf-16-be", errors="surrogatepass"))
        return "{" + ",".join(quoted(key) + ":" + canonical(value[key], depth + 1)
                              for key in keys) + "}"
    if isinstance(value, list):
        return "[" + ",".join(canonical(item, depth + 1) for item in value) + "]"
    if isinstance(value, str):
        return quoted(value)
    if isinstance(value, Decimal):
        if value.is_zero():
            return "0"
        parts = value.as_tuple()
        digits = "".join(str(digit) for digit in parts.digits)
        trimmed = digits.rstrip("0")
        exponent = int(parts.exponent) + len(digits) - len(trimmed)
        if not -(2**63) <= exponent < 2**63:
            raise ValueError("Normalized number exponent exceeds Int64 range.")
        return ("-" if parts.sign else "") + trimmed + "e" + str(exponent)
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    raise ValueError("Unsupported JSON value.")


def definition_hash(data: bytes) -> str:
    root = pipeline_object(data)
    # Check depth before exclusions as well, so malformed ignored metadata cannot hide it.
    canonical(root)
    for key in ("id", "etag", "type"):
        root.pop(key, None)
    properties = root["properties"]
    properties.pop("lastPublishTime", None)
    policy = properties.get("policy")
    if isinstance(policy, dict):
        if policy.get("elapsedTimeMetric") == {}:
            policy.pop("elapsedTimeMetric")
        if not policy:
            properties.pop("policy")
    return sha256(canonical(root).encode("utf-8"))


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HttpClient:
    def __init__(self) -> None:
        self.opener = build_opener(NoRedirect())

    def get(self, url: str, headers: dict[str, str]) -> tuple[bytes, str]:
        try:
            with self.opener.open(Request(url, headers=headers), timeout=60) as response:
                return response.read(), response.headers.get_content_type()
        except HTTPError as error:
            # Do not log request headers, tokens or response bodies.
            status = error.code
            error.close()
            raise OSError(f"HTTP {status}: request failed for {url}.") from None
        except URLError as error:
            raise OSError(f"Network request failed for {url}: {error.reason}.") from None

    def json(self, url: str, headers: dict[str, str]) -> dict:
        data, content_type = self.get(url, headers)
        if content_type not in ("application/json", "application/vnd.github+json"):
            raise ValueError("Expected a JSON API response.")
        result = parse_json(data)
        if not isinstance(result, dict):
            raise ValueError("Expected a JSON API object.")
        return result


def https_url(url: str, host: str):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or parsed.hostname != host or parsed.port not in (None, 443)
            or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment):
        raise ValueError(f"Expected an HTTPS URL on {host} without credentials, query or fragment.")
    return parsed


def github_headers(raw: bool = False) -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github.raw+json" if raw else "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "adf-compare-with-git",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def github_file(url: str, http: HttpClient) -> bytes:
    parsed = https_url(url, "github.com")
    match = re.fullmatch(r"/([^/]+)/([^/]+)/blob/([^/]+)/(.+\.json)", parsed.path, re.I)
    if not match:
        raise ValueError("GitUrl must be https://github.com/OWNER/REPO/blob/REF/PATH.json.")
    owner, repo, ref, path = match.groups()
    encode = lambda part: quote(unquote(part), safe="")
    api = (f"https://api.github.com/repos/{encode(owner)}/{encode(repo)}/contents/"
           + "/".join(encode(part) for part in path.split("/")) + f"?ref={encode(ref)}")
    data, content_type = http.get(api, github_headers(raw=True))
    if content_type not in ("application/vnd.github.raw+json", "application/vnd.github.raw"):
        raise ValueError("GitHub did not return raw file content.")
    return data


class Repository:
    def __init__(self, url: str, ref: str | None, http: HttpClient) -> None:
        parsed = https_url(url, "github.com")
        match = re.fullmatch(r"/([^/]+)/([^/]+?)(?:\.git)?/?", parsed.path)
        if not match:
            raise ValueError("RepoUrl must be https://github.com/OWNER/REPO.")
        owner, repo = (quote(unquote(part), safe="") for part in match.groups())
        self.web = f"https://github.com/{owner}/{repo}"
        api = f"https://api.github.com/repos/{owner}/{repo}"
        headers = github_headers()
        if not ref:
            ref = http.json(api, headers).get("default_branch")
            if not isinstance(ref, str) or not ref.strip():
                raise ValueError("GitHub did not return a default branch.")
        commit = http.json(f"{api}/commits/{quote(ref, safe='')}", headers)
        self.commit = commit.get("sha")
        details = commit.get("commit")
        tree_details = details.get("tree") if isinstance(details, dict) else None
        tree_sha = tree_details.get("sha") if isinstance(tree_details, dict) else None
        for value in (self.commit, tree_sha):
            if not isinstance(value, str) or not re.fullmatch(r"(?:[a-f0-9]{40}|[a-f0-9]{64})", value):
                raise ValueError("GitHub did not return a valid commit/tree.")
        tree = http.json(f"{api}/git/trees/{tree_sha}?recursive=1", headers)
        if tree.get("truncated") is not False or not isinstance(tree.get("tree"), list):
            raise ValueError("Invalid or truncated GitHub repository tree.")
        self.files: dict[str, list[str]] = {}
        for item in tree["tree"]:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                raise ValueError("Invalid GitHub tree entry.")
            path = item["path"]
            if item.get("type") == "blob" and item.get("mode") != "120000" and path.lower().endswith(".json"):
                self.files.setdefault(path.rsplit("/", 1)[-1], []).append(path)
        print(f"Repository snapshot: {self.commit}")

    def file_url(self, name: str) -> str:
        matches = self.files.get(name, [])
        if not matches:
            raise ValueError(f"No JSON named {name!r} in repository (case-sensitive search).")
        if len(matches) != 1:
            raise ValueError(f"Multiple JSON files named {name!r}: {', '.join(matches)}. Use explicit GitUrl.")
        path = "/".join(quote(part, safe="") for part in matches[0].split("/"))
        return f"{self.web}/blob/{self.commit}/{path}"


def empty_result(adf_path: str, git_path: str, git_url: str, mode: str) -> dict:
    result = dict.fromkeys(FIELDS)
    result.update(AdfPath=adf_path, GitPath=git_path or None, GitUrl=git_url or None,
                  ComparisonMode=mode, Result="ERROR",
                  NormalizationVersion=VERSION if mode == "PipelineDefinition" else None)
    return result


def compare(adf_path: str, *, git_path: str = "", git_url: str = "",
            mode: str = "ExactBytes", http: HttpClient | None = None) -> dict:
    result = empty_result(adf_path, git_path, git_url, mode)
    try:
        if mode not in MODES or bool(git_path) == bool(git_url):
            raise ValueError("Select a valid mode and exactly one of GitPath/GitUrl.")
        source = Path(adf_path).read_bytes()
        target = github_file(git_url, http or HttpClient()) if git_url else Path(git_path).read_bytes()
        result.update(AdfSHA256=sha256(source), GitSHA256=sha256(target))
        result["BytesIdentical"] = result["AdfSHA256"] == result["GitSHA256"]
        if mode == "PipelineDefinition":
            result["AdfDefinitionSHA256"] = definition_hash(source)
            result["GitDefinitionSHA256"] = definition_hash(target)
            result["DefinitionIdentical"] = result["AdfDefinitionSHA256"] == result["GitDefinitionSHA256"]
            result["Identical"] = result["DefinitionIdentical"]
        else:
            result["Identical"] = result["BytesIdentical"]
        result["Result"] = "MATCH" if result["Identical"] else "DIFFERENT"
    except ERRORS as error:
        result["Error"] = str(error)
        warn(f"Comparison failed: {error}")
    return result


def exit_code(results: list[dict]) -> int:
    if not results or any(row["Result"] == "ERROR" for row in results):
        return 2
    return 1 if any(row["Result"] == "DIFFERENT" for row in results) else 0


def write_csv(path: Path, rows: list[dict], fields: list[str], delimiter: str) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter=delimiter, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def batch(csv_path: str, report_path: str, *, repo_url: str = "", git_ref: str = "",
          mode: str = "ExactBytes", delimiter: str = ",", http: HttpClient | None = None) -> list[dict]:
    source = Path(csv_path).resolve()
    report = Path(report_path).resolve()
    if git_ref and not repo_url:
        raise ValueError("GitRef requires RepoUrl.")
    if mode not in MODES or delimiter not in (",", ";"):
        raise ValueError("Invalid comparison mode or delimiter.")
    if report == source or report.is_dir() or not report.parent.is_dir():
        raise ValueError("ReportPath must not overwrite input CSV and must be in an existing directory.")
    with source.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream, delimiter=delimiter, strict=True)
        required = {"AdfPath"} if repo_url else {"AdfPath", "GitUrl"}
        if not required.issubset(reader.fieldnames or []) or len(set(reader.fieldnames or [])) != len(reader.fieldnames or []):
            raise ValueError("CSV requires AdfPath and, without RepoUrl, GitUrl. Check headers/delimiter.")
        entries = list(reader)
    if not entries:
        raise ValueError("CSV must contain at least one data row.")
    prepared = []
    for number, entry in enumerate(entries, 2):
        raw_path = entry.get("AdfPath") or ""
        path = Path(raw_path)
        path = (source.parent / path).resolve() if not path.is_absolute() else path.resolve()
        if raw_path.strip() and path == report:
            raise ValueError("ReportPath must not overwrite an ADF source file.")
        prepared.append((number, entry, str(path) if raw_path.strip() else ""))
    client = http or HttpClient()
    repository = Repository(repo_url, git_ref, client) if repo_url else None
    results = []
    for number, entry, path in prepared:
        url = "" if repo_url else entry.get("GitUrl") or ""
        result = empty_result(path, "", url, mode)
        try:
            if None in entry or any(value is None for value in entry.values()):
                raise ValueError("CSV row has extra or missing fields.")
            if not path:
                raise ValueError("AdfPath is required for every row.")
            if repository:
                url = repository.file_url(Path(path).name)
            if not url.strip():
                raise ValueError("GitUrl is required for every row.")
            result = compare(path, git_url=url, mode=mode, http=client)
        except ERRORS as error:
            result["Error"] = str(error)
        result["Row"] = number
        if result["Result"] == "ERROR":
            warn(f"Row {number}: {result['Error']}")
        results.append(result)
    write_csv(report, results, ["Row"] + FIELDS, delimiter)
    for row in results:
        print(f"{row['Row']}: {row['Result']} | {row['AdfPath']}")
    print(" | ".join(f"{status}: {sum(row['Result'] == status for row in results)}"
                     for status in ("MATCH", "DIFFERENT", "ERROR")))
    print(f"Report: {report}")
    return results


class ArmClient:
    def __init__(self, subscription: str, http: HttpClient) -> None:
        self.subscription = subscription
        self.http = http
        self.token = ""
        self.expiry = 0.0

    def headers(self) -> dict[str, str]:
        if self.expiry <= time.time() + 300:
            executable = shutil.which("az")
            if not executable:
                raise OSError("Azure CLI 2.54+ is required. Install it and run az login.")
            # An argument list avoids shell interpolation, including for az.cmd on Windows.
            completed = subprocess.run(
                [executable, "account", "get-access-token", "--subscription", self.subscription,
                 "--resource", "https://management.azure.com/", "--output", "json"],
                capture_output=True, timeout=120, check=False,
            )
            if completed.returncode:
                raise ValueError("Azure authentication failed. Run az login with read access to the factory.")
            token = parse_json(completed.stdout)
            if not isinstance(token, dict) or not isinstance(token.get("accessToken"), str) or not token["accessToken"]:
                raise ValueError("Azure CLI did not return an access token.")
            self.expiry = float(token.get("expires_on", 0))
            if self.expiry <= time.time():
                raise ValueError("Azure CLI returned a missing/expired expires_on. Use CLI 2.54+ and az login.")
            self.token = token["accessToken"]
        return {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}


def safe_filename(name: object) -> str:
    if (not isinstance(name, str) or not name.strip() or len(name.encode("utf-16-le")) // 2 > 250
            or name in (".", "..") or name.endswith((".", " "))
            or re.search(r'[<>:"/\\|?*\x00-\x1f]', name)
            or re.match(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", name, re.I)):
        raise ValueError("ADF returned a pipeline name unsafe for Windows export.")
    return name


def factory(resource_id: str, repo_url: str, *, output_directory: str = ".\\adf-comparison",
            git_ref: str = "", mode: str = "ExactBytes", delimiter: str = ",",
            http: HttpClient | None = None) -> tuple[list[dict], Path]:
    match = RESOURCE_ID.fullmatch(resource_id)
    if not match:
        raise ValueError("FactoryResourceId must identify /subscriptions/GUID/resourceGroups/GROUP/providers/Microsoft.DataFactory/factories/FACTORY.")
    if mode not in MODES or delimiter not in (",", ";"):
        raise ValueError("Invalid mode or delimiter.")
    https_url(repo_url, "github.com")
    subscription, group, name = match.groups()
    base = (f"https://management.azure.com/subscriptions/{subscription}/resourceGroups/"
            f"{quote(group, safe='')}/providers/Microsoft.DataFactory/factories/{quote(name, safe='')}")
    list_url = base + "/pipelines?api-version=2018-06-01"
    client = http or HttpClient()
    arm = ArmClient(subscription, client)
    names = []
    seen_names: set[str] = set()
    visited: set[str] = set()
    page_url = list_url
    while page_url:
        if not isinstance(page_url, str):
            raise ValueError("ADF returned an invalid pagination URL.")
        parsed = urlsplit(page_url)
        if (parsed.scheme != "https" or parsed.hostname != "management.azure.com"
                or parsed.port not in (None, 443) or parsed.username is not None
                or parsed.password is not None or parsed.fragment
                or parsed.path != urlsplit(list_url).path or page_url in visited):
            raise ValueError("ADF returned unsafe or repeated pagination URL.")
        visited.add(page_url)
        page = client.json(page_url, arm.headers())
        if not isinstance(page.get("value"), list):
            raise ValueError("ADF did not return a pipeline list in value.")
        for item in page["value"]:
            if not isinstance(item, dict):
                raise ValueError("Invalid pipeline list entry.")
            pipeline_name = safe_filename(item.get("name"))
            if pipeline_name.casefold() in seen_names:
                raise ValueError("Duplicate pipeline name or Windows filename collision.")
            seen_names.add(pipeline_name.casefold())
            names.append(pipeline_name)
        page_url = page.get("nextLink")
    if not names:
        raise ValueError("No published pipelines found; nothing to compare.")
    run = Path(output_directory).resolve() / f"{name}-{datetime.now():%Y%m%d-%H%M%S}-{uuid4().hex}"
    exports = run / "exports"
    exports.mkdir(parents=True, exist_ok=False)
    print(f"Factory: {name} | Published pipelines: {len(names)}\nRun directory: {run}")
    if mode == "ExactBytes":
        warn("ExactBytes includes ARM metadata and response formatting; equivalent pipelines may differ.")
    status = []
    for pipeline_name in names:
        path = exports / f"{pipeline_name}.json"
        partial = path.with_suffix(".json.partial")
        row = dict(PipelineName=pipeline_name, AdfPath=str(path), Result="ERROR", Error=None)
        try:
            data, content_type = client.get(
                f"{base}/pipelines/{quote(pipeline_name, safe='')}?api-version=2018-06-01", arm.headers(),
            )
            if content_type != "application/json":
                raise ValueError("ADF did not return application/json.")
            definition = pipeline_object(data)
            if definition["name"] != pipeline_name:
                raise ValueError("ADF returned a different pipeline name.")
            partial.write_bytes(data)
            partial.replace(path)
            row["Result"] = "EXPORTED"
        except ERRORS as error:
            row["Error"] = str(error)
            warn(f"Export failed for {pipeline_name!r}: {error}")
        finally:
            partial.unlink(missing_ok=True)
        status.append(row)
    manifest = run / "pipelines.csv"
    report = run / "comparison-results.csv"
    write_csv(manifest, status, ["AdfPath"], delimiter)
    write_csv(run / "export-status.csv", status, ["PipelineName", "AdfPath", "Result", "Error"], delimiter)
    results = batch(str(manifest), str(report), repo_url=repo_url, git_ref=git_ref,
                    mode=mode, delimiter=delimiter, http=client)
    for result, export in zip(results, status):
        if export["Result"] == "ERROR":
            result.update(Result="ERROR", Error=f"ADF export failed: {export['Error']}")
    write_csv(report, results, ["Row"] + FIELDS, delimiter)
    return results, run


def main(kind: str) -> int:
    parser = argparse.ArgumentParser(description=f"ADF comparison: {kind}")
    parser.add_argument("--comparison-mode", choices=MODES, default="ExactBytes")
    if kind == "pipeline":
        parser.add_argument("--adf-path", required=True)
        target = parser.add_mutually_exclusive_group(required=True)
        target.add_argument("--git-path", default="")
        target.add_argument("--git-url", default="")
    else:
        parser.add_argument("--repo-url", required=kind == "factory", default="")
        parser.add_argument("--git-ref", default="")
        parser.add_argument("--delimiter", choices=(",", ";"), default=",")
        if kind == "factory":
            parser.add_argument("--factory-resource-id", required=True)
            parser.add_argument("--output-directory", default=".\\adf-comparison")
        else:
            parser.add_argument("--csv-path", required=True)
            parser.add_argument("--report-path", default="comparison-results.csv")
    args = parser.parse_args()
    try:
        if kind == "pipeline":
            results = [compare(args.adf_path, git_path=args.git_path, git_url=args.git_url,
                               mode=args.comparison_mode)]
            print(json.dumps(results[0], indent=2, ensure_ascii=True))
        elif kind == "pipelines":
            results = batch(args.csv_path, args.report_path, repo_url=args.repo_url,
                            git_ref=args.git_ref, delimiter=args.delimiter, mode=args.comparison_mode)
        else:
            results, _ = factory(
                args.factory_resource_id, args.repo_url, output_directory=args.output_directory,
                git_ref=args.git_ref, delimiter=args.delimiter, mode=args.comparison_mode,
            )
        return exit_code(results)
    except (*ERRORS, csv.Error, subprocess.TimeoutExpired) as error:
        warn(f"ADF comparison failed: {error}")
        return 2
