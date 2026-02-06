<%@ Application Language="C#" %>

<script runat="server">
    void Application_Start(object sender, EventArgs e)
    {
        string appDataPath = Server.MapPath("~/App_Data");
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
