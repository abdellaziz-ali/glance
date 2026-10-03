// Glance-Setup.exe stub. Embedded resources are extracted to %TEMP% and Install.ps1 is run
// with Windows PowerShell. Compiled by Build-Installer.ps1 using the csc.exe bundled with Windows.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Glance Setup")]
[assembly: AssemblyProduct("Glance")]
[assembly: AssemblyDescription("Glance installer - no dependencies, per-user install")]
[assembly: AssemblyVersion("__VERSION__.0.0")]
[assembly: AssemblyFileVersion("__VERSION__.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string work = Path.Combine(Path.GetTempPath(), "GlanceSetup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        try
        {
            Directory.CreateDirectory(work);
            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string res in asm.GetManifestResourceNames())
            {
                string target = Path.Combine(work, res);
                using (Stream s = asm.GetManifestResourceStream(res))
                using (FileStream f = File.Create(target)) { s.CopyTo(f); }
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                                     @"System32\WindowsPowerShell\v1.0\powershell.exe");
            string installPs1 = Path.Combine(work, "Install.ps1");
            // -File mode: arguments are literal, so wrap in double quotes (escaped) rather than single quotes.
            string setupArgs = string.Join(" ", args).Replace("\"", "\\\"");
            var psi = new ProcessStartInfo(ps,
                "-NoProfile -NoLogo -ExecutionPolicy Bypass -STA -File \"" + installPs1 + "\" -Source \"" + work + "\" -SetupArgs \"" + setupArgs + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = work
            };
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("Setup failed:\n\n" + ex.Message, "Glance Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { Directory.Delete(work, true); } catch { }
        }
    }
}
