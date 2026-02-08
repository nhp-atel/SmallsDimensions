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
