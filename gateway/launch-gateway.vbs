' DSH local GGUF gateway launcher.
'
' Resolves node.exe, then starts gateway.js with no console window. Used by the
' "DSH Local LLM Gateway" scheduled task at logon; run it by hand any time with
' gateway-control.cmd start.
Option Explicit

Dim fso, sh, base, logDir, logFile, candidates, i, nodePath, args, stream

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

base = fso.GetParentFolderName(WScript.ScriptFullName)
logDir = base & "\logs"
If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)
logFile = logDir & "\launcher.log"

If Not fso.FileExists(base & "\gateway.js") Then
  Set stream = fso.OpenTextFile(logFile, 8, True)
  stream.WriteLine Now & "  gateway.js is missing next to the launcher"
  stream.Close
  WScript.Quit 1
End If

' The DSH bundled runtime first, then a system-wide Node if DSH ever moves its own.
candidates = Array( _
  sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe", _
  sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\nodejs\node.exe", _
  sh.ExpandEnvironmentStrings("%ProgramFiles(x86)%") & "\nodejs\node.exe", _
  sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\nodejs\node.exe" _
)

nodePath = ""
For i = 0 To UBound(candidates)
  If nodePath = "" Then
    If fso.FileExists(candidates(i)) Then nodePath = candidates(i)
  End If
Next

If nodePath = "" Then
  Set stream = fso.OpenTextFile(logFile, 8, True)
  stream.WriteLine Now & "  no node.exe found; checked " & Join(candidates, "; ")
  stream.Close
  WScript.Quit 1
End If

args = """" & nodePath & """ """ & base & "\gateway.js"""
Set stream = fso.OpenTextFile(logFile, 8, True)
stream.WriteLine Now & "  launching: " & args
stream.Close

' 0 = hidden window, False = do not wait for it to finish.
sh.Run args, 0, False
