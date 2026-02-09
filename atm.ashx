<%@ WebHandler Language="C#" Class="AtmHandler" %>

using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
using System.Collections.Generic;

public class AtmHandler : IHttpHandler
{
    private const string WRAPPER_URL = "http://10.66.225.108/eds/atm.php";

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;

        try
        {
            string wrapperHtml = HttpGet(WRAPPER_URL);

            // Find iframe src="/atm/"
            string iframeSrc = ExtractIframeSrc(wrapperHtml);

            // Build absolute iframe URL
            string iframeUrl = MakeAbsoluteUrl(WRAPPER_URL, iframeSrc);

            // Fetch iframe page HTML
            string iframeHtml = HttpGet(iframeUrl);

            // Try parse the first HTML table on the iframe page
            var table = TryParseFirstHtmlTable(iframeHtml);

            var result = new
            {
                wrapperUrl = WRAPPER_URL,
                iframeUrl = iframeUrl,
                fetchedAtUtc = DateTime.UtcNow.ToString("o"),
                wrapperLength = wrapperHtml.Length,
                iframeLength = iframeHtml.Length,
                tableFound = table != null,
                table = table // null if none found
            };

            context.Response.Write(new JavaScriptSerializer().Serialize(result));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "Failed to fetch/parse ATM content",
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
        {
            return reader.ReadToEnd();
        }
    }

    private static string ExtractIframeSrc(string html)
    {
        // Very small, safe regex for iframe src="..."
        // Handles src="/atm/" or src='/atm/'
        var m = Regex.Match(html, "<iframe[^>]+src=[\"']([^\"']+)[\"']", RegexOptions.IgnoreCase);
        if (!m.Success) throw new Exception("No <iframe src=...> found in wrapper HTML.");
        return m.Groups[1].Value;
    }

    private static string MakeAbsoluteUrl(string baseUrl, string maybeRelative)
    {
        // baseUrl like http://10.66.225.108/eds/atm.php
        var baseUri = new Uri(baseUrl);
        var full = new Uri(baseUri, maybeRelative);
        return full.ToString();
    }

    private static object TryParseFirstHtmlTable(string html)
    {
        // Simple non-library table parse (works if tables are basic)
        // If the iframe content is heavy JS-rendered, this will return null.
        var tableMatch = Regex.Match(html, "<table[\\s\\S]*?</table>", RegexOptions.IgnoreCase);
        if (!tableMatch.Success) return null;

        string tableHtml = tableMatch.Value;

        // headers: <th>...</th>
        var headerMatches = Regex.Matches(tableHtml, "<th[^>]*>([\\s\\S]*?)</th>", RegexOptions.IgnoreCase);
        var headers = new List<string>();
        foreach (Match hm in headerMatches)
            headers.Add(StripTags(hm.Groups[1].Value).Trim());

        // rows: <tr>...</tr> containing <td>
        var rowMatches = Regex.Matches(tableHtml, "<tr[^>]*>([\\s\\S]*?)</tr>", RegexOptions.IgnoreCase);
        var rows = new List<Dictionary<string, string>>();

        foreach (Match rm in rowMatches)
        {
            var tdMatches = Regex.Matches(rm.Groups[1].Value, "<td[^>]*>([\\s\\S]*?)</td>", RegexOptions.IgnoreCase);
            if (tdMatches.Count == 0) continue;

            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < tdMatches.Count; i++)
            {
                string key = (headers.Count > i && !string.IsNullOrEmpty(headers[i])) ? headers[i] : "col_" + (i + 1);
                row[key] = StripTags(tdMatches[i].Groups[1].Value).Trim();
            }
            rows.Add(row);
        }

        return new
        {
            headers = headers,
            rowCount = rows.Count,
            rows = rows
        };
    }

    private static string StripTags(string input)
    {
        var noTags = Regex.Replace(input, "<[^>]+>", "");
        return WebUtility.HtmlDecode(noTags);
    }

    public bool IsReusable
    {
        get { return true; }
    }
}
