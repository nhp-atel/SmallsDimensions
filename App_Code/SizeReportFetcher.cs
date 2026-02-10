using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// Shared fetch+parse logic extracted from sizeReportJsonHandler.ashx.
/// Does NOT require HttpContext — can be called from scheduler or handler.
/// </summary>
public static class SizeReportFetcher
{
    private const string BASE_URL = "http://10.66.225.108/atm/size_report.php";
    private const string HIDDEN_URL = "http://10.66.225.108/atm/size_report_hidden.php";

    private static readonly object _logLock = new object();

    // --- Debug Logging ---

    public static void DebugLog(string component, string message)
    {
        try
        {
            string logDir = null;
            if (HttpContext.Current != null)
                logDir = HttpContext.Current.Server.MapPath("~/App_Data");
            else
                logDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "App_Data");

            if (!Directory.Exists(logDir))
                Directory.CreateDirectory(logDir);

            string logPath = Path.Combine(logDir, "fetch_debug.log");
            string entry = string.Format("[{0}] [{1}] {2}\n", DateTime.UtcNow.ToString("o"), component, message);

            lock (_logLock)
            {
                // Auto-rotate: if file exceeds 500KB, keep last half
                if (File.Exists(logPath))
                {
                    var fi = new FileInfo(logPath);
                    if (fi.Length > 512000)
                    {
                        string all = File.ReadAllText(logPath);
                        int mid = all.Length / 2;
                        int nl = all.IndexOf('\n', mid);
                        if (nl > 0)
                            File.WriteAllText(logPath, all.Substring(nl + 1));
                    }
                }

                File.AppendAllText(logPath, entry);
            }
        }
        catch { }
    }

    private static string Preview(string s, int max)
    {
        if (string.IsNullOrEmpty(s)) return "(empty)";
        if (s.Length <= max) return s.Replace("\n", "\\n").Replace("\r", "");
        return s.Substring(0, max).Replace("\n", "\\n").Replace("\r", "") + "...";
    }

    // --- Report keyword detection ---

    public static bool ContainsReportKeywords(string html)
    {
        if (string.IsNullOrEmpty(html)) return false;
        return html.IndexOf("ATM Dimensional Statistics", StringComparison.OrdinalIgnoreCase) >= 0
            || html.IndexOf("sizeDisplayData", StringComparison.OrdinalIgnoreCase) >= 0
            || html.IndexOf("Detailed CSV", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public static FetchResult FetchAndParse(string date, string report, string l, string w, string h, List<string> sorts, int maxPolls = 25, int delayMs = 1200)
    {
        var result = new FetchResult();
        result.FetchedAtUtc = DateTime.UtcNow;
        result.Hops = new List<string>();

        try
        {
            if (string.IsNullOrWhiteSpace(date)) date = GetTodayCentral_yyyyMMdd();
            report = (report ?? "small").Trim().ToLowerInvariant();
            if (report != "small" && report != "large") report = "small";
            l = (l ?? "16").Trim();
            w = (w ?? "16").Trim();
            h = (h ?? "7").Trim();
            if (sorts == null || sorts.Count == 0) sorts = new List<string> { "ALL" };

            DebugLog("FETCHER", string.Format("START FetchAndParse date={0} report={1} l={2} w={3} h={4} sorts={5}",
                date, report, l, w, h, string.Join(",", sorts)));

            var cookies = new CookieContainer();

            // 1) establish session
            HttpResponseInfo warm = HttpGetInfo(BASE_URL, cookies, null);
            result.Hops.Add("GET form status=" + warm.StatusCode + " final=" + warm.FinalUrl + " bytes=" + warm.Bytes);
            DebugLog("FETCHER", string.Format("WARMUP status={0} bytes={1} finalUrl={2} bodyPreview={3}",
                warm.StatusCode, warm.Bytes, warm.FinalUrl, Preview(warm.Body, 200)));

            // 2) trigger generation (form uses method=get)
            string submitUrl = BuildSubmitUrl(date, report, l, w, h, sorts);
            HttpResponseInfo submitResp = HttpGetInfo(submitUrl, cookies, BASE_URL);
            bool submitHasKeywords = ContainsReportKeywords(submitResp.Body ?? "");
            result.Hops.Add("GET submit status=" + submitResp.StatusCode + " final=" + submitResp.FinalUrl + " bytes=" + submitResp.Bytes);
            DebugLog("FETCHER", string.Format("SUBMIT status={0} bytes={1} containsKeywords={2} bodyPreview={3}",
                submitResp.StatusCode, submitResp.Bytes, submitHasKeywords, Preview(submitResp.Body, 200)));

            // 3) poll hidden endpoint until it contains the unescape payload with report HTML
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
                bool hasDirectTable = ContainsReportKeywords(lastHiddenHtml);
                result.Hops.Add("POLL " + i + " status=" + poll.StatusCode + " bytes=" + poll.Bytes +
                    " hasUnescape=" + hasEncoded + " hasDirectTable=" + hasDirectTable);
                DebugLog("FETCHER", string.Format("POLL {0}/{1} status={2} bytes={3} hasUnescape={4} hasDirectTable={5} bodyPreview={6}",
                    i, maxPolls, poll.StatusCode, poll.Bytes, hasEncoded, hasDirectTable, Preview(lastHiddenHtml, 300)));

                if (hasEncoded)
                {
                    string decoded = ExtractAndDecodeUnescapePayload(lastHiddenHtml);

                    if (!string.IsNullOrEmpty(decoded) && ContainsReportKeywords(decoded))
                    {
                        DebugLog("FETCHER", string.Format("UNESCAPE_FOUND decodedLength={0} containsKeywords={1} decodedPreview={2}",
                            decoded.Length, true, Preview(decoded, 300)));
                        finalHiddenPageHtml = lastHiddenHtml;
                        finalDecodedHtml = decoded;
                        break;
                    }
                }

                System.Threading.Thread.Sleep(delayMs);
            }

            // --- Fallback strategies (Step 2c) ---
            if (string.IsNullOrEmpty(finalDecodedHtml))
            {
                DebugLog("FETCHER", string.Format("POLL_EXHAUSTED no valid payload found in {0} polls. lastHiddenHtml bytes={1}",
                    maxPolls, (lastHiddenHtml ?? "").Length));

                // Fallback A: check submit response body for direct HTML data
                if (submitHasKeywords)
                {
                    finalDecodedHtml = submitResp.Body;
                    result.Hops.Add("FALLBACK: used submit response body (direct HTML, " + (submitResp.Body ?? "").Length + " bytes)");
                    DebugLog("FETCHER", string.Format("FALLBACK_SUBMIT using submit response as direct HTML. bytes={0}", (submitResp.Body ?? "").Length));
                }
                // Fallback B: check last hidden poll body for direct HTML data
                else if (!string.IsNullOrEmpty(lastHiddenHtml) && ContainsReportKeywords(lastHiddenHtml))
                {
                    finalDecodedHtml = lastHiddenHtml;
                    result.Hops.Add("FALLBACK: used raw hidden response (direct HTML, " + lastHiddenHtml.Length + " bytes)");
                    DebugLog("FETCHER", string.Format("FALLBACK_HIDDEN using raw hidden response as direct HTML. bytes={0}", lastHiddenHtml.Length));
                }
            }

            // Parse
            DebugLog("FETCHER", string.Format("PARSING decodedHtml is {0}",
                string.IsNullOrEmpty(finalDecodedHtml) ? "null/empty" : (finalDecodedHtml.Length + " bytes")));

            string reportText = HtmlToText(finalDecodedHtml ?? "");
            result.Parsed = SizeReportParser.Parse(reportText, finalDecodedHtml ?? "");
            result.DecodedHtml = finalDecodedHtml;
            result.Success = (result.Parsed != null && result.Parsed.DetailedFound);

            DebugLog("FETCHER", string.Format("PARSED detailedFound={0} columns={1}:{2} rows={3} sortBlocks={4} success={5}",
                result.Parsed != null ? result.Parsed.DetailedFound.ToString() : "null",
                result.Parsed != null && result.Parsed.DetailedColumns != null ? result.Parsed.DetailedColumns.Count.ToString() : "0",
                result.Parsed != null && result.Parsed.DetailedColumns != null ? string.Join(",", result.Parsed.DetailedColumns) : "",
                result.Parsed != null && result.Parsed.DetailedRows != null ? result.Parsed.DetailedRows.Count.ToString() : "0",
                result.Parsed != null && result.Parsed.SortBlocks != null ? result.Parsed.SortBlocks.Count.ToString() : "0",
                result.Success));
        }
        catch (Exception ex)
        {
            result.Error = ex.Message;
            result.Success = false;
            DebugLog("FETCHER", string.Format("ERROR {0}: {1}", ex.GetType().Name, ex.Message));
        }

        return result;
    }

    public static string GetTodayCentral_yyyyMMdd()
    {
        var tz = TimeZoneInfo.FindSystemTimeZoneById("Central Standard Time");
        var ct = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, tz);
        return ct.ToString("yyyy-MM-dd");
    }

    public static string GetNowCentralFormatted()
    {
        var tz = TimeZoneInfo.FindSystemTimeZoneById("Central Standard Time");
        var ct = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, tz);
        return ct.ToString("yyyy-MM-dd hh:mm tt");
    }

    // --- URL builders ---

    public static string BuildSubmitUrl(string date, string report, string l, string w, string h, List<string> sorts)
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

    public static string BuildHiddenUrl(string date, string report, string l, string w, string h, List<string> sorts)
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

    // --- HTTP ---

    public class HttpResponseInfo
    {
        public int StatusCode;
        public string FinalUrl;
        public string Body;
        public int Bytes;
    }

    public static HttpResponseInfo HttpGetInfo(string url, CookieContainer cookies, string referer)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = 30000;
        req.UserAgent = "ATM-SizeReport-Proxy/1.0";
        req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
        req.AllowAutoRedirect = true;
        req.CookieContainer = cookies;
        req.Proxy = null;

        if (!string.IsNullOrEmpty(referer)) req.Referer = referer;

        using (var resp = (HttpWebResponse)req.GetResponse())
        using (var stream = resp.GetResponseStream())
        using (var ms = new MemoryStream())
        {
            stream.CopyTo(ms);
            byte[] bytes = ms.ToArray();

            Encoding enc = Encoding.UTF8;
            try
            {
                if (!string.IsNullOrEmpty(resp.CharacterSet))
                    enc = Encoding.GetEncoding(resp.CharacterSet);
            }
            catch { }

            string body = enc.GetString(bytes);

            return new HttpResponseInfo
            {
                StatusCode = (int)resp.StatusCode,
                FinalUrl = resp.ResponseUri.ToString(),
                Body = body,
                Bytes = bytes.Length
            };
        }
    }

    // --- Payload decode ---

    public static bool ContainsUnescapePayload(string html)
    {
        if (string.IsNullOrEmpty(html)) return false;
        return Regex.IsMatch(html, @"(?:unescape|decodeURIComponent|decodeURI)\(\s*(['""])[\s\S]*?\1\s*\)", RegexOptions.IgnoreCase);
    }

    public static string ExtractAndDecodeUnescapePayload(string html)
    {
        if (string.IsNullOrEmpty(html)) return null;

        Match m = Regex.Match(html, @"(?:unescape|decodeURIComponent|decodeURI)\(\s*(?<q>['""])(?<p>[\s\S]*?)\k<q>\s*\)", RegexOptions.IgnoreCase);
        if (!m.Success) return null;

        string payload = m.Groups["p"].Value;
        return Uri.UnescapeDataString(payload);
    }

    // --- HTML to text ---

    public static string HtmlToText(string html)
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

    // --- Helper ---

    public static Dictionary<string, string> GetDetailedTotalsBySort(SizeReportParsed parsed)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        if (parsed == null || !parsed.DetailedFound || parsed.DetailedRows == null || parsed.DetailedRows.Count == 0)
            return map;

        string firstCol = (parsed.DetailedColumns != null && parsed.DetailedColumns.Count > 0) ? parsed.DetailedColumns[0] : "";

        Dictionary<string, string> totalsRow = null;

        // Step 3d: use firstCol != null instead of !IsNullOrEmpty so empty-string key "" still works
        if (firstCol != null)
            totalsRow = parsed.DetailedRows.FirstOrDefault(r =>
                r.ContainsKey(firstCol) && string.Equals((r[firstCol] ?? "").Trim(), "Totals", StringComparison.OrdinalIgnoreCase));

        if (totalsRow == null)
            totalsRow = parsed.DetailedRows.FirstOrDefault(r =>
                r.Values.Any(v => string.Equals((v ?? "").Trim(), "Totals", StringComparison.OrdinalIgnoreCase)));

        if (totalsRow == null || parsed.DetailedColumns == null)
            return map;

        foreach (var col in parsed.DetailedColumns)
        {
            if (string.IsNullOrWhiteSpace(col)) continue;
            if (col.Equals("Totals", StringComparison.OrdinalIgnoreCase)) continue;

            string code = null;
            if (col.StartsWith("Sunrise", StringComparison.OrdinalIgnoreCase)) code = "SUN";
            else if (col.StartsWith("Daysort", StringComparison.OrdinalIgnoreCase)) code = "DAY";
            else if (col.StartsWith("Twilight", StringComparison.OrdinalIgnoreCase)) code = "TWI";
            else if (col.StartsWith("Night", StringComparison.OrdinalIgnoreCase)) code = "NGT";

            if (code == null) continue;

            string val = totalsRow.ContainsKey(col) ? (totalsRow[col] ?? "") : "";
            map[code] = val;
        }

        return map;
    }
}

