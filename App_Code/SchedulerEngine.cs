using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Linq;
using System.Web.Script.Serialization;

/// <summary>
/// Static singleton managing the automated fetch schedule.
/// </summary>
public static class SchedulerEngine
{
    private static readonly object _lock = new object();
    private static Timer _timer;
    private static string _appDataPath;
    private static readonly JavaScriptSerializer _json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

    // --- State ---
    public static bool IsRunning { get; private set; }
    public static DateTime? LastRunUtc { get; private set; }
    public static DateTime? NextRunUtc { get; private set; }
    public static string LastError { get; private set; }
    public static int TodayFetchCount { get; private set; }
    public static string TodayDate { get; private set; }

    private static List<FetchHistoryEntry> _fetchHistory = new List<FetchHistoryEntry>();
    private const int MaxHistoryEntries = 50;

    // --- Config ---
    public static SchedulerConfig CurrentConfig { get; private set; }

    public static void Start(SchedulerConfig config, string appDataPath)
    {
        lock (_lock)
        {
            if (IsRunning) Stop();

            CurrentConfig = config ?? LoadConfig(appDataPath);
            _appDataPath = appDataPath;

            // Verify the storage folder exists and is writable (throws descriptive error on failure)
            StoragePathHelper.EnsureWritable(_appDataPath);

            int intervalMs = (CurrentConfig.IntervalMinutes > 0 ? CurrentConfig.IntervalMinutes : 30) * 60 * 1000;

            _timer = new Timer(OnTick, null, 0, intervalMs);
            IsRunning = true;
            NextRunUtc = DateTime.UtcNow;
            ResetDayCounterIfNeeded();
        }
    }

    public static void Stop()
    {
        lock (_lock)
        {
            if (_timer != null)
            {
                _timer.Dispose();
                _timer = null;
            }
            IsRunning = false;
            NextRunUtc = null;
        }
    }

    public static void RunNow()
    {
        ThreadPool.QueueUserWorkItem(_ => DoFetch());
    }

    public static object GetStatus()
    {
        lock (_lock)
        {
            return new
            {
                isRunning = IsRunning,
                lastRunUtc = LastRunUtc.HasValue ? LastRunUtc.Value.ToString("o") : null,
                nextRunUtc = NextRunUtc.HasValue ? NextRunUtc.Value.ToString("o") : null,
                lastError = LastError,
                todayFetchCount = TodayFetchCount,
                todayDate = TodayDate,
                configLoaded = (CurrentConfig != null)
            };
        }
    }

    public static List<FetchHistoryEntry> GetHistory()
    {
        lock (_lock)
        {
            return new List<FetchHistoryEntry>(_fetchHistory);
        }
    }

    // --- Config persistence ---

    public static string ConfigFilePath(string appDataPath)
    {
        return Path.Combine(appDataPath, "scheduler_config.json");
    }

    public static SchedulerConfig LoadConfig(string appDataPath)
    {
        string path = ConfigFilePath(appDataPath);
        if (!File.Exists(path))
        {
            SizeReportFetcher.DebugLog("CONFIG", "CONFIG_LOAD file not found, using defaults. path=" + path);
            return SchedulerConfig.Default();
        }

        try
        {
            string json = File.ReadAllText(path, Encoding.UTF8);
            var config = _json.Deserialize<SchedulerConfig>(json);
            if (config == null)
            {
                SizeReportFetcher.DebugLog("CONFIG", "CONFIG_LOAD deserialized null, using defaults");
                return SchedulerConfig.Default();
            }

            var dimSets = config.GetEffectiveDimensionSets();
            SizeReportFetcher.DebugLog("CONFIG", string.Format(
                "CONFIG_LOAD ok report={0} interval={1}min sorts=[{2}] dimSets={3} labels=[{4}] autoStart={5}",
                config.Report ?? "(null)", config.IntervalMinutes,
                config.Sorts != null ? string.Join(",", config.Sorts) : "(null)",
                dimSets.Count,
                string.Join(",", dimSets.Select(d => d.Label)),
                config.AutoStart));
            return config;
        }
        catch (Exception ex)
        {
            SizeReportFetcher.DebugLog("CONFIG", "CONFIG_LOAD error=" + ex.Message);
            return SchedulerConfig.Default();
        }
    }

