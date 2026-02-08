# SmallsDimensions - Automated Package Dimension Reporting

Automated scheduler and dashboard for fetching ATM package dimension data from the size report system. Replaces dozens of manual URL calls per day with a single automated process that produces consolidated Excel reports.

## Quick Start

1. Deploy all files to your IIS site directory
2. Open `index.html` in your browser
3. Configure dimensions, sorts, and interval in the Configuration panel
4. Click **Save Configuration**, then **Start Scheduler**

## How to Use

### Step 1: Deploy

Copy all the new files into the same folder where your existing `.ashx` files live on the server (e.g. the `middleware_alocal` folder). The new files to copy are:

- `App_Code/SizeReportFetcher.cs`
- `App_Code/SchedulerEngine.cs`
- `App_Code/DailyDataStore.cs`
- `scheduler.ashx`
- `scheduler_config.ashx`
- `download.ashx`
- `index.html`
- `Global.asax`

Also copy the updated versions of:
- `sizeReportJsonHandler.ashx`
- `size_report_json.ashx`
- `size_report_view.ashx`
- `size_report.ashx`

That's it — no build step needed. IIS auto-compiles everything. The `App_Data/` folder and all data files are created automatically by the code.

### Step 2: One-Time IIS Setting (required for scheduler)

The **only** thing you need to do manually on the server is change the app pool idle timeout. Without this, IIS shuts down the app after 20 minutes of no web requests, which kills the scheduler.

Open **IIS Manager** on the server:

1. **Application Pools** → right-click your pool → **Advanced Settings**
   - **Idle Time-out (minutes)**: change from `20` to `0`
   - **Start Mode**: change from `OnDemand` to `AlwaysRunning`
2. **Sites** → your site → right-click → **Advanced Settings**
   - **Preload Enabled**: change to `True`

This is a one-time change. Everything else is handled by the code automatically:
- `App_Data/` folder — created automatically
- `scheduler_config.json` — created automatically on first config save
- `consolidated.json` per date — created automatically on each fetch
- `Global.asax` — picked up by IIS automatically (handles auto-start after app pool recycles)

### Step 3: Open the Dashboard

Go to: `http://10.66.225.81/middleware_alocal/index.html`

You'll see the dashboard with a red "Stopped" badge in the header.

### Step 4: Configure Fetch Settings

1. In the **Configuration** panel at the top, set your preferences:
   - **Report Type**: Choose `Small` or `Large`
   - **Dimensions**: Set L, W, H thresholds (defaults: 16, 16, 7)
   - **Sorts**: Check which sorts to fetch — `ALL` fetches all sorts in one request, or pick individual ones (`Sunrise`, `Daysort`, `Twilight`, `Night`)
   - **Fetch Interval**: How often to auto-fetch (15, 30, 45, or 60 minutes)
   - **Auto-start**: Check this if you want the scheduler to start automatically whenever the IIS app pool restarts
2. Click **Save Configuration**

### Step 5: Run Your First Fetch

Click the **Fetch Now** button to trigger a manual fetch immediately. This takes 15-30 seconds (the ATM system requires polling). Once complete:
- The **Status** panel updates with the fetch time
- The **Data View** panel shows your data in the Summary tab
- The **Fetch History** section at the bottom shows the result

### Step 6: Start the Scheduler

Click **Start Scheduler** to begin automated fetching. The header badge turns green and shows "Running". The scheduler will automatically fetch data at your configured interval. The dashboard auto-refreshes status every 15 seconds.

### Step 7: View Data

- Use the **Date** dropdown to switch between dates
- Click the **Summary** tab to see package totals per sort across all time intervals
- Click individual sort tabs (**Sunrise**, **Daysort**, **Twilight**, **Night**) to see the full dimension breakdown table and totals over time
- The data accumulates throughout the day — each fetch adds a new time column

### Step 8: Download Excel

Click **Download Excel** to generate an `.xlsx` file with:
- A **Summary** sheet with sort totals across all time intervals
- Individual sheets per sort (e.g. **Sunrise**, **Daysort**) with the full dimension breakdown
- Only sorts that have actual data get a sheet (empty sorts are skipped)

