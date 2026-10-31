using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace AdfCompare
{
    // A strict parser avoids PowerShell-version differences, case-insensitive
    // property maps, date coercion and floating-point rounding in JSON conversion.
    public static class PipelineDefinition
    {
        public const string Version = "PipelineDefinition-v2";

        public static string HashFile(string path)
        {
            string text;
            using (var reader = new StreamReader(path, new UTF8Encoding(false, true), true))
                text = reader.ReadToEnd();
            var root = new Parser(text).Parse() as SortedDictionary<string, object>;
            object name, properties, type;
            if (root == null || !root.TryGetValue("name", out name) ||
                !(name is string) || String.IsNullOrWhiteSpace((string)name) ||
                !root.TryGetValue("properties", out properties) ||
                !(properties is SortedDictionary<string, object>))
                throw new FormatException("Expected a pipeline object with a nonempty name and object properties.");
            if (root.TryGetValue("type", out type) &&
                !String.Equals(type as string, "Microsoft.DataFactory/factories/pipelines", StringComparison.Ordinal))
                throw new FormatException("Unexpected root pipeline type.");
            root.Remove("id");
            root.Remove("etag");
            root.Remove("type");
            var pipelineProperties = (SortedDictionary<string, object>)properties;
            pipelineProperties.Remove("lastPublishTime");
            object policyValue;
            if (pipelineProperties.TryGetValue("policy", out policyValue))
            {
                var policy = policyValue as SortedDictionary<string, object>;
                if (policy != null)
                {
                    object metricValue;
                    if (policy.TryGetValue("elapsedTimeMetric", out metricValue))
                    {
                        var metric = metricValue as SortedDictionary<string, object>;
                        if (metric != null && metric.Count == 0) policy.Remove("elapsedTimeMetric");
                    }
                    if (policy.Count == 0) pipelineProperties.Remove("policy");
                }
            }
            var canonical = new StringBuilder();
            Write(root, canonical);
            using (var algorithm = SHA256.Create())
                return BitConverter.ToString(algorithm.ComputeHash(
                    new UTF8Encoding(false, true).GetBytes(canonical.ToString()))).Replace("-", "");
        }

        private sealed class Number
        {
            public readonly string Value;
            public Number(string token)
            {
                var match = Regex.Match(token, @"^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$");
                string digits = (match.Groups[2].Value + match.Groups[3].Value).TrimStart('0');
                if (digits.Length == 0) { Value = "0"; return; }
                long exponent = 0;
                if (match.Groups[4].Success && !Int64.TryParse(match.Groups[4].Value,
                    NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out exponent))
                    throw new FormatException("JSON number exponent exceeds the supported Int64 range.");
                checked { exponent -= match.Groups[3].Value.Length; }
                int length = digits.Length;
                digits = digits.TrimEnd('0');
                checked { exponent += length - digits.Length; }
                Value = match.Groups[1].Value + digits + "e" + exponent.ToString(CultureInfo.InvariantCulture);
            }
        }

        private static void Write(object value, StringBuilder output)
        {
            var obj = value as SortedDictionary<string, object>;
            var array = value as List<object>;
            if (obj != null)
            {
                output.Append('{');
                bool first = true;
                foreach (var pair in obj)
                {
                    if (!first) output.Append(',');
                    first = false;
                    WriteString(pair.Key, output);
                    output.Append(':');
                    Write(pair.Value, output);
                }
                output.Append('}');
            }
            else if (array != null)
            {
                output.Append('[');
                for (int i = 0; i < array.Count; i++)
                {
                    if (i != 0) output.Append(',');
                    Write(array[i], output);
                }
                output.Append(']');
            }
            else if (value is string) WriteString((string)value, output);
            else if (value is Number) output.Append(((Number)value).Value);
            else if (value is bool) output.Append((bool)value ? "true" : "false");
            else output.Append("null");
        }

        private static void WriteString(string value, StringBuilder output)
        {
            output.Append('"');
            foreach (char c in value)
            {
                if (c == '"' || c == '\\') output.Append('\\').Append(c);
                else if (c < 32 || c > 126)
                    output.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                else output.Append(c);
            }
            output.Append('"');
        }

        private sealed class Parser
        {
            private readonly string text;
            private int position;
            public Parser(string text) { this.text = text; }
            public object Parse()
            {
                object value = ReadValue(0);
                Space();
                if (position != text.Length) Fail();
                return value;
            }
            private void Space()
            {
                while (position < text.Length && (text[position] == ' ' ||
                    text[position] == '\t' || text[position] == '\r' || text[position] == '\n')) position++;
            }
            private bool Take(char c)
            {
                Space();
                if (position < text.Length && text[position] == c) { position++; return true; }
                return false;
            }
            private void Require(char c) { if (!Take(c)) Fail(); }
            private void Fail() { throw new FormatException("Invalid JSON at character " + position + "."); }
            private object ReadValue(int depth)
            {
                if (depth > 256) throw new FormatException("JSON nesting exceeds 256 levels.");
                Space();
                if (position == text.Length) { Fail(); return null; }
                char c = text[position];
                if (c == '{')
                {
                    position++;
                    var obj = new SortedDictionary<string, object>(StringComparer.Ordinal);
                    if (Take('}')) return obj;
                    do
                    {
                        Space();
                        string key = ReadString();
                        Require(':');
                        if (obj.ContainsKey(key)) throw new FormatException("Duplicate JSON property.");
                        obj.Add(key, ReadValue(depth + 1));
                        if (Take('}')) return obj;
                        Require(',');
                    } while (true);
                }
                if (c == '[')
                {
                    position++;
                    var array = new List<object>();
                    if (Take(']')) return array;
                    do
                    {
                        array.Add(ReadValue(depth + 1));
                        if (Take(']')) return array;
                        Require(',');
                    } while (true);
                }
                if (c == '"') return ReadString();
                if (c == 't') { Literal("true"); return true; }
                if (c == 'f') { Literal("false"); return false; }
                if (c == 'n') { Literal("null"); return null; }
                var match = Regex.Match(text.Substring(position), @"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?");
                if (!match.Success) { Fail(); return null; }
                position += match.Length;
                return new Number(match.Value);
            }
            private void Literal(string expected)
            {
                if (position + expected.Length > text.Length ||
                    String.CompareOrdinal(text, position, expected, 0, expected.Length) != 0) Fail();
                position += expected.Length;
            }
            private string ReadString()
            {
                if (position >= text.Length || text[position++] != '"') { Fail(); return null; }
                var value = new StringBuilder();
                while (position < text.Length)
                {
                    char c = text[position++];
                    if (c == '"') return value.ToString();
                    if (c < 32) Fail();
                    if (c != '\\') { value.Append(c); continue; }
                    if (position == text.Length) Fail();
                    c = text[position++];
                    switch (c)
                    {
                        case '"': case '\\': case '/': value.Append(c); break;
                        case 'b': value.Append('\b'); break;
                        case 'f': value.Append('\f'); break;
                        case 'n': value.Append('\n'); break;
                        case 'r': value.Append('\r'); break;
                        case 't': value.Append('\t'); break;
                        case 'u':
                            ushort code;
                            if (position + 4 > text.Length || !UInt16.TryParse(text.Substring(position, 4),
                                NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code)) { Fail(); return null; }
                            value.Append((char)code);
                            position += 4;
                            break;
                        default: Fail(); break;
                    }
                }
                Fail();
                return null;
            }
        }
    }
}