    public static void SaveConfig(string appDataPath, SchedulerConfig config)
    {
        StoragePathHelper.EnsureWritable(appDataPath);

        var dimSets = config.GetEffectiveDimensionSets();
        SizeReportFetcher.DebugLog("CONFIG", string.Format(
            "CONFIG_SAVE report={0} interval={1}min dimSets={2} labels=[{3}] autoStart={4}",
            config.Report ?? "(null)", config.IntervalMinutes,
            dimSets.Count,
            string.Join(",", dimSets.Select(d => d.Label)),
            config.AutoStart));

        string path = ConfigFilePath(appDataPath);
        string json = _json.Serialize(config);
        File.WriteAllText(path, json, Encoding.UTF8);

        lock (_lock)
        {
            CurrentConfig = config;
        }
    }

    // --- Timer callback ---

    private static void OnTick(object state)
    {
        DoFetch();
    }

    private static void DoFetch()
    {
        SchedulerConfig config;
        string appDataPath;

        lock (_lock)
        {
            config = CurrentConfig;
            appDataPath = _appDataPath;
        }

        if (config == null || string.IsNullOrEmpty(appDataPath)) return;

        string date = SizeReportFetcher.GetTodayCentral_yyyyMMdd();
        var sorts = config.Sorts ?? new List<string> { "ALL" };
        var dimensionSets = config.GetEffectiveDimensionSets();
        string lastError = null;
        int successCount = 0;
        int failCount = 0;

        SizeReportFetcher.DebugLog("SCHEDULER", string.Format(
            "SCHEDULER_LOOP_START date={0} dimensionSets={1} labels=[{2}] sorts=[{3}] interval={4}min",
            date, dimensionSets.Count,
            string.Join(",", dimensionSets.Select(d => d.Label)),
            string.Join(",", sorts),
            config.IntervalMinutes));

        foreach (var dimSet in dimensionSets)
        {
            try
            {
                SizeReportFetcher.DebugLog("SCHEDULER", string.Format("SCHEDULER_FETCH dim={0} date={1} report={2} sorts={3}",
                    dimSet.Label, date, config.Report ?? "small", string.Join(",", sorts)));

                var result = SizeReportFetcher.FetchAndParse(
                    date,
                    config.Report ?? "small",
                    dimSet.L ?? "16",
                    dimSet.W ?? "16",
                    dimSet.H ?? "7",
                    sorts,
                    config.MaxPolls > 0 ? config.MaxPolls : 25,
                    config.DelayMs > 0 ? config.DelayMs : 1200
                );

                SizeReportFetcher.DebugLog("SCHEDULER", string.Format("SCHEDULER_RESULT dim={0} success={1} error={2} hops={3} decodedHtmlBytes={4}",
                    dimSet.Label, result.Success, result.Error ?? "(none)",
                    result.Hops != null ? result.Hops.Count : 0,
                    result.DecodedHtml != null ? result.DecodedHtml.Length : 0));

                DailyDataStore.Append(appDataPath, date, result, dimSet.Label);

                SizeReportFetcher.DebugLog("SCHEDULER", string.Format("SCHEDULER_STORED dim={0} date={1}",
                    dimSet.Label, date));

                if (result.Success)
                    successCount++;
                else
                {
                    failCount++;
                    lastError = result.Error ?? "Fetch returned no detailed data";
                }

                lock (_lock)
                {
                    ResetDayCounterIfNeeded();
                    TodayFetchCount++;

                    var sortSummary = new Dictionary<string, string>();
                    if (result.Parsed != null)
                    {
                        var totals = SizeReportFetcher.GetDetailedTotalsBySort(result.Parsed);
                        foreach (var kv in totals)
                            sortSummary[kv.Key] = kv.Value;
                    }

                    _fetchHistory.Insert(0, new FetchHistoryEntry
                    {
                        FetchedAtUtc = DateTime.UtcNow.ToString("o"),
                        FetchedAtCentral = SizeReportFetcher.GetNowCentralFormatted(),
                        Success = result.Success,
                        Error = result.Error,
                        SortCounts = sortSummary,
                        Hops = result.Hops ?? new List<string>(),
                        DimensionLabel = dimSet.Label
                    });

                    if (_fetchHistory.Count > MaxHistoryEntries)
                        _fetchHistory.RemoveAt(_fetchHistory.Count - 1);
                }
            }
            catch (Exception ex)
            {
                SizeReportFetcher.DebugLog("SCHEDULER", string.Format("SCHEDULER_ERROR dim={0} error={1}\n  stackTrace={2}",
                    dimSet.Label, ex.Message, ex.StackTrace));
                lastError = ex.Message;
                failCount++;

                lock (_lock)
                {
                    _fetchHistory.Insert(0, new FetchHistoryEntry
                    {
                        FetchedAtUtc = DateTime.UtcNow.ToString("o"),
                        FetchedAtCentral = SizeReportFetcher.GetNowCentralFormatted(),
                        Success = false,
                        Error = ex.Message,
                        SortCounts = new Dictionary<string, string>(),
                        Hops = new List<string>(),
                        DimensionLabel = dimSet.Label
                    });

                    if (_fetchHistory.Count > MaxHistoryEntries)
                        _fetchHistory.RemoveAt(_fetchHistory.Count - 1);
                }
            }
        }

        SizeReportFetcher.DebugLog("SCHEDULER", string.Format(
            "SCHEDULER_LOOP_END date={0} total={1} success={2} fail={3} lastError={4}",
            date, dimensionSets.Count, successCount, failCount, lastError ?? "(none)"));

        lock (_lock)
        {
            LastRunUtc = DateTime.UtcNow;
            LastError = lastError;
            int intervalMs = (config.IntervalMinutes > 0 ? config.IntervalMinutes : 30) * 60 * 1000;
            NextRunUtc = DateTime.UtcNow.AddMilliseconds(intervalMs);
        }
    }

