# SmallsDimensions - Automated Package Dimension Reporting

Automated scheduler and dashboard for fetching ATM package dimension data from the size report system. Fetches data for **multiple dimension configurations** every N minutes, stores snapshots, and provides a dashboard with **delta tracking** between any two snapshots and consolidated Excel reports.

## Quick Start

1. Deploy all files to your IIS site directory
2. Open `index.html` in your browser
3. Configure sorts and interval in the Configuration panel
4. Click **Save Configuration**, then **Start Scheduler**

## How to Use

### Step 1: Deploy

Copy all files into the same folder where your existing `.ashx` files live on the server (e.g. the `middleware_alocal` folder). Key files:

- `App_Code/SizeReportFetcher.cs` — Shared fetch+parse logic
- `App_Code/SchedulerEngine.cs` — Timer-based scheduler with multi-dimension support
- `App_Code/DailyDataStore.cs` — JSON file storage per date
- `App_Code/StoragePathHelper.cs` — Path resolution and permission checking
- `scheduler.ashx` — API: start/stop/status/runnow/history
- `scheduler_config.ashx` — API: GET/POST configuration
- `download.ashx` — API: list dates, get day data, view debug log
- `diag.ashx` — Connection diagnostic tool
- `index.html` — Dashboard UI
- `Global.asax` — Auto-start on app pool start

Also copy the updated legacy handlers:
- `sizeReportJsonHandler.ashx`, `size_report_json.ashx`, `size_report_view.ashx`, `size_report.ashx`

No build step needed — IIS auto-compiles everything. `App_Data/` and all data files are created automatically.

### Step 2: One-Time IIS Setting (required for scheduler)

The scheduler needs the app pool to stay alive. Without this, IIS shuts down the app after 20 minutes of no web requests.

Open **IIS Manager** on the server:

1. **Application Pools** → right-click your pool → **Advanced Settings**
   - **Idle Time-out (minutes)**: change from `20` to `0`
   - **Start Mode**: change from `OnDemand` to `AlwaysRunning`
2. **Sites** → your site → right-click → **Advanced Settings**
   - **Preload Enabled**: change to `True`

This is a one-time change. Everything else is handled automatically.

### Step 3: Open the Dashboard

Go to: `http://10.66.225.81/middleware_alocal/index.html`

### Step 4: Configure Fetch Settings

1. In the **Configuration** panel:
   - **Report Type**: Choose `Small` or `Large`
   - **Dimension Sets**: Displayed read-only — defaults to `16x16x7` and `16x7x16`
   - **Sorts**: Check which sorts to fetch — `ALL` fetches all sorts in one request
   - **Fetch Interval**: 15, 30, 45, or 60 minutes
   - **Auto-start**: Check to auto-start scheduler on app pool restart
2. Click **Save Configuration**

### Step 5: Run Your First Fetch

Click **Fetch Now** to trigger a manual fetch. The scheduler fetches data for **each dimension set** sequentially — you'll see two history entries per fetch cycle (one for 16x16x7, one for 16x7x16).

### Step 6: Start the Scheduler

Click **Start Scheduler** for automated fetching at your configured interval.

### Step 7: View Data with Delta Tracking

The Data View panel shows **two stacked dimension sections** (one per dimension set):

- Each section has its own **Snapshot A / Snapshot B** selectors
- Pick any two timestamps to compare
- **Summary tab**: Shows sort totals delta (Snap A vs Snap B) plus a full time-series overview
- **Sort tabs** (Sunrise, Daysort, Twilight, Night): Shows per-dimension row deltas with the Totals row highlighted
- Positive deltas are shown in green, negative in red

### Step 8: Download Excel

Click **Download Excel** to generate an `.xlsx` file with sheets per dimension set:
- `Summary 16x16x7`, `Summary 16x7x16` — Sort totals across all time intervals
- `Sunrise 16x16x7`, `Sunrise 16x7x16`, etc. — Per-dimension row deltas + time-series

## Architecture

IIS-hosted ASP.NET project — no build system or `.csproj` needed. IIS auto-compiles `.ashx` handlers and `App_Code/*.cs` files.

