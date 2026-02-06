<%@ WebHandler Language="C#" Class="SizeReportJsonHandler2" %>

using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// Original sizeReportJsonHandler - now delegates to SizeReportFetcher (App_Code).
/// Maintains full backwards compatibility with existing URL parameters.
/// </summary>
public class SizeReportJsonHandler2 : IHttpHandler
{
    private static readonly object _logLock = new object();

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;

        try
        {
            // Read inputs (same as before)
            string date = (context.Request["date"] ?? SizeReportFetcher.GetTodayCentral_yyyyMMdd()).Trim();

            string report = (context.Request["report"] ?? "small").Trim().ToLowerInvariant();
            if (report != "small" && report != "large") report = "small";

            string l = (context.Request["l"] ?? "16").Trim();
            string w = (context.Request["w"] ?? "16").Trim();
            string h = (context.Request["h"] ?? "7").Trim();

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

            int maxPolls = ParseIntOrDefault(context.Request["maxPolls"], 25);
            int delayMs = ParseIntOrDefault(context.Request["delayMs"], 1200);

            bool log = (context.Request["log"] ?? "").Trim() == "1";
            string logPath = (context.Request["logPath"] ?? "").Trim();

            // Delegate to shared fetcher
            var result = SizeReportFetcher.FetchAndParse(date, report, l, w, h, sorts, maxPolls, delayMs);

            // Optional CSV logging (same as original)
            string logFolderUsed = null;
            bool logAppended = false;
            string logError = null;
            List<string> logFilesTouched = new List<string>();

            if (log)
            {
                try
                {
                    logFolderUsed = ResolveLogFolder(context, logPath);
                    logFilesTouched = AppendPerSortCsv(logFolderUsed, date, report, l, w, h, sorts, result.Parsed);
                    logAppended = true;
                }
                catch (Exception lex)
                {
                    logError = lex.ToString();
                }
            }

            // Build response (same structure as original)
            string submitUrl = SizeReportFetcher.BuildSubmitUrl(date, report, l, w, h, sorts);
            string hiddenUrl = SizeReportFetcher.BuildHiddenUrl(date, report, l, w, h, sorts);

            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                page = "size_report",
                fetchedAtUtc = result.FetchedAtUtc.ToString("o"),
                request = new
                {
                    baseUrl = "http://10.66.225.108/atm/size_report.php",
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
                    log = log,
                    logFolder = logFolderUsed,
                    logFilesTouched = logFilesTouched,
                    logAppended = logAppended,
                    logError = logError
                },
                hops = result.Hops,
                hiddenRawPreview = "",
                decodedHtmlPreview = (result.DecodedHtml ?? "").Substring(0, Math.Min((result.DecodedHtml ?? "").Length, 1200)),
                textPreview = "",
                parsed = result.Parsed
            }));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "size_report_json failed",
                message = ex.Message,
                detail = ex.ToString(),
                utc = DateTime.UtcNow.ToString("o")
            }));
        }
    }

    private static int ParseIntOrDefault(string s, int def)
    {
        int v;
        return int.TryParse((s ?? "").Trim(), out v) ? v : def;
    }

    // --- CSV logging (kept here for backwards compat, uses shared SizeReportFetcher helpers) ---

    private static string ResolveLogFolder(HttpContext context, string overrideFolder)
    {
        string folder;
        if (!string.IsNullOrWhiteSpace(overrideFolder))
            folder = overrideFolder;
        else
            folder = context.Server.MapPath("~/App_Data");

        if (!Directory.Exists(folder)) Directory.CreateDirectory(folder);
        return folder;
    }

    private static List<string> AppendPerSortCsv(string folder, string date, string report, string l, string w, string h, List<string> sorts, SizeReportParsed parsed)
    {
        var touched = new List<string>();

        string fetchedAtUtc = DateTime.UtcNow.ToString("o");
        string sortsJoined = string.Join("|", sorts ?? new List<string>());

        var totals = SizeReportFetcher.GetDetailedTotalsBySort(parsed);

        if (totals == null || totals.Count == 0)
            return touched;

        foreach (var kv in totals)
        {
            string sortCode = kv.Key;
            string pkgsRaw = (kv.Value ?? "").Trim();

            if (pkgsRaw.Equals("no data", StringComparison.OrdinalIgnoreCase)) pkgsRaw = "0";

            int pkgsInt = 0;
            int.TryParse(pkgsRaw.Replace(",", ""), out pkgsInt);

            if (pkgsInt <= 0) continue;

            string csvPath = Path.Combine(folder, "size_report_" + sortCode + ".csv");
            bool fileExists = File.Exists(csvPath);

            lock (_logLock)
            {
                using (var fs = new FileStream(csvPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read))
                {
                    fs.Seek(0, SeekOrigin.End);
                    using (var sw = new StreamWriter(fs, Encoding.UTF8))
                    {
                        if (!fileExists || fs.Length == 0)
                        {
                            sw.WriteLine(string.Join(",",
                                "fetchedAtUtc","date","sort","report","l","w","h","requestSorts",
                                "pkgs","statsLine","forLine","totalsOverall"
                            ));
                        }

                        sw.WriteLine(string.Join(",",
                            Csv(fetchedAtUtc),
                            Csv(date),
                            Csv(sortCode),
                            Csv(report),
                            Csv(l),
                            Csv(w),
                            Csv(h),
                            Csv(sortsJoined),
                            Csv(pkgsRaw),
                            Csv(parsed?.StatsLine ?? ""),
                            Csv(parsed?.ForLine ?? ""),
                            Csv(parsed?.DetailedTotalsOverall ?? "")
                        ));
                    }
                }
            }

            touched.Add(csvPath);
        }

        return touched;
    }

    private static string Csv(string s)
    {
        s = s ?? "";
        s = s.Replace("\"", "\"\"");
        return "\"" + s + "\"";
    }

    public bool IsReusable { get { return true; } }
}
