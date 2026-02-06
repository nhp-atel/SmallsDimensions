<%@ WebHandler Language="C#" Class="SizeReportViewHandler" %>

using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Linq;

public class SizeReportViewHandler : IHttpHandler
{
    private const string BASE_URL = "http://10.66.225.108/atm/size_report.php";
    private const string HIDDEN_URL = "http://10.66.225.108/atm/size_report_hidden.php";

    public void ProcessRequest(HttpContext context)
    {
        try
        {
            // -----------------------------
            // Read inputs
            // -----------------------------
            string date = (context.Request["date"] ?? "2025-12-29").Trim();
            string report = (context.Request["report"] ?? "small").Trim().ToLowerInvariant();
            if (report != "small" && report != "large") report = "small";

            string l = (context.Request["l"] ?? "16").Trim();
            string w = (context.Request["w"] ?? "16").Trim();
            string h = (context.Request["h"] ?? "7").Trim();

            // format modes:
            // - format=csv => download CSV
            // - format=xlsx => download CSV (Excel opens it)
            // - format=view => HTML view to verify data
            // - (default) => JSON
            string format = (context.Request["format"] ?? "").Trim().ToLowerInvariant();
            bool exportCsv = (format == "csv" || format == "xlsx");
            bool viewOnly = (format == "view");

            // sorts: CSV (?sorts=SUN,DAY) or repeated (?sort=SUN&sort=DAY)
            var sorts = new List<string>();
            string sortsCsv = (context.Request["sorts"] ?? "").Trim();

            if (!string.IsNullOrEmpty(sortsCsv))
            {
                foreach (var s in sortsCsv.Split(','))
                {
                    var v = (s ?? "").Trim().ToUpperInvariant();
                    if (!string.IsNullOrEmpty(v)) sorts.Add(v);
                }
            }
            else
            {
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

            if (sorts.Count == 0) sorts.Add("ALL");

            // Optional tuning
            int maxPolls = ParseIntOrDefault(context.Request["maxPolls"], 25);
            int delayMs = ParseIntOrDefault(context.Request["delayMs"], 1200);

            // -----------------------------
            // Requests
            // -----------------------------
            var cookies = new CookieContainer();
            var hops = new List<string>();

            // 1) establish session
            HttpResponseInfo warm = HttpGetInfo(BASE_URL, cookies, null);
            hops.Add("GET form status=" + warm.StatusCode + " final=" + warm.FinalUrl + " bytes=" + warm.Bytes);

            // 2) trigger generation
            string submitUrl = BuildSubmitUrl(date, report, l, w, h, sorts);
            HttpResponseInfo submitResp = HttpGetInfo(submitUrl, cookies, BASE_URL);
            hops.Add("GET submit status=" + submitResp.StatusCode + " final=" + submitResp.FinalUrl + " bytes=" + submitResp.Bytes);

            // 3) poll hidden endpoint
            string hiddenUrl = BuildHiddenUrl(date, report, l, w, h, sorts);

            string finalHiddenPageHtml = null;
            string finalDecodedHtml = null;
            string lastHiddenHtml = null;

            for (int i = 1; i <= maxPolls; i++)
            {
                string pollUrl = hiddenUrl + "&_ts=" + DateTime.UtcNow.Ticks.ToString();

                HttpResponseInfo poll = HttpGetInfo(pollUrl, cookies, BASE_URL);
                lastHiddenHtml = poll.Body ?? "";

                bool hasEncoded = ContainsUnescapePayload(lastHiddenHtml);
                hops.Add("POLL " + i + " status=" + poll.StatusCode + " bytes=" + poll.Bytes + " hasUnescape=" + hasEncoded);

                if (hasEncoded)
                {
                    string decoded = ExtractAndDecodeUnescapePayload(lastHiddenHtml);

                    if (!string.IsNullOrEmpty(decoded) &&
                        (decoded.IndexOf("ATM Dimensional Statistics", StringComparison.OrdinalIgnoreCase) >= 0 ||
                         decoded.IndexOf("Detailed CSV", StringComparison.OrdinalIgnoreCase) >= 0 ||
                         decoded.IndexOf("sizeDisplayData", StringComparison.OrdinalIgnoreCase) >= 0))
                    {
                        finalHiddenPageHtml = lastHiddenHtml;
                        finalDecodedHtml = decoded;
                        break;
                    }
                }

                System.Threading.Thread.Sleep(delayMs);
            }

            // -----------------------------
            // Parse
            // -----------------------------
            string reportText = HtmlToText(finalDecodedHtml ?? "");
            string textPreview = reportText.Substring(0, Math.Min(reportText.Length, 2000));
            object parsed = SizeReportParserView.Parse(reportText, finalDecodedHtml ?? "");

            // -----------------------------
            // Build detailed table (shared for CSV + VIEW)
            // -----------------------------
            object detailedObj = SizeReportParserView.ParseDetailedTableFromHtml(finalDecodedHtml ?? "");

            var serializer = new JavaScriptSerializer();
            var detailedJson = serializer.Serialize(detailedObj);
            var detailedDict = serializer.Deserialize<Dictionary<string, object>>(detailedJson);

            bool found = detailedDict.ContainsKey("found") &&
                         (detailedDict["found"] is bool) &&
                         (bool)detailedDict["found"];

            // columns + rows (serializer might use object[] or ArrayList)
            List<string> columns = new List<string>();
            object[] rowsObj = new object[0];

            if (found)
            {
                object colsRaw = detailedDict.ContainsKey("columns") ? detailedDict["columns"] : null;
                object rowsRaw = detailedDict.ContainsKey("rows") ? detailedDict["rows"] : null;

                object[] colsObj = colsRaw as object[];
                if (colsObj == null && colsRaw is System.Collections.ArrayList)
                    colsObj = ((System.Collections.ArrayList)colsRaw).ToArray();
                if (colsObj == null) colsObj = new object[0];

                rowsObj = rowsRaw as object[];
                if (rowsObj == null && rowsRaw is System.Collections.ArrayList)
                    rowsObj = ((System.Collections.ArrayList)rowsRaw).ToArray();
                if (rowsObj == null) rowsObj = new object[0];

                columns = colsObj.Select(c => (c ?? "").ToString()).ToList();
            }

            // -----------------------------
            // VIEW ONLY (HTML) to verify
            // -----------------------------
            if (viewOnly)
            {
                context.Response.Clear();
                context.Response.ContentType = "text/html";
                context.Response.ContentEncoding = Encoding.UTF8;

                string title = "Size Report Preview";
                context.Response.Write(BuildViewHtml(
                    title,
                    date, report, l, w, h, sorts,
                    found, columns, rowsObj,
                    hops
                ));

                context.Response.Flush();
                return;
            }

            // -----------------------------
            // CSV Export (Excel opens this)
            // -----------------------------
            if (exportCsv)
            {
                if (!found)
                    throw new Exception("No detailed table found to export.");

                // File name
                string safeDate = (date ?? "").Replace(":", "-").Replace("/", "-");
                string fileName = "size_report_" + report + "_" + safeDate + ".csv";

                context.Response.Clear();
                context.Response.ContentType = "text/csv";
                context.Response.ContentEncoding = Encoding.UTF8;
                context.Response.AddHeader("Content-Disposition", "attachment; filename=" + fileName);

                using (var sw = new StreamWriter(context.Response.OutputStream, Encoding.UTF8))
                {
                    // Header
                    sw.WriteLine(string.Join(",", columns.Select(Csv)));

                    // Rows
                    foreach (object ro in rowsObj)
                    {
                        var r = ro as Dictionary<string, object>;
                        if (r == null) continue;

                        var line = new List<string>();
                        foreach (var col in columns)
                        {
                            object cellObj;
                            string val = (r.TryGetValue(col, out cellObj) && cellObj != null) ? cellObj.ToString() : "";
                            line.Add(Csv(val));
                        }
                        sw.WriteLine(string.Join(",", line));
                    }
                }

                context.Response.Flush();
                return;
            }

            // -----------------------------
            // JSON Response (existing)
            // -----------------------------
            string rawPreviewSrc = (finalHiddenPageHtml ?? lastHiddenHtml ?? "");
            string decodedPreviewSrc = (finalDecodedHtml ?? "");

            context.Response.ContentType = "application/json";
            context.Response.ContentEncoding = Encoding.UTF8;

            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                page = "size_report",
                fetchedAtUtc = DateTime.UtcNow.ToString("o"),
                request = new
                {
                    baseUrl = BASE_URL,
                    submitGetUrl = submitUrl,
                    hiddenUrl = hiddenUrl,
                    report = report,
                    date = date,
                    l = l,
                    w = w,
                    h = h,
                    sorts = sorts,
                    maxPolls = maxPolls,
                    delayMs = delayMs,
                    format = format
                },
                hops = hops,
                hiddenRawPreview = rawPreviewSrc.Substring(0, Math.Min(rawPreviewSrc.Length, 1200)),
                decodedHtmlPreview = decodedPreviewSrc.Substring(0, Math.Min(decodedPreviewSrc.Length, 1200)),
                textPreview = textPreview,
                parsed = parsed
            }));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.ContentType = "application/json";
            context.Response.ContentEncoding = Encoding.UTF8;

            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "size_report_json failed",
                message = ex.Message,
                detail = ex.ToString(),
                utc = DateTime.UtcNow.ToString("o")
            }));
        }
    }

    // -----------------------------
    // VIEW HTML builder
    // -----------------------------
    private static string BuildViewHtml(
        string title,
        string date, string report, string l, string w, string h, List<string> sorts,
        bool found,
        List<string> columns,
        object[] rowsObj,
        List<string> hops)
    {
        Func<string, string> enc = s => HttpUtility.HtmlEncode(s ?? "");

        var sb = new StringBuilder();
        sb.Append("<!doctype html><html><head><meta charset='utf-8'/>");
        sb.Append("<meta name='viewport' content='width=device-width, initial-scale=1'/>");
        sb.Append("<title>").Append(enc(title)).Append("</title>");
        sb.Append("<style>");
        sb.Append("body{font-family:Segoe UI,Arial,sans-serif;margin:16px;}");
        sb.Append(".meta{margin-bottom:12px;padding:10px;border:1px solid #ddd;border-radius:8px;}");
        sb.Append("table{border-collapse:collapse;width:100%;}");
        sb.Append("th,td{border:1px solid #ddd;padding:6px 8px;font-size:13px;}");
        sb.Append("th{background:#f5f5f5;position:sticky;top:0;}");
        sb.Append(".warn{color:#b00;font-weight:600;}");
        sb.Append(".small{color:#666;font-size:12px;}");
        sb.Append("</style></head><body>");

        sb.Append("<h2>").Append(enc(title)).Append("</h2>");

        sb.Append("<div class='meta'>");
        sb.Append("<div><b>Report:</b> ").Append(enc(report)).Append("</div>");
        sb.Append("<div><b>Date:</b> ").Append(enc(date)).Append("</div>");
        sb.Append("<div><b>Dims:</b> ").Append(enc(l)).Append(" x ").Append(enc(w)).Append(" x ").Append(enc(h)).Append("</div>");
        sb.Append("<div><b>Sorts:</b> ").Append(enc(string.Join(",", sorts ?? new List<string>()))).Append("</div>");
        sb.Append("<div class='small'><b>View URL:</b> format=view (this page) | format=csv (download)</div>");
        sb.Append("</div>");

        if (!found)
        {
            sb.Append("<div class='warn'>No detailed table found in decoded HTML.</div>");
        }
        else
        {
            sb.Append("<div class='small'>Rows: ").Append(rowsObj != null ? rowsObj.Length.ToString() : "0").Append("</div>");
            sb.Append("<div style='overflow:auto; max-height:70vh; border:1px solid #ddd; border-radius:8px;'>");
            sb.Append("<table><thead><tr>");
            foreach (var c in (columns ?? new List<string>()))
                sb.Append("<th>").Append(enc(c)).Append("</th>");
            sb.Append("</tr></thead><tbody>");

            foreach (object ro in (rowsObj ?? new object[0]))
            {
                var r = ro as Dictionary<string, object>;
                if (r == null) continue;

                sb.Append("<tr>");
                foreach (var col in columns)
                {
                    object cellObj;
                    string val = (r.TryGetValue(col, out cellObj) && cellObj != null) ? cellObj.ToString() : "";
                    sb.Append("<td>").Append(enc(val)).Append("</td>");
                }
                sb.Append("</tr>");
            }

            sb.Append("</tbody></table></div>");
        }

        sb.Append("<h3>Hops</h3><ul>");
        foreach (var hop in (hops ?? new List<string>()))
            sb.Append("<li class='small'>").Append(enc(hop)).Append("</li>");
        sb.Append("</ul>");

        sb.Append("</body></html>");
        return sb.ToString();
    }

    private static string Csv(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        s = s.Replace("\"", "\"\"");
        if (s.IndexOf(",") >= 0 || s.IndexOf("\"") >= 0 || s.IndexOf("\n") >= 0 || s.IndexOf("\r") >= 0)
            return "\"" + s + "\"";
        return s;
    }

    private static int ParseIntOrDefault(string s, int def)
    {
        int v;
        return int.TryParse((s ?? "").Trim(), out v) ? v : def;
    }

    // -----------------------------
    // URL builders
    // -----------------------------
    private static string BuildSubmitUrl(string date, string report, string l, string w, string h, List<string> sorts)
    {
        var sb = new StringBuilder();
        sb.Append(BASE_URL).Append("?");

        sb.Append("date=").Append(HttpUtility.UrlEncode(date));
        sb.Append("&report=").Append(HttpUtility.UrlEncode(report));
        sb.Append("&l=").Append(HttpUtility.UrlEncode(l));
        sb.Append("&w=").Append(HttpUtility.UrlEncode(w));
        sb.Append("&h=").Append(HttpUtility.UrlEncode(h));

        foreach (var s in sorts)
            sb.Append("&sort%5B%5D=").Append(HttpUtility.UrlEncode(s));

        sb.Append("&btnSubmit=").Append(HttpUtility.UrlEncode("Run"));
        sb.Append("&submit=1");

        return sb.ToString();
    }

    private static string BuildHiddenUrl(string date, string report, string l, string w, string h, List<string> sorts)
    {
        var sb = new StringBuilder();
        sb.Append(HIDDEN_URL).Append("?");

        sb.Append("date=").Append(HttpUtility.UrlEncode(date));
        sb.Append("&report=").Append(HttpUtility.UrlEncode(report));
        sb.Append("&l=").Append(HttpUtility.UrlEncode(l));
        sb.Append("&w=").Append(HttpUtility.UrlEncode(w));
        sb.Append("&h=").Append(HttpUtility.UrlEncode(h));

        sb.Append("&btnSubmit=");

        foreach (var s in sorts)
            sb.Append("&sort%5B%5D=").Append(HttpUtility.UrlEncode(s));

        sb.Append("&submit=1");

        return sb.ToString();
    }

    // -----------------------------
    // HTTP
    // -----------------------------
    private class HttpResponseInfo
    {
        public int StatusCode;
        public string FinalUrl;
        public string Body;
        public int Bytes;
    }

    private static HttpResponseInfo HttpGetInfo(string url, CookieContainer cookies, string referer)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = 30000;
        req.UserAgent = "ATM-SizeReport-Proxy/1.0";
        req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
        req.AllowAutoRedirect = true;
        req.CookieContainer = cookies;
        if (!string.IsNullOrEmpty(referer)) req.Referer = referer;

        using (var resp = (HttpWebResponse)req.GetResponse())
        using (var stream = resp.GetResponseStream())
        using (var ms = new MemoryStream())
        {
            stream.CopyTo(ms);
            byte[] bytes = ms.ToArray();

            string body = Encoding.UTF8.GetString(bytes);

            return new HttpResponseInfo
            {
                StatusCode = (int)resp.StatusCode,
                FinalUrl = resp.ResponseUri.ToString(),
                Body = body,
                Bytes = bytes.Length
            };
        }
    }

    // -----------------------------
    // Hidden payload decode
    // -----------------------------
    private static bool ContainsUnescapePayload(string html)
    {
        if (string.IsNullOrEmpty(html)) return false;
        return Regex.IsMatch(html, @"unescape\(\s*'[^']+'\s*\)", RegexOptions.IgnoreCase);
    }

    private static string ExtractAndDecodeUnescapePayload(string html)
    {
        if (string.IsNullOrEmpty(html)) return null;

        Match m = Regex.Match(html, @"unescape\(\s*'(?<p>[^']+)'\s*\)", RegexOptions.IgnoreCase);
        if (!m.Success) return null;

        string payload = m.Groups["p"].Value;
        return Uri.UnescapeDataString(payload);
    }

    // -----------------------------
    // HTML -> TEXT
    // -----------------------------
    private static string HtmlToText(string html)
    {
        if (html == null) html = "";

        html = Regex.Replace(html, @"(<br\s*/?>)", "\n", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"(</p\s*>)", "\n", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"(</tr\s*>)", "\n", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"(</td\s*>)", "\t", RegexOptions.IgnoreCase);

        html = Regex.Replace(html, @"<script[\s\S]*?</script>", "", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"<style[\s\S]*?</style>", "", RegexOptions.IgnoreCase);

        html = Regex.Replace(html, "<[^>]+>", "");
        html = WebUtility.HtmlDecode(html);

        html = Regex.Replace(html, @"\r", "");
        html = Regex.Replace(html, @"[ \t]+\n", "\n");
        html = Regex.Replace(html, @"\n{3,}", "\n\n");
        return html.Trim();
    }

    public bool IsReusable { get { return true; } }
}

