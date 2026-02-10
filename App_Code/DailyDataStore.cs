using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Linq;
using System.Web.Script.Serialization;

/// <summary>
/// JSON-file-based storage that accumulates interval snapshots per day.
/// Thread-safe with lock(_fileLock).
/// </summary>
public static class DailyDataStore
{
    private static readonly object _fileLock = new object();
    private static readonly JavaScriptSerializer _json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

    /// <summary>
    /// Append one interval snapshot to App_Data/{date}/consolidated.json
    /// </summary>
    public static void Append(string appDataPath, string date, FetchResult result)
    {
        SizeReportFetcher.DebugLog("STORE", string.Format("STORE_APPEND date={0} resultNull={1} parsedNull={2}",
            date, result == null, result != null ? (result.Parsed == null).ToString() : "n/a"));

        if (result == null || result.Parsed == null)
        {
            SizeReportFetcher.DebugLog("STORE", "STORE_SKIP result or parsed is null — nothing stored");
            return;
        }

        string dateFolder = Path.Combine(appDataPath, date);
        string filePath = Path.Combine(dateFolder, "consolidated.json");

        var snapshot = BuildSnapshot(result);

        lock (_fileLock)
        {
            if (!Directory.Exists(dateFolder))
                Directory.CreateDirectory(dateFolder);

            List<Dictionary<string, object>> existing = ReadExistingSnapshots(filePath);
            existing.Add(snapshot);

            string json = _json.Serialize(existing);
            File.WriteAllText(filePath, json, Encoding.UTF8);

            SizeReportFetcher.DebugLog("STORE", string.Format("STORE_WRITTEN path={0} snapshotCount={1} success={2} columns={3} rows={4}",
                filePath, existing.Count, result.Success,
                result.Parsed.DetailedColumns != null ? result.Parsed.DetailedColumns.Count : 0,
                result.Parsed.DetailedRows != null ? result.Parsed.DetailedRows.Count : 0));
        }
    }

    /// <summary>
    /// Read all intervals for a given date. Returns the raw JSON string.
    /// </summary>
    public static string ReadDay(string appDataPath, string date)
    {
        string filePath = Path.Combine(appDataPath, date, "consolidated.json");

        lock (_fileLock)
        {
            if (!File.Exists(filePath))
                return "[]";

            return File.ReadAllText(filePath, Encoding.UTF8);
        }
    }

    /// <summary>
    /// List available date folders (those containing consolidated.json).
    /// </summary>
    public static List<string> ListDates(string appDataPath)
    {
        var dates = new List<string>();

        if (!Directory.Exists(appDataPath))
            return dates;

        foreach (var dir in Directory.GetDirectories(appDataPath))
        {
            string dirName = Path.GetFileName(dir);
            string consolidatedPath = Path.Combine(dir, "consolidated.json");

            if (File.Exists(consolidatedPath))
                dates.Add(dirName);
        }

        dates.Sort();
        dates.Reverse();
        return dates;
    }

    private static Dictionary<string, object> BuildSnapshot(FetchResult result)
    {
        var snapshot = new Dictionary<string, object>();
        snapshot["fetchedAtUtc"] = result.FetchedAtUtc.ToString("o");
        snapshot["fetchedAtCentral"] = SizeReportFetcher.GetNowCentralFormatted();
        snapshot["success"] = result.Success;
        snapshot["error"] = result.Error;

        // Sort blocks
        var sortBlocks = new List<Dictionary<string, string>>();
        if (result.Parsed.SortBlocks != null)
        {
            foreach (var sb in result.Parsed.SortBlocks)
            {
                var d = new Dictionary<string, string>();
                d["name"] = sb.name ?? "";
                d["timeWindow"] = sb.timeWindow ?? "";
                d["percentOfSort"] = sb.percentOfSort ?? "";
                d["pkgs"] = sb.pkgs ?? "";
                d["totalPkgs"] = sb.totalPkgs ?? "";
                sortBlocks.Add(d);
            }
        }
        snapshot["sortBlocks"] = sortBlocks;

        // Detailed table
        snapshot["detailedFound"] = result.Parsed.DetailedFound;
        snapshot["detailedColumns"] = result.Parsed.DetailedColumns ?? new List<string>();

        var rows = new List<Dictionary<string, string>>();
        if (result.Parsed.DetailedRows != null)
        {
            foreach (var row in result.Parsed.DetailedRows)
            {
                var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var kv in row)
                    d[kv.Key] = kv.Value;
                rows.Add(d);
            }
        }
        snapshot["detailedRows"] = rows;

        snapshot["statsLine"] = result.Parsed.StatsLine ?? "";
        snapshot["forLine"] = result.Parsed.ForLine ?? "";
        snapshot["detailedTotalsOverall"] = result.Parsed.DetailedTotalsOverall ?? "";

        return snapshot;
    }

    private static List<Dictionary<string, object>> ReadExistingSnapshots(string filePath)
    {
        if (!File.Exists(filePath))
            return new List<Dictionary<string, object>>();

        try
        {
            string json = File.ReadAllText(filePath, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(json))
                return new List<Dictionary<string, object>>();

            var arr = _json.Deserialize<object[]>(json);
            if (arr == null)
                return new List<Dictionary<string, object>>();

            var list = new List<Dictionary<string, object>>();
            foreach (var item in arr)
            {
                var dict = item as Dictionary<string, object>;
                if (dict != null)
                    list.Add(dict);
            }
            return list;
        }
        catch
        {
            return new List<Dictionary<string, object>>();
        }
    }
}
