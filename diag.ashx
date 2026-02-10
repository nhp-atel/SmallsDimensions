<%@ WebHandler Language="C#" Class="DiagHandler" %>

using System;
using System.IO;
using System.Text;
using System.Net;
using System.Web;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using System.Text.RegularExpressions;

public class DiagHandler : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;
        context.Response.AddHeader("Cache-Control", "no-cache, no-store");

        var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        string appDataPath = StoragePathHelper.Resolve(context.Server.MapPath("~/App_Data"));

        try
        {
            var config = SchedulerEngine.LoadConfig(appDataPath);

            string date = context.Request["date"] ?? SizeReportFetcher.GetTodayCentral_yyyyMMdd();
            string report = context.Request["report"] ?? config.Report ?? "small";
            string l = context.Request["l"] ?? config.L ?? "16";
            string w = context.Request["w"] ?? config.W ?? "16";
            string h = context.Request["h"] ?? config.H ?? "7";
            var sorts = config.Sorts ?? new List<string> { "ALL" };
            int maxPolls = 5; // fewer polls for diagnostics

            var result = new Dictionary<string, object>();
            result["timestamp"] = DateTime.UtcNow.ToString("o");
            result["date"] = date;
            result["report"] = report;
            result["sorts"] = sorts;

            var cookies = new CookieContainer();
            var steps = new List<Dictionary<string, object>>();

            // Step 1: Warm-up
            var step1 = new Dictionary<string, object>();
            step1["step"] = "1-warmup";
            try
            {
                var warm = SizeReportFetcher.HttpGetInfo("http://10.66.225.108/atm/size_report.php", cookies, null);
                step1["statusCode"] = warm.StatusCode;
                step1["bytes"] = warm.Bytes;
                step1["finalUrl"] = warm.FinalUrl;
                step1["bodyPreview"] = Preview(warm.Body, 2000);
                step1["success"] = true;
            }
            catch (Exception ex)
            {
                step1["success"] = false;
                step1["error"] = ex.Message;
            }
            steps.Add(step1);

            // Step 2: Submit
            var step2 = new Dictionary<string, object>();
            step2["step"] = "2-submit";
            string submitBody = null;
            try
            {
                string submitUrl = SizeReportFetcher.BuildSubmitUrl(date, report, l, w, h, sorts);
                step2["url"] = submitUrl;
                var submitResp = SizeReportFetcher.HttpGetInfo(submitUrl, cookies, "http://10.66.225.108/atm/size_report.php");
                submitBody = submitResp.Body ?? "";
                step2["statusCode"] = submitResp.StatusCode;
                step2["bytes"] = submitResp.Bytes;
                step2["finalUrl"] = submitResp.FinalUrl;
                step2["hasUnescape"] = SizeReportFetcher.ContainsUnescapePayload(submitBody);
                step2["hasKeywords"] = SizeReportFetcher.ContainsReportKeywords(submitBody);
                step2["bodyPreview"] = Preview(submitBody, 2000);
                step2["success"] = true;
            }
            catch (Exception ex)
            {
                step2["success"] = false;
                step2["error"] = ex.Message;
            }
            steps.Add(step2);

            // Step 3: Poll hidden endpoint
            string hiddenUrl = SizeReportFetcher.BuildHiddenUrl(date, report, l, w, h, sorts);
            var polls = new List<Dictionary<string, object>>();
            string lastHiddenBody = null;
            bool foundPayload = false;
            string decodedPreview = null;

            for (int i = 1; i <= maxPolls; i++)
            {
                var poll = new Dictionary<string, object>();
                poll["pollNumber"] = i;
                try
                {
                    string pollUrl = hiddenUrl + "&_ts=" + DateTime.UtcNow.Ticks.ToString();
                    var pollResp = SizeReportFetcher.HttpGetInfo(pollUrl, cookies, "http://10.66.225.108/atm/size_report.php");
                    lastHiddenBody = pollResp.Body ?? "";

                    bool hasUnescape = SizeReportFetcher.ContainsUnescapePayload(lastHiddenBody);
                    bool hasKeywords = SizeReportFetcher.ContainsReportKeywords(lastHiddenBody);

                    poll["statusCode"] = pollResp.StatusCode;
                    poll["bytes"] = pollResp.Bytes;
                    poll["hasUnescape"] = hasUnescape;
                    poll["hasKeywords"] = hasKeywords;
                    poll["bodyPreview"] = Preview(lastHiddenBody, 2000);

                    if (hasUnescape)
                    {
                        string decoded = SizeReportFetcher.ExtractAndDecodeUnescapePayload(lastHiddenBody);
                        if (!string.IsNullOrEmpty(decoded))
                        {
                            poll["decodedLength"] = decoded.Length;
                            poll["decodedHasKeywords"] = SizeReportFetcher.ContainsReportKeywords(decoded);
                            poll["decodedPreview"] = Preview(decoded, 2000);
                            decodedPreview = Preview(decoded, 2000);
                            foundPayload = true;
                        }
                    }

                    poll["success"] = true;
                }
                catch (Exception ex)
                {
                    poll["success"] = false;
                    poll["error"] = ex.Message;
                }
                polls.Add(poll);

                if (foundPayload) break;
                System.Threading.Thread.Sleep(1200);
            }

            result["steps"] = steps;
            result["polls"] = polls;
            result["pollCount"] = polls.Count;
            result["foundPayload"] = foundPayload;

            // Diagnosis
            string diagnosis;
            if (foundPayload)
            {
                diagnosis = "SUCCESS: unescape/decodeURI payload found and decoded successfully in poll " + polls.Count;
            }
            else
            {
                bool submitHasKeywords = submitBody != null && SizeReportFetcher.ContainsReportKeywords(submitBody);
                bool hiddenHasKeywords = lastHiddenBody != null && SizeReportFetcher.ContainsReportKeywords(lastHiddenBody);

                if (submitHasKeywords)
                {
                    diagnosis = "FALLBACK AVAILABLE: unescape not found but direct HTML table detected in SUBMIT response. The fallback logic will use the submit response body.";
                }
                else if (hiddenHasKeywords)
                {
                    diagnosis = "FALLBACK AVAILABLE: unescape not found but direct HTML table detected in hidden poll response. The fallback logic will use the raw hidden response.";
                }
                else
                {
                    diagnosis = "NO DATA FOUND: Neither unescape payload nor direct HTML data found in any response after " + maxPolls + " polls. Check bodyPreview fields to see what the ATM server is returning.";
                }

                result["submitHasKeywords"] = submitHasKeywords;
                result["hiddenHasKeywords"] = hiddenHasKeywords;
            }

            result["diagnosis"] = diagnosis;

            // Check log file
            string logPath = Path.Combine(appDataPath, "fetch_debug.log");
            if (File.Exists(logPath))
            {
                var fi = new FileInfo(logPath);
                result["logFileExists"] = true;
                result["logFileBytes"] = fi.Length;
            }
            else
            {
                result["logFileExists"] = false;
            }

            context.Response.Write(json.Serialize(result));
        }
        catch (Exception ex)
        {
            context.Response.Write(json.Serialize(new { error = ex.Message, stackTrace = ex.StackTrace }));
        }
    }

    private string Preview(string s, int max)
    {
        if (string.IsNullOrEmpty(s)) return "(empty)";
        if (s.Length <= max) return s;
        return s.Substring(0, max) + "... [truncated, total " + s.Length + " chars]";
    }

    public bool IsReusable { get { return false; } }
}