    private static void ResetDayCounterIfNeeded()
    {
        string today = SizeReportFetcher.GetTodayCentral_yyyyMMdd();
        if (TodayDate != today)
        {
            TodayDate = today;
            TodayFetchCount = 0;
        }
    }
}

public class SchedulerConfig
{
    public string Report { get; set; }
    public string L { get; set; }
    public string W { get; set; }
    public string H { get; set; }
    public List<string> Sorts { get; set; }
    public int IntervalMinutes { get; set; }
    public int MaxPolls { get; set; }
    public int DelayMs { get; set; }
    public bool AutoStart { get; set; }
    public List<DimensionSet> DimensionSets { get; set; }

    public List<DimensionSet> GetEffectiveDimensionSets()
    {
        if (DimensionSets != null && DimensionSets.Count > 0)
            return DimensionSets;
        return new List<DimensionSet> {
            new DimensionSet {
                Label = (L ?? "16") + "x" + (W ?? "16") + "x" + (H ?? "7"),
                L = L ?? "16", W = W ?? "16", H = H ?? "7"
            }
        };
    }

    public static SchedulerConfig Default()
    {
        return new SchedulerConfig
        {
            Report = "small",
            L = "16",
            W = "16",
            H = "7",
            Sorts = new List<string> { "ALL" },
            IntervalMinutes = 30,
            MaxPolls = 25,
            DelayMs = 1200,
            AutoStart = false,
            DimensionSets = new List<DimensionSet>
            {
                new DimensionSet { Label = "16x16x7", L = "16", W = "16", H = "7" },
                new DimensionSet { Label = "16x7x16", L = "16", W = "7", H = "16" }
            }
        };
    }
}

public class FetchHistoryEntry
{
    public string FetchedAtUtc { get; set; }
    public string FetchedAtCentral { get; set; }
    public bool Success { get; set; }
    public string Error { get; set; }
    public Dictionary<string, string> SortCounts { get; set; }
    public List<string> Hops { get; set; }
    public string DimensionLabel { get; set; }
}

public class DimensionSet
{
    public string Label { get; set; }
    public string L { get; set; }
    public string W { get; set; }
    public string H { get; set; }
}
