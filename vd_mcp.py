#!/usr/bin/env python3
"""Codex stdio adapter for the installed VD app. All actions go through its CLI."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile

CLI = Path.home()/".local/bin/vd"
COMMANDS = ["start","status","doctor","permissions","apps","windows","move","launch","inspect","press","set","click","drag","scroll","type","key","screenshot","stop"]
TOOL = {"name":"vd","description":"Use the local Virtual Display CLI to operate another Mac app on the user's extended monitor. Get help for argument syntax. Screenshot accepts no arguments for the full display or PID WINDOW and returns an image directly. Verify each interaction by inspection or screenshot.","inputSchema":{"type":"object","properties":{"command":{"type":"string","enum":["help",*COMMANDS]},"arguments":{"type":"array","items":{"type":"string"}}},"required":["command"],"additionalProperties":False}}

OBSERVE_COMMANDS = ["status","permissions","apps","doctor","help"]
OBSERVE = {"name":"vd_observe","description":"Read VD status, privacy grants, running app inventory, display registrations or CLI help.","annotations":{"readOnlyHint":True,"destructiveHint":False},"inputSchema":{"type":"object","properties":{"command":{"type":"string","enum":OBSERVE_COMMANDS}},"required":["command"],"additionalProperties":False}}

VIEW = {"name":"vd_view","description":"View the running virtual display as a PNG, optionally scoped to one of its windows.","annotations":{"readOnlyHint":True,"destructiveHint":False},"inputSchema":{"type":"object","properties":{"pid":{"type":"integer","minimum":1},"window":{"type":"integer","minimum":1}},"additionalProperties":False}}

def run(params):
    if params.get("name") not in ("vd","vd_observe","vd_view"):raise ValueError("Unknown tool")
    fields=params.get("arguments",{})
    cmd=fields.get("command")
    if params["name"]=="vd_observe" and cmd not in OBSERVE_COMMANDS: raise ValueError("Expected an observation command")
    args=fields.get("arguments",[])
    if params["name"]=="vd_view":
        if set(fields) not in (set(),{"pid","window"}):raise ValueError("Specify both pid and window, or neither")
        args=[str(fields[k]) for k in ("pid","window") if k in fields]
        cmd="screenshot"
    if params["name"]=="vd_observe" and args:raise ValueError("Unexpected arguments")
    if cmd not in ["help",*COMMANDS] or not isinstance(args,list) or len(args)>8 or not all(isinstance(s,str) for s in args):raise ValueError("Invalid VD arguments")
    with tempfile.TemporaryDirectory() as directory:
        image=Path(directory)/"view.png"
        if cmd=="screenshot":
            if len(args) not in (0,2):raise ValueError("Expected no arguments or PID WINDOW")
            args=[*args,str(image)]
        proc=subprocess.run([CLI,cmd,*args],capture_output=True,text=True,timeout=60)
        if proc.returncode:return {"isError":True,"content":[{"type":"text","text":proc.stderr.strip() or proc.stdout.strip()}]}
        if cmd=="screenshot":
            return {"content":[{"type":"image","mimeType":"image/png","data":base64.b64encode(image.read_bytes()).decode("ascii")}]}
        return {"content":[{"type":"text","text":proc.stdout.strip()}]}

def serve(msg):
    method=msg.get("method")
    if method=="initialize":
        return {"protocolVersion":"2025-06-18","serverInfo":{"name":"virtual-display","version":"1.0"},"capabilities":{"tools":{}}}
    if method=="ping":return {}
    if method=="tools/list":return {"tools":[OBSERVE,VIEW,TOOL]}
    if method=="tools/call":return run(msg["params"])
    raise KeyError(method)

for line in sys.stdin:
    try:
        msg=json.loads(line)
        if "id" not in msg:continue
        reply={"jsonrpc":"2.0","id":msg["id"]}
        try:reply["result"]=serve(msg)
        except KeyError as exc:reply["error"]={"code":-32601,"message":str(exc)}
        except (ValueError,OSError,subprocess.SubprocessError) as exc:reply["error"]={"code":-32602,"message":str(exc)}
        print(json.dumps(reply),flush=True)
    except ValueError:continue
