using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace DaFeiYuBuild
{
    // 归档格式：exe 自身末尾追加
    //   [所有文件原始字节][manifest.json][8 字节 manifest 长度][8 字节 manifest 偏移][8 字节 magic]
    // 不解压未知内容，逐文件边写边算 SHA256，与 manifest 比对，任何不符立即中止。
    static class Pkg
    {
        public const string Magic = "DSHLPKG1";
        public const int TrailerSize = 24;

        public class Entry
        {
            public string p { get; set; }   // 相对路径
            public long s { get; set; }     // 字节数
            public long o { get; set; }     // 数据在归档中的偏移
            public string h { get; set; }   // sha256 hex
        }

        public class Manifest
        {
            public List<Entry> files { get; set; }
            public long total { get; set; }
        }

        public static string SelfPath()
        {
            return System.Reflection.Assembly.GetExecutingAssembly().Location;
        }

        public static Manifest ReadManifest()
        {
            string self = SelfPath();
            using (var fs = new FileStream(self, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            {
                if (fs.Length < TrailerSize) throw new Exception("归档不完整");
                fs.Seek(fs.Length - TrailerSize, SeekOrigin.Begin);
                var tr = new byte[TrailerSize];
                fs.Read(tr, 0, TrailerSize);
                long manLen = BitConverter.ToInt64(tr, 0);
                long manOff = BitConverter.ToInt64(tr, 8);
                string magic = Encoding.ASCII.GetString(tr, 16, 8);
                if (magic != Magic) throw new Exception("找不到归档标记（这个 exe 没有被追加数据）");
                if (manOff < 0 || manLen <= 0 || manOff + manLen > fs.Length) throw new Exception("归档索引损坏");

                fs.Seek(manOff, SeekOrigin.Begin);
                var buf = new byte[manLen];
                int read = 0;
                while (read < manLen)
                {
                    int n = fs.Read(buf, read, (int)(manLen - read));
                    if (n <= 0) break;
                    read += n;
                }
                string json = Encoding.UTF8.GetString(buf, 0, read);
                var ser = new JavaScriptSerializer();
                ser.MaxJsonLength = int.MaxValue;
                var m = ser.Deserialize<Manifest>(json);
                if (m == null || m.files == null || m.files.Count == 0) throw new Exception("归档清单为空");
                return m;
            }
        }

        /// 解压全部文件到 destRoot，逐文件校验 SHA256。
        public static void Extract(Manifest m, string destRoot, Action<string, int> progress)
        {
            string self = SelfPath();
            string full = Path.GetFullPath(destRoot);
            long done = 0;
            int index = 0;
            using (var src = new FileStream(self, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
            using (var sha = SHA256.Create())
            {
                var buffer = new byte[1 << 20];
                foreach (var e in m.files)
                {
                    index++;
                    string target = Path.Combine(full, e.p.Replace('/', '\\'));
                    string dir = Path.GetDirectoryName(target);
                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

                    src.Seek(e.o, SeekOrigin.Begin);
                    long left = e.s;
                    sha.Initialize();
                    using (var dst = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
                    {
                        while (left > 0)
                        {
                            int want = (int)Math.Min(buffer.Length, left);
                            int n = src.Read(buffer, 0, want);
                            if (n <= 0) throw new Exception("归档被截断：" + e.p);
                            dst.Write(buffer, 0, n);
                            sha.TransformBlock(buffer, 0, n, null, 0);
                            left -= n;
                            done += n;
                            if (progress != null) progress(e.p, (int)(done * 100 / Math.Max(1, m.total)));
                        }
                    }
                    sha.TransformFinalBlock(new byte[0], 0, 0);
                    string hex = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    if (!string.Equals(hex, e.h, StringComparison.OrdinalIgnoreCase))
                        throw new Exception("文件校验失败（可能被篡改或损坏）：" + e.p);
                }
            }
            if (progress != null) progress("完成", 100);
        }
    }

    static class Program
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AttachConsole(int dwProcessId);

        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--selftest")
            {
                Environment.ExitCode = SelfTest();
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }

        // 无人值守自检：解压到临时目录、校验全部哈希、报告文件数，然后删掉。
        static int SelfTest()
        {
            try { AttachConsole(-1); } catch { }   // winexe 无控制台，挂到父进程
            var logPath = Path.Combine(Path.GetTempPath(), "dafiyu-selftest.log");
            var sb = new StringBuilder();
            Action<string> say = delegate(string s) { sb.AppendLine(s); try { Console.WriteLine(s); } catch { } };

            string tmp = Path.Combine(Path.GetTempPath(), "dafiyu-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            int rc = 1;
            try
            {
                var m = Pkg.ReadManifest();
                say("archive files : " + m.files.Count);
                say("archive bytes : " + m.total);
                var sw = Stopwatch.StartNew();
                int last = -1;
                Pkg.Extract(m, tmp, delegate(string name, int pct)
                {
                    if (pct / 20 != last / 20) { say("  " + pct + "%  " + name); last = pct; }
                });
                sw.Stop();
                int found = Directory.GetFiles(tmp, "*", SearchOption.AllDirectories).Length;
                say("extracted     : " + found + " files in " + Math.Round(sw.Elapsed.TotalSeconds) + "s");
                say("all sha256    : MATCH");
                if (found != m.files.Count) { say("MISMATCH file count"); rc = 1; }
                else { say("SELFTEST OK"); rc = 0; }
                Directory.Delete(tmp, true);
            }
            catch (Exception ex)
            {
                say("SELFTEST FAIL: " + ex.Message);
                try { Directory.Delete(tmp, true); } catch { }
                rc = 1;
            }
            try { File.WriteAllText(logPath, sb.ToString(), Encoding.UTF8); } catch { }
            return rc;
        }
    }

    class MainForm : Form
    {
        const string Brand = "大肥鱼build整合";
        const string Version = "v1.0";
        static readonly string WorkRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DaFeiYuBuild");

        Pkg.Manifest manifest;
        string psExe = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        TextBox log;
        Label status;
        ProgressBar bar;
        Button btnInstall, btnAdv, btnVerify, btnDocs, btnUninstall, btnCancel;
        Panel adv;
        RadioButton rbAuto, rbManual;
        ComboBox cbModel;
        CheckedListBox clbPlugins;
        Process current;
        bool busy;

        static readonly string[] PluginNames = { "dsh-better-sidebar", "dsh-context", "dsh-whale-widget", "dshmarket" };
        static readonly string[] PluginDesc = {
            "侧边栏增强 (MIT, dsh-external)",
            "上下文可视化 (Apache-2.0, bowenliang123)",
            "余额小鲸鱼挂件 (MIT, MeteorNOX)",
            "插件市场 (MIT, fkysly & dsh-market)"
        };

        public MainForm()
        {
            Text = Brand + " · DSH 本地模型安装器 " + Version;
            ClientSize = new Size(800, 660);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Font = new Font("Microsoft YaHei UI", 9f);
            BackColor = Color.FromArgb(250, 250, 252);
            BuildUi();
            LoadManifest();
        }

        void BuildUi()
        {
            var brand = new Label();
            brand.Text = Brand;
            brand.Font = new Font("Microsoft YaHei UI", 22f, FontStyle.Bold);
            brand.ForeColor = Color.FromArgb(30, 34, 45);
            brand.SetBounds(30, 18, 620, 42);
            Controls.Add(brand);

            var sub = new Label();
            sub.Text = "DSH 本地模型 · 单文件安装包 " + Version + "　·　llama.cpp + Qwen3-VL + 调用规则 + 4 个插件";
            sub.ForeColor = Color.FromArgb(110, 115, 130);
            sub.SetBounds(32, 62, 740, 20);
            Controls.Add(sub);

            var sub2 = new Label();
            sub2.Text = "全程离线。所有内容先解压并逐个校验 SHA256，校验失败立即中止。";
            sub2.ForeColor = Color.FromArgb(110, 115, 130);
            sub2.SetBounds(32, 82, 740, 20);
            Controls.Add(sub2);

            btnInstall = new Button();
            btnInstall.Text = "一 键 安 装";
            btnInstall.Font = new Font("Microsoft YaHei UI", 20f, FontStyle.Bold);
            btnInstall.SetBounds(32, 112, 736, 88);
            btnInstall.BackColor = Color.FromArgb(46, 120, 220);
            btnInstall.ForeColor = Color.White;
            btnInstall.FlatStyle = FlatStyle.Flat;
            btnInstall.FlatAppearance.BorderSize = 0;
            btnInstall.Click += delegate { DoInstall(); };
            Controls.Add(btnInstall);

            btnAdv = new Button();
            btnAdv.Text = "高级选项 ▾";
            btnAdv.SetBounds(32, 210, 140, 30);
            btnAdv.FlatStyle = FlatStyle.Flat;
            btnAdv.Click += delegate { ToggleAdv(); };
            Controls.Add(btnAdv);

            btnDocs = new Button();
            btnDocs.Text = "阅读文档（说明 / 第三方声明 / 免责）";
            btnDocs.SetBounds(182, 210, 300, 30);
            btnDocs.FlatStyle = FlatStyle.Flat;
            btnDocs.Click += delegate { OpenDocs(); };
            Controls.Add(btnDocs);

            btnUninstall = new Button();
            btnUninstall.Text = "卸载";
            btnUninstall.SetBounds(700, 210, 68, 30);
            btnUninstall.FlatStyle = FlatStyle.Flat;
            btnUninstall.Click += delegate { DoUninstall(); };
            Controls.Add(btnUninstall);

            adv = new Panel();
            adv.SetBounds(32, 246, 736, 196);
            adv.Visible = false;
            adv.BackColor = Color.White;
            adv.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(adv);

            var grpModel = new GroupBox();
            grpModel.Text = "模型";
            grpModel.SetBounds(10, 8, 710, 78);
            adv.Controls.Add(grpModel);

            rbAuto = new RadioButton();
            rbAuto.Text = "自动选择（按显存与内存判断，推荐）";
            rbAuto.SetBounds(14, 22, 320, 22);
            rbAuto.Checked = true;
            rbAuto.CheckedChanged += delegate { cbModel.Enabled = rbManual.Checked; };
            grpModel.Controls.Add(rbAuto);

            rbManual = new RadioButton();
            rbManual.Text = "手动指定（可能爆显存，后果自负）";
            rbManual.SetBounds(14, 48, 320, 22);
            grpModel.Controls.Add(rbManual);

            cbModel = new ComboBox();
            cbModel.DropDownStyle = ComboBoxStyle.DropDownList;
            cbModel.Items.AddRange(new object[] {
                "Qwen3-VL-4B —— 质量最好，需约 3.0 GB 空闲显存",
                "Qwen3-VL-2B —— 更快更省，需约 1.5 GB",
                "不部署任何模型 —— 只装网关"
            });
            cbModel.SelectedIndex = 0;
            cbModel.SetBounds(350, 46, 346, 24);
            cbModel.Enabled = false;
            grpModel.Controls.Add(cbModel);

            var grpPlugins = new GroupBox();
            grpPlugins.Text = "插件（默认全不装，勾选后才装）";
            grpPlugins.SetBounds(10, 92, 710, 56);
            adv.Controls.Add(grpPlugins);

            clbPlugins = new CheckedListBox();
            clbPlugins.SetBounds(10, 18, 688, 32);
            clbPlugins.MultiColumn = true;
            clbPlugins.ColumnWidth = 344;
            clbPlugins.CheckOnClick = true;
            for (int i = 0; i < PluginNames.Length; i++)
                clbPlugins.Items.Add(PluginNames[i] + "  —— " + PluginDesc[i]);
            grpPlugins.Controls.Add(clbPlugins);

            btnVerify = new Button();
            btnVerify.Text = "联网校验文件（对照上游公布哈希）";
            btnVerify.SetBounds(14, 156, 320, 28);
            btnVerify.Click += delegate { DoVerify(); };
            adv.Controls.Add(btnVerify);

            var hint = new Label();
            hint.Text = "只读取哈希，不上传任何本地数据";
            hint.ForeColor = Color.Gray;
            hint.SetBounds(346, 162, 340, 20);
            adv.Controls.Add(hint);

            status = new Label();
            status.Text = "就绪";
            status.SetBounds(32, 450, 560, 20);
            status.ForeColor = Color.FromArgb(90, 95, 110);
            Controls.Add(status);

            btnCancel = new Button();
            btnCancel.Text = "中止";
            btnCancel.SetBounds(700, 446, 68, 28);
            btnCancel.Enabled = false;
            btnCancel.Click += delegate { CancelRunning(); };
            Controls.Add(btnCancel);

            bar = new ProgressBar();
            bar.SetBounds(32, 474, 736, 18);
            bar.Minimum = 0;
            bar.Maximum = 100;
            Controls.Add(bar);

            log = new TextBox();
            log.Multiline = true;
            log.ScrollBars = ScrollBars.Vertical;
            log.ReadOnly = true;
            log.SetBounds(32, 500, 736, 128);
            log.BackColor = Color.FromArgb(28, 30, 36);
            log.ForeColor = Color.FromArgb(210, 214, 220);
            log.Font = new Font("Consolas", 8.5f);
            log.WordWrap = true;
            Controls.Add(log);
        }

        void LoadManifest()
        {
            try
            {
                manifest = Pkg.ReadManifest();
                Append("内嵌归档：" + manifest.files.Count + " 个文件，" +
                       Math.Round(manifest.total / 1073741824.0, 2) + " GB");
                Append("安装时先解压并逐个校验 SHA256，任一不符立即中止。");
            }
            catch (Exception ex)
            {
                btnInstall.Enabled = false;
                btnVerify.Enabled = false;
                btnUninstall.Enabled = false;
                Append("! 读取内嵌归档失败：" + ex.Message);
                MessageBox.Show("这个 exe 的归档读不出来：\r\n\r\n" + ex.Message +
                                "\r\n\r\n文件可能在传输中被截断，请重新获取。",
                                Brand, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        void Append(string line)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(Append), line); return; }
            log.AppendText(line + Environment.NewLine);
        }

        void SetStatus(string s)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(SetStatus), s); return; }
            status.Text = s;
        }

        void SetBar(int v)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<int>(SetBar), v); return; }
            bar.Value = Math.Max(0, Math.Min(100, v));
        }

        void SetBusy(bool b)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<bool>(SetBusy), b); return; }
            busy = b;
            btnInstall.Enabled = !b;
            btnAdv.Enabled = !b;
            btnDocs.Enabled = !b;
            btnUninstall.Enabled = !b;
            btnVerify.Enabled = !b;
            btnCancel.Enabled = b;
        }

        void ToggleAdv()
        {
            adv.Visible = !adv.Visible;
            btnAdv.Text = adv.Visible ? "高级选项 ▴" : "高级选项 ▾";
        }

        string ModelArg()
        {
            if (!rbManual.Checked) return "";
            switch (cbModel.SelectedIndex)
            {
                case 0: return " -ForceProfile 4b";
                case 1: return " -ForceProfile 2b";
                default: return " -ForceProfile none";
            }
        }

        string PluginArg()
        {
            var sb = new StringBuilder();
            foreach (object item in clbPlugins.CheckedItems)
            {
                string name = item.ToString().Split(' ')[0];
                if (sb.Length > 0) sb.Append(",");
                sb.Append(name);
            }
            if (sb.Length == 0) return "";
            return " -WithPlugins -PluginNames \"" + sb + "\"";
        }

        // 保证归档已解压到 WorkRoot/package，返回该目录
        string EnsureExtracted()
        {
            string pkgRoot = Path.Combine(WorkRoot, "package");
            string marker = Path.Combine(WorkRoot, ".extracted");
            if (File.Exists(marker) && File.Exists(Path.Combine(pkgRoot, "install.ps1")))
                return pkgRoot;

            SetStatus("正在解压并校验…");
            Append("解压到 " + pkgRoot);
            if (Directory.Exists(pkgRoot)) Directory.Delete(pkgRoot, true);
            Pkg.Extract(manifest, pkgRoot, delegate(string name, int pct)
            {
                SetBar(pct);
                if (pct % 5 == 0) SetStatus("解压校验中 " + pct + "%  " + name);
            });
            Directory.CreateDirectory(WorkRoot);
            File.WriteAllText(marker, DateTime.Now.ToString("o"));
            Append("解压完成，全部文件 SHA256 校验通过。");
            return pkgRoot;
        }

        void DoInstall()
        {
            if (busy || manifest == null) return;
            string msg =
                Brand + " 将执行：\r\n\r\n" +
                "  1. 解压内嵌归档到 %LOCALAPPDATA%\\DaFeiYuBuild（约 " +
                Math.Round(manifest.total / 1073741824.0, 2) + " GB）并逐个校验 SHA256\r\n" +
                "  2. 把文件铺到 %LOCALAPPDATA%\\dsh-local-llm\r\n" +
                "  3. 在 DSH 的 cordis.patch.yml 追加标记块（改前备份）\r\n" +
                "  4. 在 ~\\.dsh\\AGENTS.md 追加调用规则块（改前备份）\r\n" +
                "  5. 「启动」文件夹建快捷方式，并跑一次自检\r\n\r\n" +
                "不写注册表、不装服务、不提权、不联网。\r\n" +
                "安装过程需要约 9 GB 空闲磁盘（解压副本会在完成后删除）。\r\n\r\n继续？";
            if (rbManual.Checked) msg += "\r\n注意：你选了手动指定模型，显存不足会启动失败。\r\n";
            if (MessageBox.Show(msg, "确认安装", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK)
                return;

            SetBusy(true);
            SetBar(0);
            string pkgRoot;
            try { pkgRoot = EnsureExtracted(); }
            catch (Exception ex)
            {
                SetBusy(false);
                Append("! 解压失败：" + ex.Message);
                MessageBox.Show("解压或校验失败：\r\n\r\n" + ex.Message, Brand, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            RunScript(Path.Combine(pkgRoot, "install.ps1"), "-Apply" + ModelArg() + PluginArg(), "安装中…");
        }

        void DoUninstall()
        {
            if (busy) return;
            if (MessageBox.Show(
                "将停掉网关、删除安装目录、清理 DSH 配置标记块与自启动快捷方式。\r\n\r\n继续？",
                "确认卸载", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
                return;
            SetBusy(true);
            string pkgRoot;
            try { pkgRoot = EnsureExtracted(); }
            catch (Exception ex) { SetBusy(false); MessageBox.Show("解压失败：" + ex.Message, Brand); return; }
            RunScript(Path.Combine(pkgRoot, "uninstall.ps1"), "-Apply", "卸载中…");
        }

        void DoVerify()
        {
            if (busy) return;
            SetBusy(true);
            string pkgRoot;
            try { pkgRoot = EnsureExtracted(); }
            catch (Exception ex) { SetBusy(false); MessageBox.Show("解压失败：" + ex.Message, Brand); return; }
            RunScript(Path.Combine(pkgRoot, "verify.ps1"), "-CheckUpstream", "校验中（会访问 GitHub / ModelScope）…", true);
        }

        void OpenDocs()
        {
            string pkgRoot = Path.Combine(WorkRoot, "package");
            string[] docs = { "DISCLAIMER.md", "THIRD-PARTY-NOTICES.md", "README.md" };
            int opened = 0;
            foreach (string d in docs)
            {
                string p = Path.Combine(pkgRoot, d);
                if (!File.Exists(p)) continue;
                try { Process.Start("notepad.exe", "\"" + p + "\""); opened++; } catch { }
            }
            if (opened == 0)
            {
                if (MessageBox.Show("文档还没解压出来。现在解压？（约需数秒）", Brand,
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
                    return;
                try { EnsureExtracted(); } catch (Exception ex) { MessageBox.Show("解压失败：" + ex.Message, Brand); return; }
                OpenDocs();
            }
        }

        void RunScript(string scriptPath, string args, string label) { RunScript(scriptPath, args, label, false); }

        void RunScript(string scriptPath, string args, string label, bool thenPlugins)
        {
            if (!File.Exists(scriptPath))
            {
                SetBusy(false);
                MessageBox.Show("找不到脚本：" + scriptPath, Brand, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            SetBusy(true);
            SetStatus(label);
            Append("> " + Path.GetFileName(scriptPath) + " " + args);

            var psi = new ProcessStartInfo(psExe);
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\" " + args;
            psi.WorkingDirectory = Path.GetDirectoryName(scriptPath);
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;

            var p = new Process();
            p.StartInfo = psi;
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Append(e.Data); };
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Append("! " + e.Data); };
            p.EnableRaisingEvents = true;
            p.Exited += delegate
            {
                int code = -1;
                try { code = p.ExitCode; } catch { }
                BeginInvoke(new Action<int>(c => Finish(c, thenPlugins)), code);
            };
            current = p;
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }

        void Finish(int code, bool thenPlugins)
        {
            Append("--- 退出码 " + code + " ---");
            if (thenPlugins && code == 0)
            {
                string pkgRoot = Path.Combine(WorkRoot, "package");
                string pv = Path.Combine(pkgRoot, "plugins-verify.ps1");
                if (File.Exists(pv)) { RunScript(pv, "", "校验插件中（会访问 npm registry）…", false); return; }
            }
            SetBusy(false);
            SetStatus(code == 0 ? "完成" : "结束（退出码 " + code + "，请看上方输出）");
            if (code == 0) SetBar(100);
            current = null;
        }

        void CancelRunning()
        {
            if (current != null && !current.HasExited)
            {
                try { current.Kill(); } catch { }
                Append("! 已中止");
            }
            current = null;
            SetBusy(false);
            SetStatus("已中止");
        }
    }
}
