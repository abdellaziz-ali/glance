// Glance.exe - native host for Glance.ps1.
// Embeds the script as a resource and runs it in an in-process Windows PowerShell 5.1 runspace on an STA thread.
// Compiled by Build.ps1 with the csc.exe that ships with the .NET Framework (C# 5 syntax only).
using System;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Glance")]
[assembly: AssemblyDescription("Always-on-top CPU, memory, GPU, disk and network monitor")]
[assembly: AssemblyProduct("Glance")]
[assembly: AssemblyCompany("Glance")]
[assembly: AssemblyCopyright("MIT")]
[assembly: AssemblyVersion("__VERSION__.0.0")]
[assembly: AssemblyFileVersion("__VERSION__.0.0")]

namespace Glance
{
    sealed class QuietHost : PSHost
    {
        readonly Guid id = Guid.NewGuid();
        public int ExitCode;
        public override CultureInfo CurrentCulture { get { return Thread.CurrentThread.CurrentCulture; } }
        public override CultureInfo CurrentUICulture { get { return Thread.CurrentThread.CurrentUICulture; } }
        public override Guid InstanceId { get { return id; } }
        public override string Name { get { return "Glance"; } }
        public override PSHostUserInterface UI { get { return null; } }
        public override Version Version { get { return Assembly.GetExecutingAssembly().GetName().Version; } }
        public override void EnterNestedPrompt() { }
        public override void ExitNestedPrompt() { }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
        public override void SetShouldExit(int exitCode) { ExitCode = exitCode; }
    }

    static class Program
    {
        [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

        static string LogPath
        {
            get { return Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Glance"), "error.log"); }
        }

        static void Log(string msg)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
                File.AppendAllText(LogPath, DateTime.Now.ToString("s") + " host: " + msg + Environment.NewLine);
            }
            catch { }
        }

        [STAThread]
        static int Main(string[] args)
        {
            bool headless = Environment.GetEnvironmentVariable("GLANCE_HEADLESS") == "1";
            if (headless) AttachConsole(-1);

            string exe = Assembly.GetExecutingAssembly().Location;
            string script;
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("Glance.ps1"))
            using (StreamReader r = new StreamReader(s))
                script = r.ReadToEnd();

            QuietHost host = new QuietHost();
            try
            {
                InitialSessionState iss = InitialSessionState.CreateDefault();
                iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                using (Runspace rs = RunspaceFactory.CreateRunspace(host, iss))
                {
                    rs.ApartmentState = ApartmentState.STA;
                    rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    rs.Open();
                    rs.SessionStateProxy.SetVariable("AppExe", exe);
                    using (PowerShell ps = PowerShell.Create())
                    {
                        ps.Runspace = rs;
                        ps.AddScript(script, false);
                        Collection<PSObject> output = ps.Invoke();
                        if (headless)
                        {
                            var lines = new System.Collections.Generic.List<string>();
                            foreach (PSObject o in output) lines.Add(o == null ? "" : o.ToString());
                            foreach (ErrorRecord e in ps.Streams.Error) lines.Add("ERROR: " + e);
                            foreach (string l in lines) Console.WriteLine(l);
                            string outFile = Environment.GetEnvironmentVariable("GLANCE_OUT");   // GUI exes can't be piped; tests read this file
                            if (!string.IsNullOrEmpty(outFile)) File.WriteAllLines(outFile, lines.ToArray());
                        }
                        else
                        {
                            foreach (ErrorRecord e in ps.Streams.Error) Log(e.ToString());
                        }
                    }
                }
            }
            catch (RuntimeException ex)
            {
                string where = ex.ErrorRecord != null && ex.ErrorRecord.InvocationInfo != null ? ex.ErrorRecord.InvocationInfo.PositionMessage : "";
                Log(ex.Message + Environment.NewLine + where);
                if (headless) Console.Error.WriteLine("FAILED: " + ex.Message + Environment.NewLine + where);
                else MessageBox.Show("Glance stopped unexpectedly:\n\n" + ex.Message + "\n\nDetails were written to\n" + LogPath, "Glance", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            catch (Exception ex)
            {
                Log(ex.ToString());
                if (headless) Console.Error.WriteLine("FAILED: " + ex);
                else MessageBox.Show("Glance could not start:\n\n" + ex.Message, "Glance", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            return host.ExitCode;
        }
    }
}