The file is generated client-side using SheetJS — nothing is sent to a server.

### Stopping the Scheduler

Click **Stop Scheduler** at any time. Already-collected data is preserved in `App_Data/`. You can restart anytime and it will continue accumulating data for the current day.

### Viewing Historical Data

All data is stored by date in `App_Data/{yyyy-MM-dd}/consolidated.json`. Use the date dropdown in the Data View panel to browse previous days. You can download Excel files for any historical date.

### Using the API Directly

You can also interact with the system via direct API calls (useful for scripting or monitoring):

```
# Check scheduler status
GET http://10.66.225.81/middleware_alocal/scheduler.ashx?action=status

# Start/stop the scheduler
GET http://10.66.225.81/middleware_alocal/scheduler.ashx?action=start
GET http://10.66.225.81/middleware_alocal/scheduler.ashx?action=stop

# Trigger a manual fetch
GET http://10.66.225.81/middleware_alocal/scheduler.ashx?action=runnow

# View fetch history
GET http://10.66.225.81/middleware_alocal/scheduler.ashx?action=history

# Get/save configuration
GET http://10.66.225.81/middleware_alocal/scheduler_config.ashx
POST http://10.66.225.81/middleware_alocal/scheduler_config.ashx  (JSON body)

# List available dates
GET http://10.66.225.81/middleware_alocal/download.ashx?action=dates

# Get a specific day's data
GET http://10.66.225.81/middleware_alocal/download.ashx?date=2026-02-05
```

### Backwards Compatibility

Your existing URLs still work exactly as before:
- `http://10.66.225.81/middleware_alocal/size_report.ashx`
- `http://10.66.225.81/middleware_alocal/sizeReportJsonHandler.ashx`
- `http://10.66.225.81/middleware_alocal/size_report_json.ashx`
- etc.

The new scheduler system is additive — it doesn't break any existing workflows.

## Architecture

IIS-hosted ASP.NET project — no build system or `.csproj` needed. IIS auto-compiles `.ashx` handlers and `App_Code/*.cs` files.

```
SmallsDimensions/
  App_Code/
    SizeReportFetcher.cs       # Shared fetch+parse logic (static class)
    SchedulerEngine.cs         # Timer-based scheduler singleton
    DailyDataStore.cs          # JSON file storage per date
  App_Data/                    # Auto-created data storage
    scheduler_config.json      # Persisted configuration
    2026-02-05/
      consolidated.json        # All fetched intervals for the day
  scheduler.ashx               # API: start/stop/status/runnow/history
  scheduler_config.ashx        # API: GET/POST configuration
  download.ashx                # API: list dates + get day data
  index.html                   # Dashboard UI
  Global.asax                  # Auto-start scheduler on app pool start
  sizeReportJsonHandler.ashx   # Original handler (backwards compatible)
  size_report_json.ashx        # Legacy JSON handler
  size_report_view.ashx        # Legacy view handler
  size_report_run.ashx         # Legacy run handler
  size_report.ashx             # Legacy base handler
```

## API Endpoints

### Scheduler Control — `scheduler.ashx`

| Parameter | Action |
|---|---|
| `?action=status` | Returns scheduler status (running, last/next fetch, error) |
| `?action=start` | Starts the scheduler with saved config |
| `?action=stop` | Stops the scheduler |
| `?action=runnow` | Triggers an immediate fetch |
| `?action=history` | Returns recent fetch history with sort counts |

### Configuration — `scheduler_config.ashx`

| Method | Action |
|---|---|
| `GET` | Returns current config JSON |
| `POST` (JSON body) | Saves new config |

### Data Access — `download.ashx`

| Parameter | Action |
|---|---|
| `?action=dates` | Lists available dates |
| `?date=2026-02-05` | Returns all fetched intervals for that date |
| *(no params)* | Returns today's data |

## Dashboard Features

