<%@ WebHandler Language="C#" Class="SizeReportRunHandler" %>

using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
using System.Collections.Generic;

public class SizeReportRunHandler : IHttpHandler
{
    private const string BASE_URL = "http://10.66.225.108/atm/size_report.php";

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;

        try
        {
            // --- Read incoming params (all optional) ---
            // report: small|large (default small)
            string report = (context.Request["report"] ?? "small").Trim().ToLowerInvariant();
            if (report != "small" && report != "large") report = "small";

            // date: pass-through; if blank, keep blank (site default)
            string date = (context.Request["date"] ?? "").Trim();

            // thresholds
            string l = (context.Request["l"] ?? "").Trim();
            string w = (context.Request["w"] ?? "").Trim();
            string h = (context.Request["h"] ?? "").Trim();

            // sorts: either comma list (?sorts=ALL,SUN) or repeated (?sort=ALL&sort=SUN)
            var sorts = new List<string>();
            string sortsCsv = (context.Request["sorts"] ?? "").Trim();
            if (!string.IsNullOrEmpty(sortsCsv))
            {
                foreach (var s in sortsCsv.Split(','))
                {
                    var v = s.Trim().ToUpperInvariant();
                    if (!string.IsNullOrEmpty(v)) sorts.Add(v);
                }
            }
            

            else
            {
                // allow ?sort=ALL&sort=SUN
                var sortValues = context.Request.QueryString.GetValues("sort");
                if (sortValues != null)
                {
                    foreach (var sv in sortValues)
                    {
                        var v = (sv ?? "").Trim().ToUpperInvariant();
                        if (!string.IsNullOrEmpty(v)) sorts.Add(v);
                    }
                }
            }


            // Default sorts if none provided: ALL
            if (sorts.Count == 0) sorts.Add("ALL");

            // Build the query exactly like the form:
            // ?date=...&report=small&l=..&w=..&h=..&sort[]=ALL&submit=1
            string url = BuildUrl(report, date, l, w, h, sorts);

            string html = HttpGet(url);

            // Parse ALL tables, then keep those that look like real report output (not just header UI)
            var parsedTables = HtmlTableRegexParser.ParseAllTables(html);

            var outputTables = new List<object>();
            foreach (var t in parsedTables)
            {
                // Heuristic: keep tables with some non-empty cells beyond the "ATM version" banner
                if (t.ContainsAtmVersionBanner) continue;

                // Keep if it has >= 2 rows and >= 3 columns OR any cell looks like real data (numbers etc.)
                bool keep =
                    t.Rows.Count >= 2 &&
                    t.MaxCols >= 3;

                if (keep)
                {
                    outputTables.Add(new
                    {
                        index = t.Index,
                        headers = t.Headers,
                        rowCount = t.Rows.Count,
                        rows = t.Rows
                    });
                }
            }

            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                page = "size_report",
                fetchedAtUtc = DateTime.UtcNow.ToString("o"),
                request = new
                {
                    report = report,
                    date = date,
                    l = l,
                    w = w,
                    h = h,
                    sorts = sorts,
                    url = url
                },
                htmlLength = html.Length,
                tableCount = outputTables.Count,
                tables = outputTables,
                note = "If tableCount is 0, the report output may be rendered outside tables or requires a non-empty date/thresholds."
            }));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "size_report run failed",
                message = ex.Message,
                utc = DateTime.UtcNow.ToString("o")
            }));
        }
    }

    private static string BuildUrl(string report, string date, string l, string w, string h, List<string> sorts)
    {
        var sb = new StringBuilder();
        sb.Append(BASE_URL);
        sb.Append("?");

        // Standard fields
        sb.Append("date=").Append(HttpUtility.UrlEncode(date));
        sb.Append("&report=").Append(HttpUtility.UrlEncode(report));
        sb.Append("&l=").Append(HttpUtility.UrlEncode(l));
        sb.Append("&w=").Append(HttpUtility.UrlEncode(w));
        sb.Append("&h=").Append(HttpUtility.UrlEncode(h));

        // sort[] fields
        foreach (var s in sorts)
        {
            sb.Append("&sort%5B%5D=").Append(HttpUtility.UrlEncode(s)); // sort[]= encoded
        }

        // hidden submit=1 (important)
        sb.Append("&submit=1");

        return sb.ToString();
    }

    private static string HttpGet(string url)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = 30000;
        req.UserAgent = "ATM-SizeReport-Proxy/1.0";
        req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;

        using (var resp = (HttpWebResponse)req.GetResponse())
        using (var stream = resp.GetResponseStream())
        using (var reader = new StreamReader(stream))
            return reader.ReadToEnd();
    }

    public bool IsReusable { get { return true; } }
}

static class HtmlTableRegexParser
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
