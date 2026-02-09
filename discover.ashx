<%@ WebHandler Language="C#" Class="DiscoverHandler" %>

using System;
using System.Net;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
using System.Collections.Generic;

public class DiscoverHandler : IHttpHandler
{
    private const string WRAPPER_URL = "http://10.66.225.108/eds/atm.php";

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.ContentEncoding = Encoding.UTF8;

        try
        {
            string wrapperHtml = HttpGet(WRAPPER_URL);
            string iframeSrc = ExtractIframeSrc(wrapperHtml);
            string iframeUrl = MakeAbsoluteUrl(WRAPPER_URL, iframeSrc);
            string iframeHtml = HttpGet(iframeUrl);

            var urls = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            // Collect src/href from script/link tags
            foreach (Match m in Regex.Matches(iframeHtml, "<script[^>]+src=[\"']([^\"']+)[\"']", RegexOptions.IgnoreCase))
                urls.Add(MakeAbsoluteUrl(iframeUrl, m.Groups[1].Value));

            foreach (Match m in Regex.Matches(iframeHtml, "<link[^>]+href=[\"']([^\"']+)[\"']", RegexOptions.IgnoreCase))
                urls.Add(MakeAbsoluteUrl(iframeUrl, m.Groups[1].Value));

            // Collect "something.php" or "/path/xyz" style strings inside the HTML
            foreach (Match m in Regex.Matches(iframeHtml, @"([A-Za-z0-9_\-/]+\.php(\?[A-Za-z0-9_\-=&%]+)?)", RegexOptions.IgnoreCase))
                urls.Add(MakeAbsoluteUrl(iframeUrl, m.Groups[1].Value));

            // Also collect likely API-ish paths
            foreach (Match m in Regex.Matches(iframeHtml, @"(\/[A-Za-z0-9_\-\/]+(\?[A-Za-z0-9_\-=&%]+)?)", RegexOptions.IgnoreCase))
            {
                var candidate = m.Groups[1].Value;
                // Keep it somewhat sane
                if (candidate.Length > 2 && candidate.Length < 120)
                    urls.Add(MakeAbsoluteUrl(iframeUrl, candidate));
            }

            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                wrapperUrl = WRAPPER_URL,
                iframeUrl = iframeUrl,
                fetchedAtUtc = DateTime.UtcNow.ToString("o"),
                iframeLength = iframeHtml.Length,
                discoveredCount = urls.Count,
                discovered = urls
            }));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new
            {
                error = "Discovery failed",
                message = ex.Message,
                utc = DateTime.UtcNow.ToString("o")
            }));
        }
    }

    private static string HttpGet(string url)
    {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.Method = "GET";
        req.Timeout = 30000;
        req.UserAgent = "RisewellAtmProxy/1.0";
        req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;

        using (var resp = (HttpWebResponse)req.GetResponse())
        using (var stream = resp.GetResponseStream())
        using (var reader = new StreamReader(stream))
            return reader.ReadToEnd();
    }

    private static string ExtractIframeSrc(string html)
    {
        var m = Regex.Match(html, "<iframe[^>]+src=[\"']([^\"']+)[\"']", RegexOptions.IgnoreCase);
        if (!m.Success) throw new Exception("No <iframe src=...> found.");
        return m.Groups[1].Value;
    }

    private static string MakeAbsoluteUrl(string baseUrl, string maybeRelative)
    {
        var baseUri = new Uri(baseUrl);
        return new Uri(baseUri, maybeRelative).ToString();
    }

    public bool IsReusable { get { return true; } }
}
