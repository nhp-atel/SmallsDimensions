<%@ WebHandler Language="C#" Class="AtmDataHandler" %>

using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
using System.Collections.Generic;

public class AtmDataHandler : IHttpHandler
{
    // Map friendly names to actual pages
    private static readonly Dictionary<string, string> PageMap =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "index", "http://10.66.225.108/atm/index.php" },
            { "atmrecent", "http://10.66.225.108/atm/atmrecent.php" },
            { "diags", "http://10.66.225.108/atm/diags.php" },
            { "tolerances", "http://10.66.225.108/atm/tolerances.php" },
            { "tolerance_report", "http://10.66.225.108/atm/tolerance_report.php" },
            { "size_report", "http://10.66.225.108/atm/size_report.php" },
            { "sorts_config", "http://10.66.225.108/atm/sorts_config.php" },
            { "cfx", "http://10.66.225.108/atm/cfx.php" }
        };

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;

        string pageKey = (context.Request["page"] ?? "atmrecent").Trim();

        if (!PageMap.ContainsKey(pageKey))
        {
            context.Response.StatusCode = 400;
            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "Unknown page key",
                allowed = new List<string>(PageMap.Keys),
                example = "atmdata.ashx?page=atmrecent"
            }));
            return;
        }

        var url = PageMap[pageKey];

        try
        {
            string html = HttpGet(url);

            // Parse ALL tables found
            var tables = HtmlTableRegexParser.ParseAllTables(html);

            var result = new
            {
                page = pageKey,
                url = url,
                fetchedAtUtc = DateTime.UtcNow.ToString("o"),
                htmlLength = html.Length,
                tableCount = tables.Count,
                tables = tables
            };

            context.Response.Write(new JavaScriptSerializer().Serialize(result));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "Failed to fetch/parse page",
                page = pageKey,
                url = url,
                message = ex.Message,
                utc = DateTime.UtcNow.ToString("o")
            }));
        }
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

static class HtmlTableRegexParser
{
    public static List<object> ParseAllTables(string html)
    {
        var tables = new List<object>();

        // capture each <table>...</table>
        var tableMatches = Regex.Matches(html, "<table[\\s\\S]*?</table>", RegexOptions.IgnoreCase);
        int tableIndex = 0;

        foreach (Match tm in tableMatches)
        {
            tableIndex++;
            string tableHtml = tm.Value;

            // headers from th, else empty and we'll use col_#
            var headerMatches = Regex.Matches(tableHtml, "<th[^>]*>([\\s\\S]*?)</th>", RegexOptions.IgnoreCase);
            var headers = new List<string>();
            foreach (Match hm in headerMatches)
                headers.Add(StripTags(hm.Groups[1].Value).Trim());

            var rows = new List<Dictionary<string, string>>();

            // rows: each <tr> with <td>
            var trMatches = Regex.Matches(tableHtml, "<tr[^>]*>([\\s\\S]*?)</tr>", RegexOptions.IgnoreCase);
            foreach (Match trm in trMatches)
            {
                var tdMatches = Regex.Matches(trm.Groups[1].Value, "<td[^>]*>([\\s\\S]*?)</td>", RegexOptions.IgnoreCase);
                if (tdMatches.Count == 0) continue;

                var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < tdMatches.Count; i++)
                {
                    string key =
                        (headers.Count > i && !string.IsNullOrEmpty(headers[i]))
                        ? headers[i]
                        : "col_" + (i + 1);

                    row[key] = StripTags(tdMatches[i].Groups[1].Value).Trim();
                }

                rows.Add(row);
            }

            // Only keep tables that actually have data rows
            if (rows.Count > 0)
            {
                tables.Add(new
                {
                    index = tableIndex,
                    headers = headers,
                    rowCount = rows.Count,
                    rows = rows
                });
            }
        }

        return tables;
    }

    private static string StripTags(string input)
    {
        var noTags = Regex.Replace(input, "<[^>]+>", "");
        return WebUtility.HtmlDecode(noTags);
    }
}
