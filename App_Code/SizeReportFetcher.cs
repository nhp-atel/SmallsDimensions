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

            var cookies = new CookieContainer();

            // 1) establish session
            HttpResponseInfo warm = HttpGetInfo(BASE_URL, cookies, null);
            result.Hops.Add("GET form status=" + warm.StatusCode + " final=" + warm.FinalUrl + " bytes=" + warm.Bytes);

            // 2) trigger generation (form uses method=get)
            string submitUrl = BuildSubmitUrl(date, report, l, w, h, sorts);
            HttpResponseInfo submitResp = HttpGetInfo(submitUrl, cookies, BASE_URL);
            result.Hops.Add("GET submit status=" + submitResp.StatusCode + " final=" + submitResp.FinalUrl + " bytes=" + submitResp.Bytes);

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
                result.Hops.Add("POLL " + i + " status=" + poll.StatusCode + " bytes=" + poll.Bytes + " hasUnescape=" + hasEncoded);

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

            // Parse
            string reportText = HtmlToText(finalDecodedHtml ?? "");
            result.Parsed = SizeReportParser.Parse(reportText, finalDecodedHtml ?? "");
            result.DecodedHtml = finalDecodedHtml;
            result.Success = (result.Parsed != null && result.Parsed.DetailedFound);
        }
        catch (Exception ex)
        {
            result.Error = ex.Message;
            result.Success = false;
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
        return Regex.IsMatch(html, @"unescape\(\s*(['""])[\s\S]*?\1\s*\)", RegexOptions.IgnoreCase);
    }

    public static string ExtractAndDecodeUnescapePayload(string html)
    {
        if (string.IsNullOrEmpty(html)) return null;

        Match m = Regex.Match(html, @"unescape\(\s*(?<q>['""])(?<p>[\s\S]*?)\k<q>\s*\)", RegexOptions.IgnoreCase);
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

        if (!string.IsNullOrEmpty(firstCol))
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
            if (!string.IsNullOrEmpty(firstCol))
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
            return result;

        var tableMatch = Regex.Match(
            decodedHtml,
            @"<table[^>]*class\s*=\s*""[^""]*sizeDisplayData[^""]*""[^>]*>(?<t>[\s\S]*?)</table>",
            RegexOptions.IgnoreCase
        );

        if (!tableMatch.Success)
            return result;

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

        var headerCells = Regex.Matches(rowMatches[0].Groups["r"].Value, @"<th[^>]*>(?<c>[\s\S]*?)</th>", RegexOptions.IgnoreCase);
        foreach (Match c in headerCells)
            result.Columns.Add(strip(c.Groups["c"].Value));

        for (int i = 1; i < rowMatches.Count; i++)
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

        return result;
    }

    private static string FirstMatch(string text, string pattern, RegexOptions opts)
    {
        var m = Regex.Match(text ?? "", pattern, opts);
        if (!m.Success) return null;
        return (m.Groups.Count > 1 ? m.Groups[1].Value : m.Value).Trim();
    }
}
