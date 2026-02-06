<%@ WebHandler Language="C#" Class="SchedulerHandler" %>

using System;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

public class SchedulerHandler : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;
        context.Response.AddHeader("Cache-Control", "no-cache, no-store");

        var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        string appDataPath = context.Server.MapPath("~/App_Data");

        try
        {
            string action = (context.Request["action"] ?? "status").Trim().ToLowerInvariant();

            switch (action)
            {
                case "status":
                    context.Response.Write(json.Serialize(SchedulerEngine.GetStatus()));
                    break;

                case "start":
                    var config = SchedulerEngine.LoadConfig(appDataPath);
                    SchedulerEngine.Start(config, appDataPath);
                    context.Response.Write(json.Serialize(new { ok = true, message = "Scheduler started", status = SchedulerEngine.GetStatus() }));
                    break;

                case "stop":
                    SchedulerEngine.Stop();
                    context.Response.Write(json.Serialize(new { ok = true, message = "Scheduler stopped", status = SchedulerEngine.GetStatus() }));
                    break;

                case "runnow":
                    if (!SchedulerEngine.IsRunning)
                    {
                        // Start engine temporarily with saved config so it has appDataPath
                        var cfg = SchedulerEngine.LoadConfig(appDataPath);
                        SchedulerEngine.Start(cfg, appDataPath);
                    }
                    SchedulerEngine.RunNow();
                    context.Response.Write(json.Serialize(new { ok = true, message = "Fetch triggered", status = SchedulerEngine.GetStatus() }));
                    break;

                case "history":
                    var history = SchedulerEngine.GetHistory();
                    context.Response.Write(json.Serialize(new { history = history }));
                    break;

                default:
                    context.Response.StatusCode = 400;
                    context.Response.Write(json.Serialize(new { error = "Unknown action: " + action }));
                    break;
            }
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(json.Serialize(new { error = ex.Message, detail = ex.ToString() }));
        }
    }

    public bool IsReusable { get { return true; } }
}
