<%@ WebHandler Language="C#" Class="SizeReportHandler" %>

using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
using System.Collections.Generic;

public class SizeReportHandler : IHttpHandler
{
    private const string SIZE_REPORT_URL = "http://10.66.225.108/atm/size_report.php";

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;

        try
        {
            string html = HttpGet(SIZE_REPORT_URL);

            // Parse all tables, then filter out junk like the ATM version banner
            var tables = HtmlTableRegexParserBase.ParseAllTables(html);

            // Filter: keep only tables with at least 3 columns OR headers containing "Report"/"Length"/"Width"/"Height"
            var filtered = new List<object>();
            foreach (var t in tables)
            {
                var headers = (List<string>)t.Headers;
                int maxCols = t.MaxCols;

                bool looksLikeSizeReport =
                    maxCols >= 3 ||
                    HasHeader(headers, "Report") ||
                    HasHeader(headers, "Length") ||
                    HasHeader(headers, "Width") ||
                    HasHeader(headers, "Height") ||
                    HasHeader(headers, "Sorts");

                // Also drop the "ATM version" banner rows
                if (looksLikeSizeReport && !t.ContainsAtmVersionBanner)
                    filtered.Add(new {
                        index = t.Index,
                        headers = headers,
                        rowCount = t.Rows.Count,
                        rows = t.Rows
                    });
            }

            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                page = "size_report",
                url = SIZE_REPORT_URL,
                fetchedAtUtc = DateTime.UtcNow.ToString("o"),
                htmlLength = html.Length,
                tableCount = filtered.Count,
                tables = filtered,
                note = "If tables still look empty, the real data is likely loaded via AJAX after clicking Run."
            }));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "Failed to fetch/parse size_report",
                url = SIZE_REPORT_URL,
                message = ex.Message,
                utc = DateTime.UtcNow.ToString("o")
            }));
        }
    }

    private static bool HasHeader(List<string> headers, string value)
    {
        foreach (var h in headers)
            if (!string.IsNullOrEmpty(h) && h.Trim().Equals(value, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    private static string HttpGet(string url)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = 30000;
        req.UserAgent = "RisewellAtmProxy/1.0";
        req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;

        using (var resp = (HttpWebResponse)req.GetResponse())
        using (var stream = resp.GetResponseStream())
        using (var reader = new StreamReader(stream))
            return reader.ReadToEnd();
    }

    public bool IsReusable { get { return true; } }
}

static class HtmlTableRegexParserBase
{
    public class ParsedTable
    {
        public int Index;
        public List<string> Headers = new List<string>();
        public List<Dictionary<string, string>> Rows = new List<Dictionary<string, string>>();
        public int MaxCols;
        public bool ContainsAtmVersionBanner;
    }

    public static List<ParsedTable> ParseAllTables(string html)
    {
        var tables = new List<ParsedTable>();
        var tableMatches = Regex.Matches(html, "<table[\\s\\S]*?</table>", RegexOptions.IgnoreCase);

        int tableIndex = 0;
        foreach (Match tm in tableMatches)
        {
            tableIndex++;
            string tableHtml = tm.Value;

            var pt = new ParsedTable();
            pt.Index = tableIndex;

            var headerMatches = Regex.Matches(tableHtml, "<th[^>]*>([\\s\\S]*?)</th>", RegexOptions.IgnoreCase);
            foreach (Match hm in headerMatches)
                pt.Headers.Add(StripTags(hm.Groups[1].Value).Trim());

            var trMatches = Regex.Matches(tableHtml, "<tr[^>]*>([\\s\\S]*?)</tr>", RegexOptions.IgnoreCase);

            foreach (Match trm in trMatches)
            {
                var tdMatches = Regex.Matches(trm.Groups[1].Value, "<td[^>]*>([\\s\\S]*?)</td>", RegexOptions.IgnoreCase);
                if (tdMatches.Count == 0) continue;

                pt.MaxCols = Math.Max(pt.MaxCols, tdMatches.Count);

                var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < tdMatches.Count; i++)
                {
                    string key =
                        (pt.Headers.Count > i && !string.IsNullOrEmpty(pt.Headers[i]))
                        ? pt.Headers[i]
                        : "col_" + (i + 1);

                    var val = StripTags(tdMatches[i].Groups[1].Value).Trim();
                    row[key] = val;

                    if (val.IndexOf("ATM", StringComparison.OrdinalIgnoreCase) >= 0 &&
                        val.IndexOf("version", StringComparison.OrdinalIgnoreCase) >= 0)
                        pt.ContainsAtmVersionBanner = true;
                }

                pt.Rows.Add(row);
            }

            // Keep only tables with some rows
            if (pt.Rows.Count > 0) tables.Add(pt);
        }

        return tables;
    }

    private static string StripTags(string input)
    {
        var noTags = Regex.Replace(input, "<[^>]+>", "");
        return WebUtility.HtmlDecode(noTags);
    }
}