// --- Models ---

public class FetchResult
{
    public bool Success;
    public DateTime FetchedAtUtc;
    public SizeReportParsed Parsed;
    public List<string> Hops;
    public string Error;
    public string DecodedHtml;
}

public class SortBlock
{
    public string name;
    public string timeWindow;
    public string percentOfSort;
    public string pkgs;
    public string totalPkgs;
}

public class SizeReportParsed
{
    public string Title;
    public string StatsLine;
    public string ForLine;

    public List<SortBlock> SortBlocks;

    public bool DetailedFound;
    public List<string> DetailedColumns;
    public List<Dictionary<string, string>> DetailedRows;

    public string DetailedTotalsOverall;
    public string DetailedTotalsFirstSort;
}

public static class SizeReportParser
{
    public static SizeReportParsed Parse(string text, string decodedHtml)
    {
        var parsed = new SizeReportParsed();

        parsed.Title = FirstMatch(text, @"^\s*(Size Report)\s*$", RegexOptions.Multiline) ?? "Size Report";
        parsed.StatsLine = FirstMatch(text, @"ATM Dimensional Statistics for\s*(.+)", RegexOptions.IgnoreCase);
        parsed.ForLine = FirstMatch(text, @"For packages dimensioned\s*(.+)", RegexOptions.IgnoreCase);

        parsed.SortBlocks = ParseSortBlocks(text);

        var detailed = ParseDetailedTableFromHtml(decodedHtml);
        parsed.DetailedFound = detailed.Found;
        parsed.DetailedColumns = detailed.Columns;
        parsed.DetailedRows = detailed.Rows;

        if (parsed.DetailedFound && parsed.DetailedRows != null && parsed.DetailedRows.Count > 0)
        {
            var firstCol = parsed.DetailedColumns != null && parsed.DetailedColumns.Count > 0 ? parsed.DetailedColumns[0] : null;

            Dictionary<string, string> totalsRow = null;
            // Step 3d: use firstCol != null instead of !IsNullOrEmpty
            if (firstCol != null)
                totalsRow = parsed.DetailedRows.FirstOrDefault(r => r.ContainsKey(firstCol) && (r[firstCol] ?? "").Trim().Equals("Totals", StringComparison.OrdinalIgnoreCase));
            else
                totalsRow = parsed.DetailedRows.FirstOrDefault(r => r.Values.Any(v => (v ?? "").Trim().Equals("Totals", StringComparison.OrdinalIgnoreCase)));

            if (totalsRow != null && parsed.DetailedColumns != null && parsed.DetailedColumns.Count >= 2)
            {
                string firstSortCol = parsed.DetailedColumns[1];
                string overallCol = parsed.DetailedColumns[parsed.DetailedColumns.Count - 1];

                parsed.DetailedTotalsFirstSort = totalsRow.ContainsKey(firstSortCol) ? totalsRow[firstSortCol] : "";
                parsed.DetailedTotalsOverall = totalsRow.ContainsKey(overallCol) ? totalsRow[overallCol] : "";
            }
        }

        return parsed;
    }