```
SmallsDimensions/
  App_Code/
    SizeReportFetcher.cs        # Static class: HTTP fetch + HTML parse
    SchedulerEngine.cs          # Singleton scheduler: timer, multi-dim fetch loop, config
    DailyDataStore.cs           # JSON file storage: append snapshots per date
    StoragePathHelper.cs        # Path resolution + permission validation
  App_Data/                     # Auto-created data storage
    fetch_debug.log             # Rolling debug log (500KB max, auto-rotates)
    scheduler_config.json       # Persisted configuration (with DimensionSets)
    {yyyy-MM-dd}/
      consolidated.json         # All fetched interval snapshots for the day
  scheduler.ashx                # API: start/stop/status/runnow/history
  scheduler_config.ashx         # API: GET/POST configuration
  download.ashx                 # API: dates list, day data, debug log viewer
  diag.ashx                     # Connection diagnostic (step-by-step HTTP test)
  index.html                    # Dashboard UI (SheetJS for Excel export)
  Global.asax                   # Auto-start scheduler on app pool start
  sizeReportJsonHandler.ashx    # Original handler (backwards compatible)
  size_report_json.ashx         # Legacy JSON handler
  size_report_view.ashx         # Legacy view handler
  size_report_run.ashx          # Legacy run handler
  size_report.ashx              # Legacy base handler
  atm.ashx                     # ATM proxy handler
  atmdata.ashx                 # ATM data handler
  discover.ashx                # Discovery handler
  download_size_report_csv.ashx # CSV download handler
```

### Key Classes

| Class | File | Purpose |
|-------|------|---------|
| `SizeReportFetcher` | SizeReportFetcher.cs | Static class. Connects to ATM system, submits form, polls for unescape payload, parses HTML tables. Also provides `DebugLog()` for all components. |
| `SizeReportParser` / `SizeReportParsed` | SizeReportFetcher.cs | Parses HTML report into structured data: sort blocks + detailed dimension rows. |
| `FetchResult` | SizeReportFetcher.cs | Result of a fetch: success/error, parsed data, hop log, decoded HTML. |
| `SchedulerEngine` | SchedulerEngine.cs | Static singleton. Timer fires every N minutes, loops over `DimensionSet`s, fetches each independently, stores results. |
| `SchedulerConfig` | SchedulerEngine.cs | Configuration POCO: report type, sorts, interval, `DimensionSets` list, auto-start. |
| `DimensionSet` | SchedulerEngine.cs | One dimension configuration: `Label` ("16x16x7"), `L`, `W`, `H`. |
| `FetchHistoryEntry` | SchedulerEngine.cs | One history row: timestamp, success/error, sort counts, hops, `DimensionLabel`. |
| `DailyDataStore` | DailyDataStore.cs | Thread-safe JSON file storage. Appends snapshots (with `dimensionLabel`) to `consolidated.json`. |
| `StoragePathHelper` | StoragePathHelper.cs | Resolves `App_Data` path, validates write permissions, provides descriptive error messages. |

### Data Flow

```
Timer tick (every N min)
  └─> SchedulerEngine.DoFetch()
        ├─> For each DimensionSet (e.g. 16x16x7, 16x7x16):
        │     ├─> SizeReportFetcher.FetchAndParse(date, report, L, W, H, sorts)
        │     │     ├─> GET warmup → POST submit → poll hidden endpoint
        │     │     └─> Parse HTML → FetchResult { Parsed, Hops, Success }
        │     ├─> DailyDataStore.Append(result, dimensionLabel)
        │     │     └─> Writes to App_Data/{date}/consolidated.json
        │     └─> Insert FetchHistoryEntry (with DimensionLabel)
        └─> Update LastRunUtc, NextRunUtc, LastError

Dashboard (index.html)
  └─> loadDayData() → fetch download.ashx?date=...
        └─> Groups snapshots by dimensionLabel into dimData{}
              └─> Renders per-dimension sections with snapshot selectors + delta tables
```

### Dual Dimension System

The scheduler fetches data for **two dimension configurations** per cycle:

| Label | L | W | H | Description |
|-------|---|---|---|-------------|
| `16x16x7` | 16 | 16 | 7 | Primary dimension set |
| `16x7x16` | 16 | 7 | 16 | Secondary dimension set (W and H swapped) |