static class SizeReportParserView
{
    public static object Parse(string text, string decodedHtml)
    {
        string title = FirstMatch(text, @"^\s*(Size Report)\s*$", RegexOptions.Multiline) ?? "Size Report";
        string statsLine = FirstMatch(text, @"ATM Dimensional Statistics for\s*(.+)", RegexOptions.IgnoreCase);
        string forLine = FirstMatch(text, @"For packages dimensioned\s*(.+)", RegexOptions.IgnoreCase);

        var sortBlocks = ParseSortBlocks(text);
        var detailed = ParseDetailedTableFromHtml(decodedHtml);

        return new
        {
            title = title,
            statsLine = statsLine,
            forLine = forLine,
            sorts = sortBlocks,
            detailed = detailed
        };
    }

    private static List<object> ParseSortBlocks(string text)
    {
        var list = new List<object>();

        var rx = new Regex(
            @"(?<name>Sunrise|Daysort|Night|Twilight|Test)\s+Sort\s*\n" +
            @"(?<time>.+?)\s*\n" +
            @"(?<pct>[\d\.]+% of sort)\s*\n" +
            @"(?<pkgs>[\d,]+)\s+pkgs\s*\n" +
            @"(?<total>[\d,]+)\s+total pkgs",
            RegexOptions.IgnoreCase);

        foreach (Match m in rx.Matches(text ?? ""))
        {
            list.Add(new
            {
                name = m.Groups["name"].Value,
                timeWindow = m.Groups["time"].Value.Trim(),
                percentOfSort = m.Groups["pct"].Value.Trim(),
                pkgs = m.Groups["pkgs"].Value.Trim(),
                totalPkgs = m.Groups["total"].Value.Trim()
            });
        }

        return list;
    }