    private static List<SortBlock> ParseSortBlocks(string text)
    {
        var list = new List<SortBlock>();

        var rx = new Regex(
            @"(?<name>Sunrise|Daysort|Night|Twilight|Test)\s+Sort\s*[\r\n]+" +
            @"(?<time>.+?)\s*[\r\n]+" +
            @"(?<pct>[\d\.]+%\s*of\s*sort)\s*[\r\n]+" +
            @"(?<pkgs>[\d,]+)\s+pkgs\s*[\r\n]+" +
            @"(?<total>[\d,]+)\s+total\s+pkgs",
            RegexOptions.IgnoreCase);

        foreach (Match m in rx.Matches(text ?? ""))
        {
            list.Add(new SortBlock
            {
                name = m.Groups["name"].Value,
                timeWindow = (m.Groups["time"].Value ?? "").Trim(),
                percentOfSort = (m.Groups["pct"].Value ?? "").Trim(),
                pkgs = (m.Groups["pkgs"].Value ?? "").Trim(),
                totalPkgs = (m.Groups["total"].Value ?? "").Trim()
            });
        }

        return list;
    }

    public class DetailedTable
    {
        public bool Found;
        public List<string> Columns = new List<string>();
        public List<Dictionary<string, string>> Rows = new List<Dictionary<string, string>>();
    }

