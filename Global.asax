<%@ Application Language="C#" %>

<script runat="server">
    void Application_Start(object sender, EventArgs e)
    {
        string appDataPath = StoragePathHelper.Resolve(Server.MapPath("~/App_Data"));

        try
        {
            StoragePathHelper.EnsureWritable(appDataPath);
        }
        catch (Exception ex)
        {
            // Log to Windows Event Log so the admin can see it even without a request
            System.Diagnostics.EventLog.WriteEntry(
                "Application",
                "SmallsDimensions: App_Data storage path not writable. " +
                "Scheduler auto-start skipped.\n" + ex.Message,
                System.Diagnostics.EventLogEntryType.Error);
            return; // skip auto-start; scheduler can still be started manually after fixing perms
        }

        var config = SchedulerEngine.LoadConfig(appDataPath);

        if (config.AutoStart)
        {
            SchedulerEngine.Start(config, appDataPath);
        }
    }

    void Application_End(object sender, EventArgs e)
    {
        SchedulerEngine.Stop();
    }
</script>
