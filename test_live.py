"""Exercise the installed VD against a real, separately owned AppKit window."""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent

def vd(*args):
    return json.loads(subprocess.check_output(["vd",*map(str,args)],text=True))

def foreground():
    return subprocess.check_output(["lsappinfo","front"])

class LiveDisplay(unittest.TestCase):
    def test_native_window(self):
        display=vd("start")["display"]
        access=vd("permissions")
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp)
            probe=tmp/"probe"
            result=tmp/"press-result"
            subprocess.run(["swiftc",ROOT/"Probe.swift","-o",probe],check=True)
            before=foreground()
            proc=subprocess.Popen([probe,str(display),result],text=True,stdout=subprocess.PIPE)
            try:
                wid,x,y=map(int,proc.stdout.readline().split())
                for _ in range(25):
                    if any(w["window"]==wid and w["pid"]==proc.pid for w in vd("windows")["windows"]):break
                    time.sleep(.1)
                else:self.fail("Independent GUI window missing from virtual display")
                self.assertEqual(foreground(),before)
                print("PASS: native app visible on VD while foreground app stayed active.",flush=True)
                if access["screenRecording"]:
                    for args in [(proc.pid,wid),()]:
                        png=tmp/"actual.png"
                        png.unlink(missing_ok=True)
                        vd("screenshot",*args,png)
                        self.assertTrue(png.read_bytes().startswith(b"\x89PNG"))
                    print("PASS: window and full-display PNG capture.",flush=True)
                if not access["accessibility"]:
                    self.skipTest("Enable Accessibility to run the input assertions")
                controls=vd("inspect",proc.pid,wid)["controls"]
                button=next(c for c in controls if c["role"]=="AXButton" and c["title"]=="Verify click")
                vd("press",proc.pid,wid,button["id"])
                self.assertEqual(result.read_text(),"pressed")
                result.unlink()
                vd("click",proc.pid,wid,x,y)
                for _ in range(30):
                    if result.exists(): break
                    time.sleep(.05)
                log=tmp/"press-result-events"
                self.assertTrue(result.exists(), log.read_text() if log.exists() else "No local events delivered")
                self.assertEqual(result.read_text(),"pressed")
                vd("scroll",proc.pid,wid,x,y,36)
                vd("drag",proc.pid,wid,10,90,25,105)
                vd("key",proc.pid,wid,124)
                vd("type",proc.pid,wid,"ab")
                time.sleep(.2)
                self.assertTrue({"1","2","6","22","10"}.issubset({line.split()[0] for line in log.read_text().splitlines()}),log.read_text())
                field=next(c for c in controls if c["role"]=="AXTextField")
                vd("set",proc.pid,wid,field["id"],"verified")
                self.assertTrue(any(c.get("value")=="verified" for c in vd("inspect",proc.pid,wid)["controls"]))
                self.assertEqual(foreground(),before)
            finally:
                proc.terminate()
                proc.wait(timeout=5)
                proc.stdout.close()

    def test_textedit_and_preview(self):
        access=vd("permissions")
        if not access["accessibility"]:
            self.skipTest("Enable Accessibility to launch and move third-party app windows")
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            note=root/"fixture.txt"
            note.write_text("existing document")
            pdf=root/"fixture.pdf"
            with pdf.open("wb") as out:
                subprocess.run(["cupsfilter","-m","application/pdf",str(note)],stdout=out,stderr=subprocess.DEVNULL,check=True)
            before=foreground()
            for name,path in [("TextEdit",note),("Preview",pdf)]:
                with self.subTest(app=name):
                    w=vd("launch",name,path)
                    try:
                        self.assertIn(w,vd("windows")["windows"])
                        self.assertEqual(foreground(),before)
                        controls=vd("inspect",w["pid"],w["window"])["controls"]
                        self.assertGreater(len(controls),1)
                        if name=="TextEdit":
                            field=next(c for c in controls if c["role"]=="AXTextArea")
                            vd("set",w["pid"],w["window"],field["id"],"verified edit")
                            self.assertTrue(any(c.get("value","").strip()=="verified edit" for c in vd("inspect",w["pid"],w["window"])["controls"] if c["role"]=="AXTextArea"))
                        if access["screenRecording"]:
                            output=root/(name+".png")
                            vd("screenshot",w["pid"],w["window"],output)
                            self.assertTrue(output.read_bytes().startswith(b"\x89PNG"))
                        self.assertEqual(foreground(),before)
                    finally:
                        # The launcher verified that this PID is a new instance.
                        import os,signal
                        os.kill(w["pid"],signal.SIGTERM)

if __name__=="__main__":unittest.main()