    public static DetailedTable ParseDetailedTableFromHtml(string decodedHtml)
    {
        var result = new DetailedTable();

        if (string.IsNullOrWhiteSpace(decodedHtml))
        {
            SizeReportFetcher.DebugLog("TABLE_PARSE", "input html is null/empty");
            return result;
        }

        SizeReportFetcher.DebugLog("TABLE_PARSE", string.Format("input html bytes={0}", decodedHtml.Length));

        // Try finding table by sizeDisplayData class
        var tableMatch = Regex.Match(
            decodedHtml,
            @"<table[^>]*class\s*=\s*""[^""]*sizeDisplayData[^""]*""[^>]*>(?<t>[\s\S]*?)</table>",
            RegexOptions.IgnoreCase
        );

        bool foundByClass = tableMatch.Success;
        SizeReportFetcher.DebugLog("TABLE_PARSE", string.Format("TABLE_SEARCH sizeDisplayData class found={0}", foundByClass));

        // Step 3a: Fallback table finding — iterate all tables
        if (!tableMatch.Success)
        {
            var allTables = Regex.Matches(decodedHtml, @"<table[^>]*>(?<t>[\s\S]*?)</table>", RegexOptions.IgnoreCase);
            bool matchByContent = false;

            SizeReportFetcher.DebugLog("TABLE_PARSE", string.Format("TABLE_FALLBACK searching all tables. found={0}", allTables.Count));

            foreach (Match tbl in allTables)
            {
                string tblContent = tbl.Groups["t"].Value;
                bool hasTotals = tblContent.IndexOf("Totals", StringComparison.OrdinalIgnoreCase) >= 0;
                bool hasDimension = Regex.IsMatch(tblContent, @"P\d{2}", RegexOptions.IgnoreCase);

                if (hasTotals && hasDimension)
                {
                    tableMatch = tbl;
                    matchByContent = true;
                    break;
                }
            }

            SizeReportFetcher.DebugLog("TABLE_PARSE", string.Format("TABLE_FALLBACK Match by Totals+dimensions={0}", matchByContent));
        }

        if (!tableMatch.Success)
        {
            SizeReportFetcher.DebugLog("TABLE_PARSE", "TABLE_NOT_FOUND no matching table in HTML");
            return result;
        }

        result.Found = true;

        string tableHtml = tableMatch.Groups["t"].Value;

        var rowMatches = Regex.Matches(tableHtml, @"<tr[^>]*>(?<r>[\s\S]*?)</tr>", RegexOptions.IgnoreCase);
        if (rowMatches.Count == 0)
            return result;

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

        // Step 3b: Try <th> headers first, fallback to <td>
        var headerCells = Regex.Matches(rowMatches[0].Groups["r"].Value, @"<th[^>]*>(?<c>[\s\S]*?)</th>", RegexOptions.IgnoreCase);
        bool usedTdFallback = false;

        if (headerCells.Count == 0)
        {
            headerCells = Regex.Matches(rowMatches[0].Groups["r"].Value, @"<td[^>]*>(?<c>[\s\S]*?)</td>", RegexOptions.IgnoreCase);
            usedTdFallback = true;
        }

        foreach (Match c in headerCells)
            result.Columns.Add(strip(c.Groups["c"].Value));

        // Step 3c: Handle empty first column header
        if (result.Columns.Count > 0 && string.IsNullOrWhiteSpace(result.Columns[0]))
        {
            result.Columns[0] = "Dimension";
            SizeReportFetcher.DebugLog("TABLE_PARSE", "HEADER_EMPTY first column was empty, renamed to 'Dimension'");
        }

        SizeReportFetcher.DebugLog("TABLE_PARSE", string.Format("HEADERS <th> count={0}. Falling back to <td>={1}. Final columns=[{2}]",
            usedTdFallback ? 0 : headerCells.Count, usedTdFallback, string.Join(",", result.Columns)));

        // If headers came from <td>, data rows start at index 1; otherwise index 1 as before
        int dataStartRow = 1;

        for (int i = dataStartRow; i < rowMatches.Count; i++)
        {
            var cellMatches = Regex.Matches(rowMatches[i].Groups["r"].Value, @"<t[dh][^>]*>(?<c>[\s\S]*?)</t[dh]>", RegexOptions.IgnoreCase);
            if (cellMatches.Count == 0) continue;

            var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            int n = Math.Min(result.Columns.Count, cellMatches.Count);

            for (int j = 0; j < n; j++)
                dict[result.Columns[j]] = strip(cellMatches[j].Groups["c"].Value);

            bool any = dict.Values.Any(v => !string.IsNullOrWhiteSpace(v));
            if (!any) continue;

            result.Rows.Add(dict);
        }

        SizeReportFetcher.DebugLog("TABLE_PARSE", string.Format("ROWS extracted {0} data rows.{1}",
            result.Rows.Count,
            result.Rows.Count > 0 ? string.Format(" First row keys=[{0}] values=[{1}]",
                string.Join(",", result.Rows[0].Keys),
                string.Join(",", result.Rows[0].Values)) : ""));

        // Log Totals row search
        Dictionary<string, string> totalsRowCheck = null;
        string totalsMethod = "notfound";
        if (result.Columns.Count > 0)
        {
            string fc = result.Columns[0];
            totalsRowCheck = result.Rows.FirstOrDefault(r =>
                r.ContainsKey(fc) && (r[fc] ?? "").Trim().Equals("Totals", StringComparison.OrdinalIgnoreCase));
            if (totalsRowCheck != null) totalsMethod = "firstCol";
        }
        if (totalsRowCheck == null)
        {
            totalsRowCheck = result.Rows.FirstOrDefault(r =>
                r.Values.Any(v => (v ?? "").Trim().Equals("Totals", StringComparison.OrdinalIgnoreCase)));
            if (totalsRowCheck != null) totalsMethod = "fallback";
        }
        SizeReportFetcher.DebugLog("TABLE_PARSE", string.Format("TOTALS_ROW found={0} method={1}", totalsRowCheck != null, totalsMethod));

        return result;
    }

    private static string FirstMatch(string text, string pattern, RegexOptions opts)
    {
        var m = Regex.Match(text ?? "", pattern, opts);
        if (!m.Success) return null;
        return (m.Groups.Count > 1 ? m.Groups[1].Value : m.Value).Trim();
    }
}