    public static object ParseDetailedTableFromHtml(string decodedHtml)
    {
        if (string.IsNullOrWhiteSpace(decodedHtml))
            return new { found = false };

        var tableMatch = Regex.Match(
            decodedHtml,
            @"<table[^>]*class\s*=\s*""[^""]*sizeDisplayData[^""]*""[^>]*>(?<t>[\s\S]*?)</table>",
            RegexOptions.IgnoreCase
        );

        if (!tableMatch.Success)
            return new { found = false };

        string tableHtml = tableMatch.Groups["t"].Value;

        var rowMatches = Regex.Matches(tableHtml, @"<tr[^>]*>(?<r>[\s\S]*?)</tr>", RegexOptions.IgnoreCase);
        if (rowMatches.Count == 0)
            return new { found = true, columns = new string[0], rows = new object[0] };

        Func<string, string> strip = (s) =>
        {
            s = Regex.Replace(s ?? "", @"<br\s*/?>", " ", RegexOptions.IgnoreCase);
            s = Regex.Replace(s ?? "", @"<script[\s\S]*?</script>", "", RegexOptions.IgnoreCase);
            s = Regex.Replace(s ?? "", @"<style[\s\S]*?</style>", "", RegexOptions.IgnoreCase);
            s = Regex.Replace(s ?? "", @"<[^>]+>", "");
            s = WebUtility.HtmlDecode(s);
            s = Regex.Replace(s.Trim(), @"\s+", " ");
            return s;
        };

