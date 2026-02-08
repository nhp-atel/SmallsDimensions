using System;
using System.Configuration;
using System.IO;
using System.Security.Principal;

/// <summary>
/// Resolves and validates the App_Data storage path.
/// Supports an optional web.config override via appSetting "AppDataStoragePath".
/// </summary>
public static class StoragePathHelper
{
    /// <summary>
    /// Returns the storage path: appSetting "AppDataStoragePath" if set,
    /// otherwise the provided default (typically Server.MapPath("~/App_Data")).
    /// </summary>
    public static string Resolve(string defaultPath)
    {
        string configPath = ConfigurationManager.AppSettings["AppDataStoragePath"];
        if (!string.IsNullOrWhiteSpace(configPath))
            return configPath.Trim();
        return defaultPath;
    }

    /// <summary>
    /// Ensures the directory exists and is writable by the current process identity.
    /// On failure, throws an InvalidOperationException with the resolved identity,
    /// path, and remediation steps.
    /// </summary>
    public static void EnsureWritable(string path)
    {
        try
        {
            if (!Directory.Exists(path))
                Directory.CreateDirectory(path);

            // Verify actual write access with a temp file
            string testFile = Path.Combine(path, ".write_test_" + Guid.NewGuid().ToString("N"));
            File.WriteAllText(testFile, "ok");
            File.Delete(testFile);
        }
        catch (UnauthorizedAccessException ex)
        {
            string identity = WindowsIdentity.GetCurrent().Name;
            throw new InvalidOperationException(
                string.Format(
                    "PERMISSION ERROR - Storage path is not writable.\n" +
                    "  Path     : {0}\n" +
                    "  Identity : {1}\n" +
                    "  Fix      : Grant Modify permission to '{1}' on folder '{0}'.\n" +
                    "             icacls \"{0}\" /grant \"{1}\":(OI)(CI)M\n" +
                    "  Alt fix  : Set appSetting 'AppDataStoragePath' in web.config to a writable folder.\n" +
                    "  Original : {2}",
                    path, identity, ex.Message),
                ex);
        }
        catch (IOException ex)
        {
            string identity = WindowsIdentity.GetCurrent().Name;
            throw new InvalidOperationException(
                string.Format(
                    "IO ERROR - Cannot create or write to storage path.\n" +
                    "  Path     : {0}\n" +
                    "  Identity : {1}\n" +
                    "  Error    : {2}",
                    path, identity, ex.Message),
                ex);
        }
    }
}