Configuration is stored in `scheduler_config.json` as a `DimensionSets` array. Backward compatibility: if the config file has no `DimensionSets` (old format), the legacy scalar `L`/`W`/`H` fields are used to build a single dimension set.

Each snapshot in `consolidated.json` includes a `dimensionLabel` field. Old snapshots without this field default to `"16x16x7"` in the UI.

## API Endpoints

### Scheduler Control — `scheduler.ashx`

| Parameter | Action |
|---|---|
| `?action=status` | Returns scheduler status (running, last/next fetch, error, today's fetch count) |
| `?action=start` | Starts the scheduler with saved config |
| `?action=stop` | Stops the scheduler |
| `?action=runnow` | Triggers an immediate fetch (all dimension sets) |
| `?action=history` | Returns recent fetch history with sort counts and dimension labels |

### Configuration — `scheduler_config.ashx`

| Method | Action |
|---|---|
| `GET` | Returns current config JSON (includes `DimensionSets` array) |
| `POST` (JSON body) | Saves new config |

### Data Access — `download.ashx`

| Parameter | Action |
|---|---|
| `?action=dates` | Lists available dates |
| `?action=debuglog` | Returns last 100 lines of `fetch_debug.log` |
| `?date=2026-02-05` | Returns all fetched intervals for that date |
| *(no params)* | Returns today's data |

### Diagnostics — `diag.ashx`

| Method | Action |
|---|---|
| `GET` | Runs step-by-step connection test: warmup, submit, poll. Returns JSON with diagnosis. |

## Dashboard Features

- **Configuration Panel** — Report type, dimension sets (read-only display), sorts, fetch interval, auto-start toggle
- **Controls** — Start/Stop scheduler, manual Fetch Now, Test Connection diagnostic
- **Live Status** — Running/stopped indicator, last/next fetch times, today's fetch count, errors
- **Data View** — Date picker, per-dimension stacked sections, each with:
  - Snapshot A / Snapshot B selectors (pick any two timestamps)
  - Summary tab with sort totals delta + full time-series
  - Sort tabs with per-dimension-row delta tables (Totals row highlighted)
  - Delta colors: green for positive, red for negative
- **Excel Export** — Download `.xlsx` with per-dimension sheets: `Summary 16x16x7`, `Sunrise 16x16x7`, etc.
- **Fetch History** — Table with dimension label, status, sort counts, error, and hop details
- **Debug Panel** — Collapsible panel showing raw data state, snapshot selectors, config, and server log viewer
- **Auto-refresh** — Polls status every 15 seconds while scheduler is running

## Configuration Options

| Field | Default | Description |
|---|---|---|
| Report | `small` | Report type (`small` or `large`) |
| DimensionSets | `[16x16x7, 16x7x16]` | Array of dimension configurations (Label, L, W, H) |
| Sorts | `ALL` | Sort codes: `SUN`, `DAY`, `TWI`, `NGT`, `ALL` |
| Interval | `30` min | Fetch frequency (15/30/45/60 minutes) |
| Auto-start | `false` | Start scheduler automatically on app pool restart |
| MaxPolls | `25` | Maximum polling attempts per fetch |
| DelayMs | `1200` | Delay between polls (ms) |

Legacy fields `L`, `W`, `H` are still supported for backward compatibility — if `DimensionSets` is absent, they're used to build a single dimension set.

## Debugging & Troubleshooting

### Server-Side Debug Log

All backend components write to `App_Data/fetch_debug.log` via `SizeReportFetcher.DebugLog()`. The log auto-rotates at 500KB (keeps last half).

**Log components and what they track:**

| Component | What it logs |
|-----------|-------------|
| `SCHEDULER` | `SCHEDULER_LOOP_START` (dimension count, labels), `SCHEDULER_FETCH` (per-dim fetch start), `SCHEDULER_RESULT` (success/error per dim), `SCHEDULER_STORED`, `SCHEDULER_LOOP_END` (totals summary), `SCHEDULER_ERROR` (with stack trace) |
| `CONFIG` | `CONFIG_LOAD` (loaded config details, dimension sets), `CONFIG_SAVE` (saved config details) |
| `STORE` | `STORE_APPEND` (date, dimension label), `STORE_WRITTEN` (path, snapshot count, columns, rows), `STORE_SKIP` (null result) |
| `FETCHER` | Warmup, submit, poll attempts, unescape detection, fallback usage |
| `TABLE_PARSE` | HTML search, header detection, row parsing, totals extraction |

**How to view the log:**

1. **Dashboard**: Open Debug Panel → click "View Server Log (last 100 lines)"
2. **Direct API**: `GET download.ashx?action=debuglog`
3. **File system**: Open `App_Data/fetch_debug.log` directly on the server

### Dashboard Debug Panel

The collapsible **Debug Panel** at the bottom of the dashboard shows:

- **Data State**: Total snapshots loaded, selected date, known dimension labels
- **Per-Dimension Snapshots**: Snapshot count, first/last timestamps, column/row counts per dimension
- **Snapshot Selectors**: Current A/B indices and timestamps for each dimension
- **Config**: Full loaded configuration including DimensionSets details
- **Active Tabs**: Which tab is active per dimension section
- **Dump State to Console**: Writes full `dayData`, `dimData`, selectors, and config to browser console (F12)
- **View Server Log**: Fetches and displays the last 100 lines of `fetch_debug.log`

### Browser Console Logging

The dashboard logs key events to the browser console (prefix: `[SmallsDim]`):

- `loadConfig`: Full config received from server
- `loadDayData`: Snapshot count, per-dimension grouping, orphan label warnings
- `renderAllDimSections`: Snapshot counts per dimension
- `onSnapChange`: Which dimension/snapshot changed

### Connection Diagnostics

Click **Test Connection** in the Controls panel to run `diag.ashx`, which tests:
1. Warmup GET to the ATM form
2. Submit POST with parameters
3. Poll hidden endpoint for unescape payload

Returns a step-by-step diagnosis: SUCCESS, FALLBACK AVAILABLE, or NO DATA FOUND.

### Common Issues

| Problem | Diagnosis | Fix |
|---------|-----------|-----|
| "Access to path denied" | Missing App_Data write permission | `icacls "App_Data" /grant "IIS AppPool\YourPool":(OI)(CI)M` |
| Scheduler stops after 20 min | IIS idle timeout | Set app pool idle timeout to 0, start mode to AlwaysRunning |
| No data for one dimension | Check debug log for that dim's SCHEDULER_FETCH/RESULT | ATM system may not have data for that L/W/H combination |
| Snapshots all in "16x16x7" | Old data without `dimensionLabel` field | Expected for pre-upgrade data; new fetches will have the label |
| Delta shows all zeros | Same snapshot selected for A and B | Pick different snapshots |
| Test Connection shows FALLBACK | Primary URL failed, hidden URL succeeded | Normal — the fetcher handles this automatically |

## Deployment & IIS Configuration

### One-Time IIS Settings

| Setting | Location | Value | Why |
|---|---|---|---|
| Idle Time-out | App Pool → Advanced Settings | `0` | Prevents IIS from killing the scheduler |
| Start Mode | App Pool → Advanced Settings | `AlwaysRunning` | Starts app pool immediately when IIS starts |
| Preload Enabled | Site → Advanced Settings | `True` | Triggers `Application_Start` on start |
| Application Initialization | Server Manager → Add Roles/Features → IIS → App Development | Enabled | Required Windows feature for preload |

### App_Data Permissions

The IIS worker process identity needs **Modify** permission on `App_Data`:

```cmd
icacls "C:\inetpub\wwwroot\Middleware_alocal\App_Data" /grant "IIS AppPool\Middleware_alocal":(OI)(CI)M
```

### Optional: Override Storage Path

Set an alternative writable path in `Web.config`:

```xml
<appSettings>
  <add key="AppDataStoragePath" value="D:\SmallsData\App_Data" />
</appSettings>
```

### Backwards Compatibility

| Scenario | Handling |
|----------|----------|
| Old `scheduler_config.json` (no `DimensionSets`) | `GetEffectiveDimensionSets()` falls back to scalar L/W/H as single set |
| Old `consolidated.json` snapshots (no `dimensionLabel`) | JS defaults to `"16x16x7"` |
| Old history entries (no `DimensionLabel`) | UI renders `h.DimensionLabel \|\| '16x16x7'` |
| Existing `.ashx` URLs | Still work unchanged — new system is additive |
