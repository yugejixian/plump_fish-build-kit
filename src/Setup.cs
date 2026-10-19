using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace DshLocalLlmSetup
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
        readonly string root;
        readonly string psExe = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        TextBox log;
        Label status;
        Button btnInstall, btnAdv, btnVerify, btnDocs, btnUninstall, btnCancel;
        Panel adv;
        RadioButton rbAuto, rbManual;
        ComboBox cbModel;
        CheckedListBox clbPlugins;
        Process current;
        bool busy;

        static readonly string[] PluginNames = {
            "dsh-better-sidebar", "dsh-context", "dsh-whale-widget", "dshmarket"
        };
        static readonly string[] PluginDesc = {
            "侧边栏增强 (MIT, dsh-external)",
            "上下文可视化 (Apache-2.0, bowenliang123)",
            "余额小鲸鱼挂件 (MIT, MeteorNOX)",
            "插件市场 (MIT, fkysly & dsh-market)"
        };

        public MainForm()
        {
            root = Application.StartupPath;
            Text = "DSH 本地模型安装器";
            ClientSize = new Size(780, 620);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Font = new Font("Microsoft YaHei UI", 9f);
            BackColor = Color.FromArgb(250, 250, 252);

            BuildUi();
            CheckPayload();
        }

        void BuildUi()
        {
            var title = new Label();
            title.Text = "本地模型 · 离线安装包";
            title.Font = new Font("Microsoft YaHei UI", 18f, FontStyle.Bold);
            title.ForeColor = Color.FromArgb(30, 34, 45);
            title.SetBounds(30, 22, 500, 38);
            Controls.Add(title);

            var sub = new Label();
            sub.Text = "llama.cpp + Qwen3-VL + 调用规则 + 4 个插件　·　全程离线，安装器不联网";
            sub.ForeColor = Color.FromArgb(110, 115, 130);
            sub.SetBounds(32, 62, 700, 20);
            Controls.Add(sub);

            btnInstall = new Button();
            btnInstall.Text = "一 键 安 装";
            btnInstall.Font = new Font("Microsoft YaHei UI", 20f, FontStyle.Bold);
            btnInstall.SetBounds(32, 96, 716, 92);
            btnInstall.BackColor = Color.FromArgb(46, 120, 220);
            btnInstall.ForeColor = Color.White;
            btnInstall.FlatStyle = FlatStyle.Flat;
            btnInstall.FlatAppearance.BorderSize = 0;
            btnInstall.Click += delegate { DoInstall(); };
            Controls.Add(btnInstall);

            btnAdv = new Button();
            btnAdv.Text = "高级选项 ▾";
            btnAdv.SetBounds(32, 198, 140, 30);
            btnAdv.FlatStyle = FlatStyle.Flat;
            btnAdv.Click += delegate { ToggleAdv(); };
            Controls.Add(btnAdv);

            btnDocs = new Button();
            btnDocs.Text = "阅读文档（说明 / 第三方声明 / 免责）";
            btnDocs.SetBounds(182, 198, 300, 30);
            btnDocs.FlatStyle = FlatStyle.Flat;
            btnDocs.Click += delegate { OpenDocs(); };
            Controls.Add(btnDocs);

            btnUninstall = new Button();
            btnUninstall.Text = "卸载";
            btnUninstall.SetBounds(680, 198, 68, 30);
            btnUninstall.FlatStyle = FlatStyle.Flat;
            btnUninstall.Click += delegate { DoUninstall(); };
            Controls.Add(btnUninstall);

            adv = new Panel();
            adv.SetBounds(32, 234, 716, 190);
            adv.Visible = false;
            adv.BackColor = Color.White;
            adv.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(adv);

            var grpModel = new GroupBox();
            grpModel.Text = "模型";
            grpModel.SetBounds(10, 8, 690, 74);
            adv.Controls.Add(grpModel);

            rbAuto = new RadioButton();
            rbAuto.Text = "自动选择（按显存与内存判断，推荐）";
            rbAuto.SetBounds(14, 22, 320, 22);
            rbAuto.Checked = true;
            rbAuto.CheckedChanged += delegate { UpdateModelUi(); };
            grpModel.Controls.Add(rbAuto);

            rbManual = new RadioButton();
            rbManual.Text = "手动指定（可能爆显存，后果自负）";
            rbManual.SetBounds(14, 46, 320, 22);
            rbManual.CheckedChanged += delegate { UpdateModelUi(); };
            grpModel.Controls.Add(rbManual);

            cbModel = new ComboBox();
            cbModel.DropDownStyle = ComboBoxStyle.DropDownList;
            cbModel.Items.AddRange(new object[] {
                "Qwen3-VL-4B  —— 质量最好，需 ~3.0 GB 空闲显存",
                "Qwen3-VL-2B  —— 更快更省，需 ~1.5 GB",
                "不部署任何模型 —— 只装网关"
            });
            cbModel.SelectedIndex = 0;
            cbModel.SetBounds(350, 44, 330, 24);
            cbModel.Enabled = false;
            grpModel.Controls.Add(cbModel);

            var grpPlugins = new GroupBox();
            grpPlugins.Text = "插件（默认全不装，勾选后才装）";
            grpPlugins.SetBounds(10, 88, 690, 58);
            adv.Controls.Add(grpPlugins);

            clbPlugins = new CheckedListBox();
            clbPlugins.SetBounds(10, 18, 668, 34);
            clbPlugins.MultiColumn = true;
            clbPlugins.ColumnWidth = 330;
            clbPlugins.CheckOnClick = true;
            for (int i = 0; i < PluginNames.Length; i++)
                clbPlugins.Items.Add(PluginNames[i] + "  —— " + PluginDesc[i]);
            grpPlugins.Controls.Add(clbPlugins);

            btnVerify = new Button();
            btnVerify.Text = "联网校验文件（对照上游公布哈希）";
            btnVerify.SetBounds(14, 152, 320, 30);
            btnVerify.Click += delegate { DoVerify(); };
            adv.Controls.Add(btnVerify);

            var hint = new Label();
            hint.Text = "校验只读取哈希，不上传任何本地数据";
            hint.ForeColor = Color.Gray;
            hint.SetBounds(346, 158, 330, 20);
            adv.Controls.Add(hint);

            status = new Label();
            status.Text = "就绪";
            status.SetBounds(32, 432, 500, 20);
            status.ForeColor = Color.FromArgb(90, 95, 110);
            Controls.Add(status);

            btnCancel = new Button();
            btnCancel.Text = "中止";
            btnCancel.SetBounds(680, 428, 68, 28);
            btnCancel.Enabled = false;
            btnCancel.Click += delegate { CancelRunning(); };
            Controls.Add(btnCancel);

            log = new TextBox();
            log.Multiline = true;
            log.ScrollBars = ScrollBars.Vertical;
            log.ReadOnly = true;
            log.SetBounds(32, 456, 716, 146);
            log.BackColor = Color.FromArgb(28, 30, 36);
            log.ForeColor = Color.FromArgb(210, 214, 220);
            log.Font = new Font("Consolas", 8.5f);
            log.WordWrap = true;
            Controls.Add(log);
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
            foreach (Control c in adv.Controls) c.Enabled = !b;
            if (!b) adv.Enabled = true;
        }

        void CheckPayload()
        {
            string payload = Path.Combine(root, "payload");
            string install = Path.Combine(root, "install.ps1");
            if (!Directory.Exists(payload) || !File.Exists(install))
            {
                btnInstall.Enabled = false;
                btnUninstall.Enabled = false;
                btnVerify.Enabled = false;
                SetStatus("找不到 payload\\ 或 install.ps1");
                log.AppendText("这个 exe 需要和 payload 文件夹放在一起。" + Environment.NewLine);
                log.AppendText("当前目录：" + root + Environment.NewLine);
                MessageBox.Show(
                    "安装包不完整：需要与 payload\\ 文件夹、install.ps1 放在同一个目录。\r\n\r\n" +
                    "请把整个安装包文件夹解压到一处再运行本程序。",
                    "缺少文件", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        void UpdateModelUi()
        {
            cbModel.Enabled = rbManual.Checked;
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

        void DoInstall()
        {
            if (busy) return;
            string msg =
                "将执行以下动作：\r\n\r\n" +
                "  · 把 payload 复制到 %LOCALAPPDATA%\\dsh-local-llm\r\n" +
                "  · 在 DSH 的 cordis.patch.yml 追加一个标记块（改前备份）\r\n" +
                "  · 在 ~\\.dsh\\AGENTS.md 追加调用规则块（改前备份）\r\n" +
                "  · 在「启动」文件夹建一个快捷方式\r\n" +
                "  · 跑一次自检\r\n\r\n" +
                "不写注册表、不装服务、不提权、不联网。\r\n" +
                "卸载时可完全回滚。\r\n\r\n继续？";

            if (rbManual.Checked)
                msg += "\r\n注意：你选择了手动指定模型，装了之后若显存不足会启动失败。\r\n";

            if (MessageBox.Show(msg, "确认安装", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK)
                return;

            RunScript(Path.Combine(root, "install.ps1"), "-Apply" + ModelArg() + PluginArg(), "安装中…");
        }

        void DoUninstall()
        {
            if (busy) return;
            if (MessageBox.Show(
                "将停掉网关、删除安装目录、清理 DSH 配置里的标记块与自启动快捷方式。\r\n\r\n继续？",
                "确认卸载", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
                return;
            RunScript(Path.Combine(root, "uninstall.ps1"), "-Apply", "卸载中…");
        }

        void DoVerify()
        {
            if (busy) return;
            RunScript(Path.Combine(root, "verify.ps1"), "-CheckUpstream", "校验中（会访问 GitHub / ModelScope）…", true);
        }

        void OpenDocs()
        {
            string[] docs = { "DISCLAIMER.md", "THIRD-PARTY-NOTICES.md", "README.md" };
            foreach (string d in docs)
            {
                string p = Path.Combine(root, d);
                if (File.Exists(p))
                {
                    try { Process.Start("notepad.exe", "\"" + p + "\""); } catch { }
                }
            }
            if (!File.Exists(Path.Combine(root, "DISCLAIMER.md")))
                MessageBox.Show("找不到文档文件。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        void RunScript(string scriptPath, string args, string label)
        {
            RunScript(scriptPath, args, label, false);
        }

        void RunScript(string scriptPath, string args, string label, bool thenPlugins)
        {
            if (!File.Exists(scriptPath))
            {
                MessageBox.Show("找不到脚本：" + scriptPath, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            SetBusy(true);
            SetStatus(label);
            log.AppendText("> " + Path.GetFileName(scriptPath) + " " + args + Environment.NewLine);

            var psi = new ProcessStartInfo(psExe);
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\" " + args;
            psi.WorkingDirectory = root;
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
            p.Exited += delegate
            {
                int code = -1;
                try { code = p.ExitCode; } catch { }
                BeginInvoke(new Action<int>(c => { Finish(c, thenPlugins); }), code);
            };
            p.EnableRaisingEvents = true;
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
                string pv = Path.Combine(root, "plugins-verify.ps1");
                if (File.Exists(pv))
                {
                    RunScript(pv, "", "校验插件中（会访问 npm registry）…", false);
                    return;
                }
            }
            SetBusy(false);
            SetStatus(code == 0 ? "完成" : "结束（退出码 " + code + "，请看上方输出）");
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
