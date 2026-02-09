<%@ WebHandler Language="C#" Class="DownloadSizeReportCsv" %>

using System;
using System.IO;
using System.Web;

public class DownloadSizeReportCsv : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        // Server-side debug logging (App_Data/size_report_debug.log)
        // Safe for production if you keep the file protected and rotate it.
        void Log(string message)
        {
            try
            {
                string logPath = context.Server.MapPath("~/App_Data/size_report_debug.log");
                string line = DateTime.UtcNow.ToString("o") + " | " + message + Environment.NewLine;
                File.AppendAllText(logPath, line);
            }
            catch
            {
                // Never let logging break the request.
            }
        }

        Log("Request start. Url=" + context.Request.RawUrl +
            " Method=" + context.Request.HttpMethod +
            " IP=" + context.Request.UserHostAddress);

        // Optional: add basic protection
        // if (context.Request["key"] != "YOUR_SECRET") { context.Response.StatusCode = 403; return; }

        try
        {
            string path = context.Server.MapPath("~/App_Data/size_report_log.csv");
            Log("Resolved path: " + path);

            if (!File.Exists(path))
            {
                Log("CSV not found.");
                context.Response.StatusCode = 404;
                context.Response.Write("CSV not found.");
                return;
            }

            long size = new FileInfo(path).Length;
            Log("CSV exists. Size=" + size);

            context.Response.ContentType = "text/csv";
            context.Response.AddHeader("Content-Disposition", "attachment; filename=size_report_log.csv");
            context.Response.TransmitFile(path);

            Log("TransmitFile completed.");
        }
        catch (Exception ex)
        {
            Log("ERROR: " + ex.GetType().FullName + " Message=" + ex.Message);
            context.Response.StatusCode = 500;
            context.Response.Write("Server error. See debug log.");
        }
    }

    public bool IsReusable { get { return true; } }
}
