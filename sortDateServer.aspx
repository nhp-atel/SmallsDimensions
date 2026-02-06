<%@ Page Language="C#" AutoEventWireup="true"   %>
    <%@ Import Namespace="System.Data.SqlClient" %>


        <%
    /*--------------------------------------------
    ----------------------------------------------
    -----DATA SERVER TO GET CURRENT SORT INFO-----
    ----------------------------------------------
    ------RETURNS JSON FILE WITH QUERY DATA-------
    ----------------------------------------------
    ----------------------------------------------*/

    string SqlConnectString = string.Format(ConfigurationManager.ConnectionStrings["SQLConnString"].ConnectionString, "Middleware");

    SqlConnection SQLconn = new SqlConnection(SqlConnectString);
    SQLconn.Open();

    string sqlCommand = @"select top(8) id, SortType,SortDate,StartTS
    ,EndTS    
    from sortstate
    order by id desc
    
              FOR JSON PATH";

    SqlCommand SQLcmd = new SqlCommand(sqlCommand, SQLconn);
    SqlDataReader SQLreader = SQLcmd.ExecuteReader();

     string json = "";

    if (SQLreader.HasRows)
    {

        while (SQLreader.Read())
        {
            json += SQLreader[0].ToString();   
        }
        
    }

    SQLreader.Close();
    SQLconn.Close();

        Response.Clear();
        Response.ContentType = "application/json; charset=utf-8";
	Response.Write(json);
	Response.End();

%>
