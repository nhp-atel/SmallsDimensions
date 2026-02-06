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

            if (!Directory.Exists(_appDataPath))
                Directory.CreateDirectory(_appDataPath);

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
            return SchedulerConfig.Default();

        try
        {
            string json = File.ReadAllText(path, Encoding.UTF8);
            var config = _json.Deserialize<SchedulerConfig>(json);
            return config ?? SchedulerConfig.Default();
        }
        catch
        {
            return SchedulerConfig.Default();
        }
    }

    public static void SaveConfig(string appDataPath, SchedulerConfig config)
    {
        if (!Directory.Exists(appDataPath))
            Directory.CreateDirectory(appDataPath);

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
        try
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

            var result = SizeReportFetcher.FetchAndParse(
                date,
                config.Report ?? "small",
                config.L ?? "16",
                config.W ?? "16",
                config.H ?? "7",
                sorts,
                config.MaxPolls > 0 ? config.MaxPolls : 25,
                config.DelayMs > 0 ? config.DelayMs : 1200
            );

            // Store data
            DailyDataStore.Append(appDataPath, date, result);

            // Update state
            lock (_lock)
            {
                LastRunUtc = DateTime.UtcNow;
                LastError = result.Success ? null : (result.Error ?? "Fetch returned no detailed data");

                ResetDayCounterIfNeeded();
                TodayFetchCount++;

                int intervalMs = (config.IntervalMinutes > 0 ? config.IntervalMinutes : 30) * 60 * 1000;
                NextRunUtc = DateTime.UtcNow.AddMilliseconds(intervalMs);

                // Build sort summary
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
                    SortCounts = sortSummary
                });

                if (_fetchHistory.Count > MaxHistoryEntries)
                    _fetchHistory.RemoveAt(_fetchHistory.Count - 1);
            }
        }
        catch (Exception ex)
        {
            lock (_lock)
            {
                LastError = ex.Message;
                LastRunUtc = DateTime.UtcNow;

                _fetchHistory.Insert(0, new FetchHistoryEntry
                {
                    FetchedAtUtc = DateTime.UtcNow.ToString("o"),
                    FetchedAtCentral = SizeReportFetcher.GetNowCentralFormatted(),
                    Success = false,
                    Error = ex.Message,
                    SortCounts = new Dictionary<string, string>()
                });

                if (_fetchHistory.Count > MaxHistoryEntries)
                    _fetchHistory.RemoveAt(_fetchHistory.Count - 1);
            }
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
            AutoStart = false
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
}