- **Configuration Panel** — Report type, dimensions (L/W/H), sorts, fetch interval, auto-start toggle
- **Controls** — Start/Stop scheduler, manual Fetch Now button
- **Live Status** — Running/stopped indicator, last/next fetch times, today's fetch count, errors
- **Data View** — Date picker, Summary + per-sort tabs showing dimension breakdowns and time-series totals
- **Excel Export** — Download `.xlsx` with Summary sheet + per-sort sheets (only sorts with data)
- **Fetch History** — Table of recent fetches with status, sort counts, and errors
- **Auto-refresh** — Polls status every 15 seconds while scheduler is running

## Configuration Options

| Field | Default | Description |
|---|---|---|
| Report | `small` | Report type (`small` or `large`) |
| L, W, H | `16, 16, 7` | Package dimension thresholds |
| Sorts | `ALL` | Sort codes: `SUN`, `DAY`, `TWI`, `NGT`, `ALL` |
| Interval | `30` min | Fetch frequency (15/30/45/60 minutes) |
| Auto-start | `false` | Start scheduler automatically on app pool restart |

## How It Works

1. **SchedulerEngine** fires a timer every N minutes
2. **SizeReportFetcher** connects to the ATM system (`10.66.225.108`), submits the form, polls the hidden endpoint until the unescape payload appears, then parses the HTML report
3. **DailyDataStore** appends each fetch result as a JSON snapshot to `App_Data/{date}/consolidated.json`
4. The **dashboard** reads this consolidated data and renders it in tables, with client-side Excel generation via SheetJS

## Deployment & IIS Configuration

### One-Time IIS Settings

Set these via **IIS Manager** on the server (not web.config):

| Setting | Location | Value | Why |
|---|---|---|---|
| Idle Time-out | App Pool → Advanced Settings | `0` | Prevents IIS from killing the scheduler after 20 min of no requests |
| Start Mode | App Pool → Advanced Settings | `AlwaysRunning` | Starts the app pool immediately when IIS starts |
| Preload Enabled | Site → Advanced Settings | `True` | Sends a warm-up request on start, triggering `Application_Start` |
| Application Initialization | Server Manager → Add Roles/Features → IIS → App Development | Enabled | Required Windows feature for preload to work |

### App_Data Permissions

The IIS worker process identity needs **Modify** permission on the `App_Data` folder. Without this you'll get:

```
Access to the path 'C:\inetpub\wwwroot\Middleware_alocal\App_Data' is denied.
```

**To fix**, open an admin Command Prompt and run:

```cmd
icacls "C:\inetpub\wwwroot\Middleware_alocal\App_Data" /grant "IIS AppPool\Middleware_alocal":(OI)(CI)M
```

Replace `Middleware_alocal` with your actual app pool name. If the pool runs as a domain account (e.g. `DOMAIN\svcSmalls`), use that instead.

You can also set this via Explorer: right-click `App_Data` → Properties → Security → Edit → Add → type the identity → check Modify → OK.

### How to Find Your App Pool Identity

The error message now includes the exact identity and path. If you hit the error via a browser request, the JSON response shows:

```
PERMISSION ERROR - Storage path is not writable.
  Path     : C:\inetpub\wwwroot\Middleware_alocal\App_Data
  Identity : IIS AppPool\Middleware_alocal
  Fix      : Grant Modify permission to 'IIS AppPool\Middleware_alocal' on folder '...'
             icacls "..." /grant "IIS AppPool\Middleware_alocal":(OI)(CI)M
```

If the error happens during auto-start (no browser request), check **Windows Event Viewer** → Windows Logs → Application for the same message.

### Optional: Override Storage Path

If you can't change permissions on the site folder, set an alternative writable path in `Web.config`:

```xml
<appSettings>
  <add key="AppDataStoragePath" value="D:\SmallsData\App_Data" />
</appSettings>
```

All code paths (Global.asax, scheduler, config, download) will use this path instead. The target folder still needs Modify permission for the app pool identity.

### web.config Auto-Start Support

The `web.config` includes an `applicationInitialization` section that works with the IIS settings above:

```xml
<applicationInitialization doAppInitAfterRestart="true">
  <add initializationPage="/" />
</applicationInitialization>
```

This tells IIS to send a warm-up request to `/` whenever the app pool starts or recycles, which triggers `Application_Start` in `Global.asax`, which auto-starts the scheduler (if `AutoStart` is enabled in the config)
