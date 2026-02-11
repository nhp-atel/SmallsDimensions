<%@ WebHandler Language="C#" Class="DownloadHandler" %>

using System;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Collections.Generic;

public class DownloadHandler : IHttpHandler
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
            string action = (context.Request["action"] ?? "").Trim().ToLowerInvariant();
            string date = (context.Request["date"] ?? "").Trim();

            if (action == "dates")
            {
                var dates = DailyDataStore.ListDates(appDataPath);
                context.Response.Write(json.Serialize(new { dates = dates }));
                return;
            }

            if (action == "debuglog")
            {
                string logPath = Path.Combine(appDataPath, "fetch_debug.log");
                if (!File.Exists(logPath))
                {
                    context.Response.Write(json.Serialize(new { content = "(log file does not exist)", lines = 0 }));
                    return;
                }
                // Read last 100 lines
                var allLines = File.ReadAllLines(logPath, Encoding.UTF8);
                int start = Math.Max(0, allLines.Length - 100);
                var tail = new string[allLines.Length - start];
                Array.Copy(allLines, start, tail, 0, tail.Length);
                context.Response.Write(json.Serialize(new {
                    content = string.Join("\n", tail),
                    lines = tail.Length,
                    totalLines = allLines.Length,
                    fileSizeKB = Math.Round((double)new FileInfo(logPath).Length / 1024, 1)
                }));
                return;
            }

            if (!string.IsNullOrEmpty(date))
            {
                // Return consolidated JSON for that date
                string dayJson = DailyDataStore.ReadDay(appDataPath, date);
                context.Response.Write(dayJson);
                return;
            }

            // Default: return today's data
            string today = SizeReportFetcher.GetTodayCentral_yyyyMMdd();
            string todayJson = DailyDataStore.ReadDay(appDataPath, today);
            context.Response.Write(todayJson);
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(json.Serialize(new { error = ex.Message, detail = ex.ToString() }));
        }
    }

    public bool IsReusable { get { return true; } }
}
