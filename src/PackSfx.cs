using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace PackSfx
{
    // 把 <packageDir> 打成一个自解压 exe：<bootstrapper.exe> + [数据][manifest][trailer]
    class Entry
    {
        public string p { get; set; }
        public long s { get; set; }
        public long o { get; set; }
        public string h { get; set; }
    }

    class Manifest
    {
        public List<Entry> files { get; set; }
        public long total { get; set; }
        public string builtAt { get; set; }
    }

    static class Program
    {
        static int Main(string[] args)
        {
            if (args.Length < 3)
            {
                Console.WriteLine("usage: PackSfx.exe <bootstrapper.exe> <packageDir> <output.exe>");
                return 2;
            }
            string boot = Path.GetFullPath(args[0]);
            string dir = Path.GetFullPath(args[1]);
            string output = Path.GetFullPath(args[2]);

            if (!File.Exists(boot)) { Console.WriteLine("bootstrapper not found: " + boot); return 2; }
            if (!Directory.Exists(dir)) { Console.WriteLine("package dir not found: " + dir); return 2; }

            var files = new List<string>();
            foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
            {
                if (string.Equals(Path.GetFullPath(f), output, StringComparison.OrdinalIgnoreCase)) continue;
                files.Add(f);
            }
            files.Sort(StringComparer.OrdinalIgnoreCase);

            long total = 0;
            foreach (var f in files) total += new FileInfo(f).Length;
            Console.WriteLine("packaging " + files.Count + " files, " + Math.Round(total / 1073741824.0, 2) + " GB");

            var manifest = new Manifest { files = new List<Entry>(), total = total, builtAt = DateTime.Now.ToString("o") };
            var buffer = new byte[1 << 20];
            var sw = System.Diagnostics.Stopwatch.StartNew();

            using (var src = new FileStream(boot, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            using (var dst = new FileStream(output, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
            using (var sha = SHA256.Create())
            {
                src.CopyTo(dst, 1 << 20);
                long pos = dst.Position;
                int done = 0;

                foreach (var f in files)
                {
                    long size = new FileInfo(f).Length;
                    var e = new Entry
                    {
                        p = f.Substring(dir.Length).TrimStart('\\', '/').Replace('\\', '/'),
                        s = size,
                        o = pos,
                        h = null
                    };
                    sha.Initialize();
                    using (var input = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
                    {
                        long left = size;
                        while (left > 0)
                        {
                            int want = (int)Math.Min(buffer.Length, left);
                            int n = input.Read(buffer, 0, want);
                            if (n <= 0) throw new Exception("short read: " + f);
                            dst.Write(buffer, 0, n);
                            sha.TransformBlock(buffer, 0, n, null, 0);
                            left -= n;
                        }
                    }
                    sha.TransformFinalBlock(new byte[0], 0, 0);
                    e.h = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    manifest.files.Add(e);
                    pos += size;
                    done++;
                    if (done % 50 == 0 || done == files.Count)
                        Console.WriteLine("  " + done + "/" + files.Count + "  " + Math.Round(sw.Elapsed.TotalSeconds) + "s");
                }

                var ser = new JavaScriptSerializer();
                ser.MaxJsonLength = int.MaxValue;
                byte[] manBytes = Encoding.UTF8.GetBytes(ser.Serialize(manifest));
                long manOff = dst.Position;
                dst.Write(manBytes, 0, manBytes.Length);

                var tr = new byte[24];
                Array.Copy(BitConverter.GetBytes((long)manBytes.Length), 0, tr, 0, 8);
                Array.Copy(BitConverter.GetBytes(manOff), 0, tr, 8, 8);
                byte[] magic = Encoding.ASCII.GetBytes("DSHLPKG1");
                Array.Copy(magic, 0, tr, 16, 8);
                dst.Write(tr, 0, 24);
            }

            Console.WriteLine("done in " + Math.Round(sw.Elapsed.TotalSeconds) + "s");
            Console.WriteLine("output: " + output);
            Console.WriteLine("size  : " + Math.Round(new FileInfo(output).Length / 1073741824.0, 2) + " GB");
            return 0;
        }
    }
}
