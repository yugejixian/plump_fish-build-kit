using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace DaFeiYuStarter
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    class MainForm : Form
    {
        const string Brand = "新手向大肥鱼build整合";
        const string Sub = "双击就能装，不用联网，不用敲命令";

        readonly string root;
        readonly string psExe = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        ProgressBar bar;
        TextBox txtPath;
        Label lblSpace;
        TextBox log;
        Label status;
        Button btnInstall, btnAdv, btnUninstall, btnCancel;
        Panel adv;
        RadioButton rbAuto, rbManual;
        ComboBox cbModel;
        CheckedListBox clbPlugins;
        CheckBox chkSettings;
        TextBox txtDoc;
        Process current;
        Timer ticker;
        DateTime busyStart;
        string busyLabel = "";
        bool busy;

        static readonly string[] PluginNames = { "dsh-better-sidebar", "dsh-context", "dsh-whale-widget", "dshmarket" };
        static readonly string[] PluginDesc = {
            "sidebar enhancement  (MIT / dsh-external)",
            "context inspector     (Apache-2.0 / bowenliang123)",
            "balance widget        (MIT / MeteorNOX)",
            "plugin marketplace    (MIT / fkysly, dsh-market)"
        };

        public MainForm()
        {
            root = Application.StartupPath;
            Text = Brand + "  ·  Local LLM bootstrap for DSH";
            ClientSize = new Size(820, 760);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Font = new Font("Microsoft YaHei UI", 9f);
            BackColor = Color.FromArgb(250, 250, 252);
            BuildUi();
            FormClosing += delegate(object s, FormClosingEventArgs e)
            {
                if (!busy) return;
                var r = MessageBox.Show("安装还在进行中，现在关闭会中断。\r\n\r\n确定要中断吗？",
                                        Brand, MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (r != DialogResult.Yes) e.Cancel = true;
            };
            ticker = new Timer();
            ticker.Interval = 1000;
            ticker.Tick += delegate
            {
                if (!busy) return;
                int s = (int)Math.Max(0, (DateTime.Now - busyStart).TotalSeconds);
                SetStatus(busyLabel + "   已用时 " + s + " 秒");
            };
            CheckPayload();
            UpdateSpaceLabel();
        }

        void BuildUi()
        {
            var brand = new Label();
            brand.Text = Brand;
            brand.Font = new Font("Microsoft YaHei UI", 21f, FontStyle.Bold);
            brand.ForeColor = Color.FromArgb(28, 32, 42);
            brand.SetBounds(28, 16, 700, 40);
            Controls.Add(brand);

            var sub = new Label();
            sub.Text = Sub;
            sub.Font = new Font("Microsoft YaHei UI", 10.5f);
            sub.ForeColor = Color.FromArgb(105, 110, 125);
            sub.SetBounds(30, 58, 700, 22);
            Controls.Add(sub);

            var note = new Label();
            note.Text = "先装好 DSH 并运行过一次，再点下面的按钮就行。全程本机操作，不联网。";
            note.ForeColor = Color.FromArgb(130, 134, 148);
            note.SetBounds(30, 82, 760, 20);
            Controls.Add(note);

            btnInstall = new Button();
            btnInstall.Text = "一  键  安  装";
            btnInstall.Font = new Font("Microsoft YaHei UI", 21f, FontStyle.Bold);
            btnInstall.SetBounds(30, 112, 760, 96);
            btnInstall.BackColor = Color.FromArgb(46, 120, 220);
            btnInstall.ForeColor = Color.White;
            btnInstall.FlatStyle = FlatStyle.Flat;
            btnInstall.FlatAppearance.BorderSize = 0;
            btnInstall.Cursor = Cursors.Hand;
            btnInstall.Click += delegate { DoInstall(); };
            Controls.Add(btnInstall);

            var lblTo = new Label();
            lblTo.Text = "装到：";
            lblTo.SetBounds(30, 222, 60, 20);
            Controls.Add(lblTo);

            txtPath = new TextBox();
            txtPath.SetBounds(92, 220, 556, 24);
            txtPath.Text = DefaultInstallDir();
            txtPath.TextChanged += delegate { UpdateSpaceLabel(); };
            Controls.Add(txtPath);

            var btnBrowse = new Button();
            btnBrowse.Text = "更改…";
            btnBrowse.SetBounds(656, 219, 68, 26);
            btnBrowse.Click += delegate { PickFolder(); };
            Controls.Add(btnBrowse);

            lblSpace = new Label();
            lblSpace.SetBounds(92, 248, 700, 18);
            lblSpace.ForeColor = Color.FromArgb(120, 126, 140);
            Controls.Add(lblSpace);
            btnAdv = new Button();
            btnAdv.Text = "高级选项 ▾";
            btnAdv.SetBounds(30, 278, 130, 30);
            btnAdv.FlatStyle = FlatStyle.Flat;
            btnAdv.Click += delegate { ToggleAdv(); UpdateSpaceLabel(); };
            Controls.Add(btnAdv);

            btnUninstall = new Button();
            btnUninstall.Text = "卸载";
            btnUninstall.SetBounds(720, 278, 70, 30);
            btnUninstall.FlatStyle = FlatStyle.Flat;
            btnUninstall.Click += delegate { DoUninstall(); };
            Controls.Add(btnUninstall);

            // ---------- 高级选项：英文，按专业工具的样子排 ----------
            adv = new Panel();
            adv.SetBounds(30, 314, 760, 276);
            adv.Visible = false;
            adv.BackColor = Color.FromArgb(30, 33, 40);
            adv.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(adv);

            var advTitle = new Label();
            advTitle.Text = "ADVANCED OPTIONS";
            advTitle.Font = new Font("Consolas", 11f, FontStyle.Bold);
            advTitle.ForeColor = Color.FromArgb(120, 200, 255);
            advTitle.SetBounds(14, 8, 400, 20);
            adv.Controls.Add(advTitle);

            var advHint = new Label();
            advHint.Text = "for troubleshooting and power users.  read before you touch.";
            advHint.Font = new Font("Consolas", 8.5f);
            advHint.ForeColor = Color.FromArgb(130, 136, 150);
            advHint.SetBounds(14, 28, 600, 16);
            adv.Controls.Add(advHint);

            var grpModel = new GroupBox();
            grpModel.Text = "Model Selection";
            grpModel.Font = new Font("Segoe UI", 8.5f);
            grpModel.ForeColor = Color.FromArgb(200, 205, 215);
            grpModel.SetBounds(14, 50, 732, 78);
            adv.Controls.Add(grpModel);

            rbAuto = new RadioButton();
            rbAuto.Text = "auto-detect by VRAM / RAM  (recommended)";
            rbAuto.Font = new Font("Consolas", 9f);
            rbAuto.ForeColor = Color.FromArgb(225, 228, 235);
            rbAuto.SetBounds(12, 20, 380, 20);
            rbAuto.Checked = true;
            rbAuto.CheckedChanged += delegate { cbModel.Enabled = rbManual.Checked; };
            grpModel.Controls.Add(rbAuto);

            rbManual = new RadioButton();
            rbManual.Text = "manual override  [danger: may exceed VRAM, use at your own risk]";
            rbManual.Font = new Font("Consolas", 9f);
            rbManual.ForeColor = Color.FromArgb(255, 170, 120);
            rbManual.SetBounds(12, 44, 470, 20);
            grpModel.Controls.Add(rbManual);

            cbModel = new ComboBox();
            cbModel.DropDownStyle = ComboBoxStyle.DropDownList;
            cbModel.Font = new Font("Consolas", 8.5f);
            cbModel.Items.AddRange(new object[] {
                "Qwen3-VL-4B   best quality   / needs ~3.0 GB free VRAM",
                "Qwen3-VL-2B   faster, lighter / needs ~1.5 GB free VRAM",
                "none          gateway only, no weights"
            });
            cbModel.SelectedIndex = 0;
            cbModel.SetBounds(486, 42, 236, 22);
            cbModel.Enabled = false;
            grpModel.Controls.Add(cbModel);

            var grpPlugins = new GroupBox();
            grpPlugins.Text = "Plugins  (all ticked by default, untick to skip)";
            grpPlugins.Font = new Font("Segoe UI", 8.5f);
            grpPlugins.ForeColor = Color.FromArgb(200, 205, 215);
            grpPlugins.SetBounds(14, 134, 732, 56);
            adv.Controls.Add(grpPlugins);

            clbPlugins = new CheckedListBox();
            clbPlugins.SetBounds(10, 18, 712, 32);
            clbPlugins.Font = new Font("Consolas", 8f);
            clbPlugins.MultiColumn = true;
            clbPlugins.ColumnWidth = 356;
            clbPlugins.CheckOnClick = true;
            clbPlugins.BackColor = Color.FromArgb(38, 42, 50);
            clbPlugins.ForeColor = Color.FromArgb(220, 224, 230);
            for (int i = 0; i < PluginNames.Length; i++)
            {
                clbPlugins.Items.Add(PluginNames[i] + "  —  " + PluginDesc[i]);
                // the group title promises "all ticked by default"; they were not,
                // so a plain one-click install silently skipped every plugin
                clbPlugins.SetItemChecked(i, true);
            }
            grpPlugins.Controls.Add(clbPlugins);

            var btnVerify = new Button();
            btnVerify.Text = "Verify against upstream";
            btnVerify.Font = new Font("Consolas", 9f);
            btnVerify.SetBounds(14, 198, 210, 28);
            btnVerify.Click += delegate { DoVerify(); };
            adv.Controls.Add(btnVerify);

            var btnDocs = new Button();
            btnDocs.Text = "Licenses / Notices / Disclaimer";
            btnDocs.Font = new Font("Consolas", 9f);
            btnDocs.SetBounds(232, 198, 250, 28);
            btnDocs.Click += delegate { OpenDocs(); };
            adv.Controls.Add(btnDocs);

            var btnPkgVerify = new Button();
            btnPkgVerify.Text = "Verify local files";
            btnPkgVerify.Font = new Font("Consolas", 9f);
            btnPkgVerify.SetBounds(490, 198, 190, 28);
            btnPkgVerify.Click += delegate { DoLocalVerify(); };
            adv.Controls.Add(btnPkgVerify);

            chkSettings = new CheckBox();
            chkSettings.Text = "restore my plugin settings  [may reset the DSH welcome wizard — leave unticked unless needed]";
            chkSettings.Font = new Font("Consolas", 8.5f);
            chkSettings.ForeColor = Color.FromArgb(200, 205, 215);
            chkSettings.SetBounds(14, 232, 640, 18);
            chkSettings.Checked = false;
            adv.Controls.Add(chkSettings);
            var foot = new Label();
            foot.Text = "verification reads hashes only — no local data leaves this machine";
            foot.Font = new Font("Consolas", 8f);
            foot.ForeColor = Color.FromArgb(120, 126, 140);
            foot.SetBounds(14, 254, 640, 16);
            adv.Controls.Add(foot);

            status = new Label();
            status.Text = "准备就绪";
            bar = new ProgressBar();
            bar.Minimum = 0; bar.Maximum = 100; bar.Value = 0;
            bar.SetBounds(30, 572, 760, 16);
            Controls.Add(bar);
            status.SetBounds(30, 594, 560, 18);
            status.ForeColor = Color.FromArgb(90, 95, 110);
            Controls.Add(status);

            btnCancel = new Button();
            btnCancel.Text = "中止";
            btnCancel.SetBounds(720, 590, 70, 26);
            btnCancel.Enabled = false;
            btnCancel.Click += delegate { CancelRunning(); };
            Controls.Add(btnCancel);

            log = new TextBox();
            log.Multiline = true;
            log.ScrollBars = ScrollBars.Vertical;
            log.ReadOnly = true;
            log.SetBounds(30, 618, 760, 130);
            log.BackColor = Color.FromArgb(26, 28, 34);
            log.ForeColor = Color.FromArgb(200, 206, 214);
            log.Font = new Font("Consolas", 8.5f);
            log.WordWrap = true;
            Controls.Add(log);
        }

        void Append(string line)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(Append), line); return; }
            log.AppendText(line + Environment.NewLine);
            try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "dafiyu-gui.log"), line + "\r\n", Encoding.UTF8); } catch { }
            log.SelectionStart = log.TextLength;
            log.ScrollToCaret();
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
            btnUninstall.Enabled = !b;
            btnCancel.Enabled = b;
        }

        void CheckPayload()
        {
            string payload = Path.Combine(root, "payload");
            string install = Path.Combine(root, "install.ps1");
            if (!Directory.Exists(payload) || !File.Exists(install))
            {
                btnInstall.Enabled = false;
                btnUninstall.Enabled = false;
                SetStatus("找不到 payload 文件夹");
                Append("! 这个程序需要和 payload 文件夹放在一起。");
                MessageBox.Show(
                    "安装包不完整：需要把本程序与 payload 文件夹、install.ps1 放在同一个目录。\r\n\r\n" +
                    "如果你是从压缩包里直接双击的，请先整个解压出来再运行。",
                    Brand, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
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

        static string DefaultInstallDir()
        {
            string best = null; long bestFree = -1;
            const long minFree = 20L * 1024 * 1024 * 1024;
            foreach (var d in DriveInfo.GetDrives())
            {
                if (d.DriveType != DriveType.Fixed || !d.IsReady) continue;
                if (d.Name.StartsWith("C", StringComparison.OrdinalIgnoreCase)) continue;
                if (d.AvailableFreeSpace < minFree) continue;
                if (d.Name.StartsWith("D", StringComparison.OrdinalIgnoreCase)) { best = d.RootDirectory.FullName; break; }
                if (d.AvailableFreeSpace > bestFree) { bestFree = d.AvailableFreeSpace; best = d.RootDirectory.FullName; }
            }
            if (best == null)
                foreach (var d in DriveInfo.GetDrives())
                {
                    if (d.DriveType != DriveType.Fixed || !d.IsReady) continue;
                    if (d.AvailableFreeSpace < minFree) continue;
                    if (d.AvailableFreeSpace > bestFree) { bestFree = d.AvailableFreeSpace; best = d.RootDirectory.FullName; }
                }
            if (best == null) best = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(best, "DSH-LocalLLM");
        }

        long ModelSize(string name)
        {
            long fallback = 3800L * 1024 * 1024;
            try
            {
                string dir = Path.Combine(root, "payload", "models", name);
                if (!Directory.Exists(dir)) return fallback;
                long n = 0;
                foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) n += new FileInfo(f).Length;
                return n > 0 ? n : fallback;
            }
            catch { return fallback; }
        }

        long NeedBytes()
        {
            long need = 900L * 1024 * 1024;   // gateway + runtime(s): 713 MB CUDA plus a 48 MB CPU fallback
            if (rbManual.Checked)
            {
                if (cbModel.SelectedIndex == 0) need += ModelSize("qwen3-vl-4b");
                else if (cbModel.SelectedIndex == 1) need += ModelSize("qwen3-vl-2b");
            }
            else need += ModelSize("qwen3-vl-4b");
            return need;
        }

        void UpdateSpaceLabel()
        {
            try
            {
                string p = txtPath.Text.Trim();
                string rootPath = Path.GetPathRoot(p);
                if (string.IsNullOrEmpty(rootPath) || !Directory.Exists(rootPath)) { lblSpace.Text = "路径无效"; return; }
                var di = new DriveInfo(rootPath);
                long need = NeedBytes();
                long free = di.AvailableFreeSpace;
                lblSpace.Text = string.Format("{0} 可用 {1:N1} GB，预计需要 {2:N1} GB　{3}",
                    di.Name, free / 1073741824.0, need / 1073741824.0,
                    free > need ? "✓ 空间够" : "✗ 空间不足");
                lblSpace.ForeColor = free > need ? Color.FromArgb(50, 140, 85) : Color.FromArgb(200, 55, 55);
            }
            catch { lblSpace.Text = ""; }
        }

        void PickFolder()
        {
            using (var dlg = new FolderBrowserDialog())
            {
                dlg.Description = "选择安装位置（会在此目录下建 llama_cpp、models、gateway）";
                string cur = Path.GetPathRoot(txtPath.Text);
                if (!string.IsNullOrEmpty(cur)) dlg.SelectedPath = cur;
                if (dlg.ShowDialog(this) == DialogResult.OK)
                    txtPath.Text = Path.Combine(dlg.SelectedPath, "DSH-LocalLLM");
            }
        }

        void DoInstall()
        {
            if (busy) return;
            string target = txtPath.Text.Trim();
            string msg =
                "要做这些事：\r\n\r\n" +
                "  1. 把本地模型文件复制到 " + target + "\r\n" +
                "  2. 让 DSH 认识这个模型（会先备份原配置）\r\n" +
                "  3. 写入调用规则，建一个开机自启\r\n" +
                "  4. 自己跑一遍检查\r\n\r\n" +
                "不会改注册表，不会装服务，不会要管理员权限，不会联网。\r\n" +
                "装错了可以点「卸载」完整退回。\r\n\r\n现在开始？";
            if (rbManual.Checked)
                msg += "\r\n注意：你在高级选项里手动指定了模型，显存不够会启动失败。\r\n";
            if (target.Length < 3 || target.IndexOf(':') != 1)
            {
                MessageBox.Show("安装路径无效，请点「更改…」选一个位置。", Brand, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            try
            {
                long need = NeedBytes();
                long free = new DriveInfo(Path.GetPathRoot(target)).AvailableFreeSpace;
                if (free < need)
                {
                    MessageBox.Show(
                        string.Format("{0} 只剩 {1:N1} GB，本次安装大约需要 {2:N1} GB。\r\n\r\n请点「更改…」换到空间更大的磁盘。",
                            Path.GetPathRoot(target), free / 1073741824.0, need / 1073741824.0),
                        Brand, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("无法检查目标磁盘：" + ex.Message, Brand, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (MessageBox.Show(msg, Brand, MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK)
                return;
            RunScript(Path.Combine(root, "install.ps1"), "-Apply -TargetDir \"" + txtPath.Text.Trim() + "\"" + ModelArg() + PluginArg() + (chkSettings.Checked ? " -RestoreSettings" : ""), "正在安装…");
        }

        void DoUninstall()
        {
            if (busy) return;
            if (MessageBox.Show(
                "会停掉后台网关、删掉安装目录、清理 DSH 里加的配置和开机自启。\r\n\r\n继续？",
                Brand, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
                return;
            RunScript(Path.Combine(root, "uninstall.ps1"), "-Apply", "正在卸载…");
        }

        void DoLocalVerify()
        {
            if (busy) return;
            RunScript(Path.Combine(root, "verify.ps1"), "", "Verifying local files (offline)…");
        }

        void DoVerify()
        {
            if (busy) return;
            RunScript(Path.Combine(root, "verify.ps1"), "-CheckUpstream", "Verifying against upstream (online)…", true);
        }

        void OpenDocs()
        {
            string[] docs = { "RECOVERY.md", "DISCLAIMER.md", "THIRD-PARTY-NOTICES.md", "README.md", "UPSTREAM-VERIFIED.txt" };
            int n = 0;
            foreach (string d in docs)
            {
                string p = Path.Combine(root, d);
                if (!File.Exists(p)) continue;
                try { Process.Start("notepad.exe", "\"" + p + "\""); n++; } catch { }
            }
            if (n == 0)
                MessageBox.Show("Documentation files not found next to this program.",
                                Brand, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            else
                Append("> opened " + n + " document(s)");
        }

        void RunScript(string scriptPath, string args, string label) { RunScript(scriptPath, args, label, false); }

        void RunScript(string scriptPath, string args, string label, bool thenPlugins)
        {
            if (!File.Exists(scriptPath))
            {
                MessageBox.Show("找不到脚本：" + scriptPath, Brand, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            SetBusy(true);
            busyStart = DateTime.Now;
            SetStatus(label);
            Append("> " + Path.GetFileName(scriptPath) + " " + args);

            var psi = new ProcessStartInfo(psExe);
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\" " + args;
            psi.WorkingDirectory = root;
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            psi.StandardOutputEncoding = Encoding.GetEncoding(System.Globalization.CultureInfo.CurrentCulture.TextInfo.OEMCodePage);
            psi.StandardErrorEncoding = Encoding.GetEncoding(System.Globalization.CultureInfo.CurrentCulture.TextInfo.OEMCodePage);

            var p = new Process();
            p.StartInfo = psi;
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data == null) return;
                Append(e.Data);
                var mm = System.Text.RegularExpressions.Regex.Match(e.Data, @"^===\s*(\d)\.");
                if (mm.Success)
                {
                    int stage = int.Parse(mm.Groups[1].Value);
                    SetBar(Math.Min(95, stage * 11));
                }
            };
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
            busyLabel = label;
            ticker.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }

        void Finish(int code, bool thenPlugins)
        {
            bar.Value = 100;              // 无论如何先拉满，避免"看着卡在 95%"
            bar.Refresh();
            Append("--- exit " + code + " ---");
            if (thenPlugins && code == 0)
            {
                string pv = Path.Combine(root, "plugins-verify.ps1");
                if (File.Exists(pv)) { RunScript(pv, "", "Verifying plugins (registry.npmjs.org)...", false); return; }
            }
            ticker.Stop();
            SetBusy(false);
            int total = (int)Math.Max(0, (DateTime.Now - busyStart).TotalSeconds);
            Append("--- total " + total + " s ---");
            if (code == 0)
            {
                SetStatus("DONE - restart DSH to see the model");
                MessageBox.Show(
                    "安装完成。\r\n\r\n" +
                    "接下来：\r\n" +
                    "  1. 完全退出 DSH（托盘图标右键 → 退出）\r\n" +
                    "  2. 重新打开 DSH\r\n" +
                    "  3. 模型列表里会出现 local-gguf / local-vl\r\n\r\n" +
                    "耗时 " + total + " 秒。日志已保存到 %TEMP%\\dafiyu-gui.log",
                    Brand, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else
            {
                SetStatus("FAILED - exit code " + code);
                MessageBox.Show(
                    "安装没有成功（退出码 " + code + "）。\r\n\r\n" +
                    "上面黑框最后几行是原因。常见情况：\r\n" +
                    "  · 磁盘空间不足\r\n" +
                    "  · 目标目录被占用\r\n" +
                    "  · 端口 8099 被别的程序占用\r\n\r\n" +
                    "可以直接再点一次一键安装，重复安装是安全的。",
                    Brand, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            current = null;
        }

        void CancelRunning()
        {
            if (current != null && !current.HasExited)
            {
                try { current.Kill(); } catch { }
                Append("! aborted");
            }
            current = null;
            SetBusy(false);
            SetStatus("已中止");
        }
    }
}
