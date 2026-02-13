<%@ Page Language="C#" Debug="true" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.Data" %>
<%@ Import Namespace="System.Data.SqlClient" %>
<%@ Import Namespace="System.Configuration" %>

<%
    Response.Clear();
    Response.Cache.SetCacheability(HttpCacheability.NoCache);
    Response.Cache.SetNoStore();
    Response.AddHeader("Pragma", "no-cache");
    Response.AddHeader("Expires", "0");
    Response.ContentType = "application/json; charset=utf-8";

    string connString = string.Format(
        ConfigurationManager.ConnectionStrings["SQLConnString"].ConnectionString,
        "InTouch_ss_reporting"
    );

    // Filters
    string sortDateStr = Request.QueryString["SortDate"];
    string sortTypeRaw = Request.QueryString["SortType"];

    string sortType = sortTypeRaw;
    if (!string.IsNullOrEmpty(sortType))
        sortType = sortType.Trim().Trim('\'');

    DateTime sortDate;
    bool hasSortDate = DateTime.TryParse(sortDateStr, out sortDate);
    bool hasSortType = !string.IsNullOrWhiteSpace(sortType);

    if (!hasSortDate || !hasSortType)
    {
        Response.Write("[]");
        Response.End();
        return;
    }

    DateTime dateStart = new DateTime(sortDate.Year, sortDate.Month, sortDate.Day, 0, 0, 0);
    DateTime dateEnd = dateStart.AddDays(1);

    // --- SQL normalization helpers ---
    string normParamSort = "REPLACE(REPLACE(REPLACE(UPPER(@sortType),'_',''),' ',''),'-','')";

    // SLS module list
    string[] slsModules = new[] {
        "SLS03","SLS04","SLS05","SLS07","SLS08","SLS10","SLS11","SLS12","SLS13","SLS14","SLS15","SLS16"
    };

    // Build ONLY the module_TotalVolume columns (but computed as: original - DA - transferred)
    // For NGSS branch, output NULLs for those same columns to keep UNION schema identical.
    var slsColsForSls = new System.Text.StringBuilder();
    var slsColsForNgss = new System.Text.StringBuilder();

    for (int i = 0; i < slsModules.Length; i++)
    {
        string m = slsModules[i];

        // Original: inducted totals per module
        string moduleTotalExpr =
            "(SELECT COALESCE(SUM(w.[value]), 0) " +
            " FROM [InTouch_ss_reporting].[dbo].[ww_inducted_cnt_sorter] w " +
            " WHERE w.[year]  = YEAR(@dateStart) " +
            "   AND w.[month] = MONTH(@dateStart) " +
            "   AND w.[day]   = DAY(@dateStart) " +
            "   AND w.[sort]  = @sortType " +
            "   AND w.[device] = '" + m + "')";

        // DA: latest sortid per module/day/sort
        string moduleDaExpr =
            "(SELECT COALESCE(SUM(s.[value]), 0) " +
            " FROM [InTouch_ss_reporting].[dbo].[ww_sorted_cnt_dest_da] s " +
            " WHERE s.[year]  = YEAR(@dateStart) " +
            "   AND s.[month] = MONTH(@dateStart) " +
            "   AND s.[day]   = DAY(@dateStart) " +
            "   AND s.[sort]  = @sortType " +
            "   AND s.[device] = '" + m + "' " +
            "   AND s.[sortid] = (SELECT MAX(s2.[sortid]) " +
            "                    FROM [InTouch_ss_reporting].[dbo].[ww_sorted_cnt_dest_da] s2 " +
            "                    WHERE s2.[year]  = YEAR(@dateStart) " +
            "                      AND s2.[month] = MONTH(@dateStart) " +
            "                      AND s2.[day]   = DAY(@dateStart) " +
            "                      AND s2.[sort]  = @sortType " +
            "                      AND s2.[device] = '" + m + "')" +
            ")";

        // Transferred: latest sortid per module/day/sort
        string moduleTransferredExpr =
            "(SELECT COALESCE(SUM(t.[value]), 0) " +
            " FROM [InTouch_ss_reporting].[dbo].[ww_sorted_cnt_dest_transferred] t " +
            " WHERE t.[year]  = YEAR(@dateStart) " +
            "   AND t.[month] = MONTH(@dateStart) " +
            "   AND t.[day]   = DAY(@dateStart) " +
            "   AND t.[sort]  = @sortType " +
            "   AND t.[device] = '" + m + "' " +
            "   AND t.[sortid] = (SELECT MAX(t2.[sortid]) " +
            "                    FROM [InTouch_ss_reporting].[dbo].[ww_sorted_cnt_dest_transferred] t2 " +
            "                    WHERE t2.[year]  = YEAR(@dateStart) " +
            "                      AND t2.[month] = MONTH(@dateStart) " +
            "                      AND t2.[day]   = DAY(@dateStart) " +
            "                      AND t2.[sort]  = @sortType " +
            "                      AND t2.[device] = '" + m + "')" +
            ")";

        // ✅ Updated math for what we expose as *_TotalVolume:
        //     Net = original - DA - transferred
        string moduleNetAsTotalExpr = "(" + moduleTotalExpr + " - " + moduleDaExpr + " - " + moduleTransferredExpr + ")";

        slsColsForSls.Append(" , " + moduleNetAsTotalExpr + " AS [" + m + "_TotalVolume]");
        slsColsForNgss.Append(" , NULL AS [" + m + "_TotalVolume]");
    }

    // ✅ NGSS Total_Volume from ato_bullfrog_inducted, filtered by latest sortid
    string ngssTotalVolume =
        "(SELECT COALESCE(SUM(a.[value]), 0) " +
        " FROM [InTouch_bf_reporting].[dbo].[ato_bullfrog_inducted] a " +
        " WHERE a.[year]  = YEAR(@dateStart) " +
        "   AND a.[month] = MONTH(@dateStart) " +
        "   AND a.[day]   = DAY(@dateStart) " +
        "   AND REPLACE(REPLACE(REPLACE(UPPER(COALESCE(a.[sort],'')),'_',''),' ',''),'-','') = " + normParamSort +
        "   AND REPLACE(REPLACE(REPLACE(UPPER(COALESCE(a.[source],'')),'_',''),' ',''),'-','') = 'NGSS' " +
        "   AND a.[sortid] = (SELECT MAX(a2.[sortid]) " +
        "                    FROM [InTouch_bf_reporting].[dbo].[ato_bullfrog_inducted] a2 " +
        "                    WHERE a2.[year]  = YEAR(@dateStart) " +
        "                      AND a2.[month] = MONTH(@dateStart) " +
        "                      AND a2.[day]   = DAY(@dateStart) " +
        "                      AND REPLACE(REPLACE(REPLACE(UPPER(COALESCE(a2.[sort],'')),'_',''),' ',''),'-','') = " + normParamSort +
        "                      AND REPLACE(REPLACE(REPLACE(UPPER(COALESCE(a2.[source],'')),'_',''),' ',''),'-','') = 'NGSS')" +
        ")";

    // SQL with consistent UNION schema
    string sql =
        "WITH SLS AS ( " +
        "  SELECT " +
        "    [SLS_ID], [DEVICE], [SortDate], [SortType], [SortName], [StartTS], [EndTS], [SortState], [ts], " +

        "    (SELECT COALESCE(SUM(e.[value]),0) " +
        "       FROM [InTouch_ss_reporting].[dbo].[ww_acb_hopper_side_a_exc_bags_closed_cnt_line] e " +
        "      WHERE e.[year]  = YEAR(@dateStart) " +
        "        AND e.[month] = MONTH(@dateStart) " +
        "        AND e.[day]   = DAY(@dateStart) " +
        "        AND REPLACE(REPLACE(REPLACE(UPPER(ISNULL(e.[device],'')),'_',''),' ',''),'-','') = REPLACE(REPLACE(REPLACE(UPPER(ISNULL([DEVICE],'')),'_',''),' ',''),'-','') " +
        "        AND REPLACE(REPLACE(REPLACE(UPPER(ISNULL(e.[sort],'')),'_',''),' ',''),'-','') = " + normParamSort +
        "    ) AS [Exception Bags Closed], " +

        "    CAST(CASE WHEN NULLIF(COALESCE(NULLIF([sort_duration], 0), DATEDIFF(SECOND,[StartTS],[EndTS])), 0) IS NULL THEN NULL " +
        "         ELSE ([inducted_cnt] / NULLIF(COALESCE(NULLIF([sort_duration], 0), DATEDIFF(SECOND,[StartTS],[EndTS])), 0.0)) * 3600.0 END AS DECIMAL(18,2)) AS [FPH (Scanned 8,500)], " +

        "    CAST(CASE WHEN NULLIF(([uptime]+[downtime]), 0) IS NULL THEN NULL " +
        "         ELSE ([uptime] / NULLIF(([uptime]+[downtime]), 0.0)) * 100.0 END AS DECIMAL(18,2)) AS [Sorter Uptime%], " +

        "    CAST(CASE WHEN NULLIF([inducted_cnt], 0) IS NULL THEN NULL ELSE ([ote_takeaway_not_run_cnt] / NULLIF([inducted_cnt], 0.0)) * 100.0 END AS DECIMAL(18,2)) AS [Take away Not Running OTE (1%)], " +
        "    CAST(CASE WHEN NULLIF([inducted_cnt], 0) IS NULL THEN NULL ELSE (([no_track_num_cnt] + [no_read_cnt]) / NULLIF([inducted_cnt], 0.0)) * 100.0 END AS DECIMAL(18,2)) AS [No Reads%], " +
        "    CAST(CASE WHEN NULLIF([scanned_cnt], 0) IS NULL THEN NULL ELSE ([ote_dest_full_cnt] / NULLIF([scanned_cnt], 0.0)) * 100.0 END AS DECIMAL(18,2)) AS [Chute Full OTE] " +

             slsColsForSls.ToString() +

        "  , NULL AS [Total_Volume] " +

        "  , CAST(CASE WHEN NULLIF(COALESCE(NULLIF([sort_duration], 0), DATEDIFF(SECOND,[StartTS],[EndTS])), 0) IS NULL THEN NULL " +
        "         ELSE ([inducted_cnt] / NULLIF(COALESCE(NULLIF([sort_duration], 0), DATEDIFF(SECOND,[StartTS],[EndTS])), 0.0)) * 3600.0 END AS DECIMAL(18,2)) AS [Unified_FPH] " +

        "  , CAST(CASE WHEN NULLIF(([uptime]+[downtime]), 0) IS NULL THEN NULL " +
        "         ELSE ([uptime] / NULLIF(([uptime]+[downtime]), 0.0)) * 100.0 END AS DECIMAL(18,2)) AS [Unified_SorterUptimePct] " +

        "  FROM [InTouch_ss_reporting].[dbo].[vSLS_Post_Summary_Report] " +
        "  WHERE [SortDate] >= @dateStart AND [SortDate] < @dateEnd AND [SortType] = @sortType " +
        "), " +

        "NGSS AS ( " +
        "  SELECT " +
        "    NULL AS [SLS_ID], 'NGSS' AS [DEVICE], CAST(@dateStart AS DATE) AS [SortDate], @sortType AS [SortType], " +
        "    NULL AS [SortName], NULL AS [StartTS], NULL AS [EndTS], NULL AS [SortState], NULL AS [ts], " +
        "    NULL AS [Exception Bags Closed], " +
        "    NULL AS [FPH (Scanned 8,500)], NULL AS [Sorter Uptime%], NULL AS [Take away Not Running OTE (1%)], NULL AS [No Reads%], NULL AS [Chute Full OTE] " +

             slsColsForNgss.ToString() +

        "  , " + ngssTotalVolume + " AS [Total_Volume] " +

        "  , NULL AS [Unified_FPH] " +
        "  , NULL AS [Unified_SorterUptimePct] " +
        ") " +

        "SELECT * FROM (SELECT * FROM SLS UNION ALL SELECT * FROM NGSS) x " +
        "FOR JSON PATH";

    try
    {
        using (SqlConnection conn = new SqlConnection(connString))
        using (SqlCommand cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.Add("@dateStart", SqlDbType.DateTime).Value = dateStart;
            cmd.Parameters.Add("@dateEnd", SqlDbType.DateTime).Value = dateEnd;
            cmd.Parameters.Add("@sortType", SqlDbType.NVarChar, 100).Value = sortType;

            conn.Open();
            string json = "[]";

            using (SqlDataReader reader = cmd.ExecuteReader(CommandBehavior.SequentialAccess))
            {
                if (reader.HasRows)
                {
                    System.Text.StringBuilder sb = new System.Text.StringBuilder();
                    while (reader.Read())
                        sb.Append(reader.GetString(0));

                    json = string.IsNullOrWhiteSpace(sb.ToString()) ? "[]" : sb.ToString();
                }
            }

            Response.Write(json);
        }
    }
    catch (Exception ex)
    {
        Response.StatusCode = 500;
        Response.Write("{\"error\":\"Failed to retrieve filtered data\",\"message\":\"" + Server.HtmlEncode(ex.Message) + "\"}");
    }
    finally
    {
        Response.End();
    }
%>
