<%@ WebHandler Language="C#" Class="SchedulerConfigHandler" %>

using System;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

public class SchedulerConfigHandler : IHttpHandler
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
            if (context.Request.HttpMethod == "POST")
            {
                // Save config
                string body;
                using (var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8))
                {
                    body = reader.ReadToEnd();
                }

                var config = json.Deserialize<SchedulerConfig>(body);
                if (config == null)
                {
                    context.Response.StatusCode = 400;
                    context.Response.Write(json.Serialize(new { error = "Invalid config JSON" }));
                    return;
                }

                SchedulerEngine.SaveConfig(appDataPath, config);
                context.Response.Write(json.Serialize(new { ok = true, message = "Config saved", config = config }));
            }
            else
            {
                // GET - return current config
                var config = SchedulerEngine.CurrentConfig ?? SchedulerEngine.LoadConfig(appDataPath);
                context.Response.Write(json.Serialize(config));
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