        var headerCells = Regex.Matches(rowMatches[0].Groups["r"].Value, @"<th[^>]*>(?<c>[\s\S]*?)</th>", RegexOptions.IgnoreCase);
        var columns = new List<string>();
        foreach (Match c in headerCells)
        {
            columns.Add(strip(c.Groups["c"].Value));
        }

        var rows = new List<Dictionary<string, string>>();
        for (int i = 1; i < rowMatches.Count; i++)
        {
            var cellMatches = Regex.Matches(rowMatches[i].Groups["r"].Value, @"<t[dh][^>]*>(?<c>[\s\S]*?)</t[dh]>", RegexOptions.IgnoreCase);
            if (cellMatches.Count == 0) continue;

            var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            int n = Math.Min(columns.Count, cellMatches.Count);
            for (int j = 0; j < n; j++)
            {
                dict[columns[j]] = strip(cellMatches[j].Groups["c"].Value);
            }

            bool any = false;
            foreach (var kv in dict)
            {
                if (!string.IsNullOrWhiteSpace(kv.Value)) { any = true; break; }
            }
            if (!any) continue;

            rows.Add(dict);
        }

        return new
        {
            found = true,
            columns = columns,
            rows = rows
        };
    }

    private static string FirstMatch(string text, string pattern, RegexOptions opts)
    {
        var m = Regex.Match(text ?? "", pattern, opts);
        if (!m.Success) return null;
        return (m.Groups.Count > 1 ? m.Groups[1].Value : m.Value).Trim();
    }
}
