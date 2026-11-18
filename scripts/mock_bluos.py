#!/usr/bin/env python3
"""Minimal fake BluOS player for testing bluplay without real hardware.

Implements the subset of the BluOS HTTP API that bluplay uses (/Status with long-poll,
/SyncStatus, /Playlist, /Browse, /Add, /Play, /Pause, /Skip, /Back, /Volume, /Delete,
/Clear, /Reindex, /Stop, /Move, /Sleep, /Presets, /Preset, /Volume?mute,
/Save, /Playlists, saved playlists under /Browse?key=BluOS:, /Load, /Delete?name=) on 127.0.0.1, backed by a small invented music library.

Network shares: GET /Settings on PORT answers 301 to PORT+1 (or the next free port).
That second listener serves /Settings?id=networkShares and /Settings?id=addShare only;
POST /cp/AddShare is answered on PORT (like a NAD C390: 11001 gives 404 for it), and its errors
are <error><message>..</message></error> like the player's. A third listener (argv port, or FAKE_REMOVE_PORT, default PORT+2)
accepts POST /findremoveshares. The share form's action points at 127.0.0.1 on that port.
FAKE_LOG receives request paths only, never bodies or passwords.

usage: mock_bluos.py [PORT] [REMOVE_PORT]   (default port 11000, remove port PORT+2)
env:   FAKE_QN=N    initial queue length (default 4)
       FAKE_LAT=MS  added latency per request (default 0)
       FAKE_LOG=F   log request paths to file F
       FAKE_NAME=S  /SyncStatus name attribute (default Fake Player)
       FAKE_REMOVE_PORT=N   POST /findremoveshares port when argv omits it
       FAKE_IDX_SECS=N      how long /Reindex reports indexing 1 (default 2)

Test-only control endpoint: /_x?resetq=N&song=I&state=play|pause|stop&vol=V
  /_x?name=S sets the /SyncStatus name; /_x?slavefail=N fails the next N /AddSlave or /RemoveSlave
       calls (<error><detail>refused</detail></error>) and does not change the group
  /_x?bigsec=N adds N albums to section P (paged 3 at a time: many nextKey pages)
  /_x?loopsec=1 makes section L answer with a nextKey that repeats forever
  /_x?sleep=N sets the sleep timer to N minutes; /_x?sleepend=pause|none[&delay=S] ends it (sleep field empty) and
       either pauses the player (after S seconds, like most BluOS firmware) or keeps playing (like the NAD)
  /_x?fixed=1 fixed volume (/Status and /Volume report -1, level changes are ignored)
  /_x?volfail=N the next N /Volume?level= sets return <error> and do not change the level
  /_x?addfail=N the next N /Add calls return <error><detail>add refused</detail></error> and do not change the queue
  /_x?totlen=N&canseek=0|1 sets duration and whether /Status reports canSeek
  /_x?seekfail=N the next N /Play?seek= calls return <error><detail>seek refused</detail></error> and do not move
  /_x?reportsec=N the next /Status reports secs N once (a stale poll); /_x?wake=1 pushes a fresh /Status
  /_x?postredirect=1  the next POST /cp/AddShare answers 307 to /cp/AddShareAccept, which accepts the same body
  /_x?addsharefail=N  the next N POST /cp/AddShare answer <error><message>Addshare failed</message></error> (mount failed)
  POST /findremoveshares answers 302 to /sharecfg?noheader=1 (the web form's done page)
  /_x?actionhost=H    host written into the remove-share form action (default 127.0.0.1)
  /_x?shareecho=1     the next POST /cp/AddShare returns <error><message> containing the submitted password
       (the response only; the log still has the path and not the body)
"""
import http.server, socketserver, urllib.parse as up, sys, time, os, random, hashlib, threading, re
from xml.sax.saxutils import escape, quoteattr as qa

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11000
LAT = int(os.environ.get("FAKE_LAT", "0")) / 1000.0
LOG = open(os.environ["FAKE_LOG"], "w") if os.environ.get("FAKE_LOG") else None
NAME = os.environ.get("FAKE_NAME", "Fake Player")
COND = threading.Condition()
random.seed(1)

NAMES = ["Alpha", "alpha beta", "Bravo", "[Bracket]", "Charlie", "Æsir", "Øresund", "Åland", "Zulu", "zebra",
         "(c) Cee", "1984", "Delta", "Echo", "Foxtrot", "Golf", "Gamma", "Hotel", "india", "Juliet", "Kilo",
         "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform"]
ALBUMS = [dict(n=n, a="Artist %d" % i, tracks=["%02d %s t%d" % (k + 1, n, k + 1) for k in range(random.randint(1, 6))])
          for i, n in enumerate(NAMES)]
MUSIC_ROOT = "/mnt/music"

def tfile(i, k): return "%s/%s/%s.flac" % (MUSIC_ROOT, ALBUMS[i]["n"], ALBUMS[i]["tracks"][k])
def make_queue(n): return [dict(t="Track %d" % (i + 1), a="Queue Artist", b="Queue Album", f="%s/queue/%02d.flac" % (MUSIC_ROOT, i + 1)) for i in range(n)]

Q = make_queue(int(os.environ.get("FAKE_QN", "4")))
S = {"state": "play", "vol": 40, "db": -40, "pid": 1, "song": 0, "base": 0.0, "t0": time.time(), "idx_t0": 0, "idx_dur": 0, "shuffle": 0, "repeat": 2, "mute": 0, "sleep": 0, "fixed": 0, "totlen": 200, "canseek": 1, "nonce": 0}
PRESETS = [dict(id=1, name="Radio One"), dict(id=2, name="Jazz & Blues")]   # /Presets, /Preset?id=N
SLEEPS = [15, 30, 45, 60, 90, 0]   # each /Sleep steps the timer
DELLOG = []
SAVED = {}   # saved playlists (/Save?name=): name -> copy of the queue

def secs(): return int(S["base"] + (time.time() - S["t0"] if S["state"] == "play" else 0))
REPORTSEC = [None]  # next /Status only; a stale poll must not change the real playhead
def status_secs():
    if REPORTSEC[0] is None: return secs()
    value = int(REPORTSEC[0]); REPORTSEC[0] = None; return value
MLAG = {"lag": 0.0, "t": 0.0, "old": 0}   # /_x?mutelag=S: /Status reports the previous mute value for S seconds after a change (like the real player)
def smute(): return MLAG["old"] if time.time() < MLAG["t"] + MLAG["lag"] else S["mute"]
def setpos(b=0.0): S["base"] = b; S["t0"] = time.time()
def bump():
    with COND: COND.notify_all()
def idxn():
    if not S["idx_dur"]: return 0
    return 0 if time.time() - S["idx_t0"] >= S["idx_dur"] else 1
def core():
    s = Q[S["song"]] if 0 <= S["song"] < len(Q) else None
    image = "<image>/Artwork?cover=1</image>" if s else ""
    nonce = ("<nonce>%d</nonce>" % S["nonce"]) if S["nonce"] else ""
    return ("<state>%s</state><pid>%d</pid><song>%d</song><title1>%s</title1><title2>%s</title2><title3>%s</title3>"
            "<volume>%d</volume><db>%d</db><totlen>%d</totlen><canSeek>%d</canSeek><indexing>%d</indexing><streamFormat>FLAC 16/44.1</streamFormat><shuffle>%d</shuffle><repeat>%d</repeat><mute>%d</mute>%s<sleep>%s</sleep>%s%s%s") % (
        S["state"], S["pid"], S["song"], escape(s["t"]) if s else "", escape(s["a"]) if s else "", escape(s["b"]) if s else "",
        -1 if S["fixed"] else S["vol"], S["db"], S["totlen"], 1 if S["canseek"] else 0, idxn(), S["shuffle"], S["repeat"], smute(), ("<muteDb>%d</muteDb>" % S["db"]) if smute() else "",
        S["sleep"] or "", ("<fn>%s</fn>" % escape(s["f"])) if s else "", image, nonce)
def etag(c): return hashlib.md5(c.encode()).hexdigest()
def sect(n): return n[:1].upper() if n[:1].isalpha() and n[:1].isascii() else "#"
def aitem(i):
    a = ALBUMS[i]
    return '<item browseKey=%s contextMenuKey=%s playURL=%s text=%s text2=%s type="album"/>' % (
        qa("ALB:%d" % i), qa("CMA:%d" % i), qa("/Add?playnow=1&album=%d" % i), qa(a["n"]), qa(a["a"]))
def skey(cat, q):   # browseKey of a search category, shaped like the real player's
    return "LocalMusic:%s/%s" % (cat, up.quote("/library/v1/%ss?expr=" % cat, safe="") + up.quote(q, safe="") + "&service=LocalMusic")
def search(k, q):
    """/Browse?key=LocalMusic:Search&q=TEXT -> menu of categories with hits; LocalMusic:Song/... etc. -> the hits"""
    if k == "LocalMusic:Search":
        if q == "FAIL": return '<error><detail>search broke</detail></error>'
        q = q.lower(); cats = []
        if any(q in a["a"].lower() for a in ALBUMS): cats.append(("Artist", "Artists"))
        if any(q in a["n"].lower() for a in ALBUMS): cats.append(("Album", "Albums"))
        if any(q in t.lower() for a in ALBUMS for t in a["tracks"]): cats.append(("Song", "Songs"))
        return '<browse serviceName="Library" type="menu">%s</browse>' % "".join(
            '<item browseKey=%s text=%s type="link"/>' % (qa(skey(c, q)), qa(n)) for c, n in cats)
    cat, rest = k[len("LocalMusic:"):].split("/", 1)
    q = up.parse_qs(up.unquote(rest).split("?", 1)[1])["expr"][0].lower()
    if cat == "Album": return '<browse serviceName="Library">%s</browse>' % "".join(aitem(i) for i, a in enumerate(ALBUMS) if q in a["n"].lower())
    if cat == "Artist": return '<browse serviceName="Library">%s</browse>' % "".join(
        '<item browseKey=%s text=%s type="artist"/>' % (qa("ART:%d" % i), qa(a["a"])) for i, a in enumerate(ALBUMS) if q in a["a"].lower())
    return '<browse serviceName="Library" type="tracks">%s</browse>' % "".join(
        '<item text=%s title=%s type="track" playURL=%s contextMenuKey=%s/>' % (qa(t), qa(t), qa("/Add?playnow=1&file=" + up.quote(tfile(i, j))), qa("CMT:%d:%d" % (i, j)))
        for i, a in enumerate(ALBUMS) for j, t in enumerate(a["tracks"]) if q in t.lower())
def browse(k, q=""):
    if k == "LocalMusic:Search" or k.startswith(("LocalMusic:Artist/", "LocalMusic:Album/", "LocalMusic:Song/")): return search(k, q)
    if k == "LocalMusic:":
        return ('<browse serviceName="Library" searchKey="LocalMusic:Search"><item browseKey="LocalMusic:bySection:Artist/x" text="Artists" type="link"/>'
                '<item browseKey="LocalMusic:bySection:Album/x" text="Albums" type="link"/></browse>')
    if k.startswith("LocalMusic:bySection:Album"):
        return '<browse serviceName="Library" type="sections">%s</browse>' % "".join(
            '<item browseKey=%s text=%s text2="%d" type="section"/>' % (qa("SEC:" + c), qa(c), sum(sect(a["n"]) == c for a in ALBUMS))
            for c in sorted(set(sect(a["n"]) for a in ALBUMS)))   # text2 = album count per section, as on the real player
    if k.startswith("LocalMusic:bySection:Artist"):
        return '<browse serviceName="Library">%s</browse>' % "".join(
            '<item browseKey=%s text=%s type="artist"/>' % (qa("ART:%d" % i), qa(a["a"])) for i, a in enumerate(ALBUMS))
    if k.startswith("ART:"):
        return '<browse serviceName="Library">%s</browse>' % aitem(int(k[4:]))
    if k.startswith("SEC:") or k.startswith("NEXT:"):   # sections paged 3 at a time (exercises nextKey)
        if k.startswith("SEC:"): c, off = k[4:], 0
        else: _, c, off = k.split(":", 2); off = int(off)
        idx = [i for i, a in enumerate(ALBUMS) if sect(a["n"]) == c][off:]
        if c == "L" and LOOP[0]: return '<browse serviceName="Library" nextKey="NEXT:L:0">%s</browse>' % "".join(aitem(i) for i in idx[:3])
        nk = (' nextKey=%s' % qa("NEXT:%s:%d" % (c, off + 3))) if len(idx) > 3 else ""
        return '<browse serviceName="Library"%s>%s</browse>' % (nk, "".join(aitem(i) for i in idx[:3]))
    if k.startswith("ALB:"):
        i = int(k[4:]); a = ALBUMS[i]
        return '<browse serviceName=%s>%s</browse>' % (qa(a["n"]), "".join(
            '<item text=%s type="track" playURL=%s contextMenuKey=%s/>' % (qa(t), qa("/Add?playnow=1&file=" + up.quote(tfile(i, j))), qa("CMT:%d:%d" % (i, j)))
            for j, t in enumerate(a["tracks"])))
    if k.startswith("CMA:"):
        return '<browse type="contextMenu"><item actionURL="/Add?playnow=-1&amp;where=last&amp;album=%d" type="addAll-last" text="Add all"/></browse>' % int(k[4:])
    if k.startswith("CMT:"):
        _, i, j = k.split(":")
        return '<browse type="contextMenu"><item actionURL="/Add?playnow=-1&amp;where=last&amp;file=%s" type="add-last" text="Add last"/></browse>' % escape(up.quote(tfile(int(i), int(j))))
    if k == "BluOS:":   # saved playlists, shaped like the real player's Browse (playURL + contextMenuKey per playlist)
        return '<browse serviceName="BluOS" type="playlists">%s</browse>' % "".join(
            '<item browseKey=%s contextMenuKey=%s playURL=%s text=%s type="playlist"/>' % (qa("BluOS:MG/BluOS-Playlist?playlist=" + up.quote(n)),
                qa("BluOS:CM/BluOS-Playlist?playlist=" + up.quote(n)), qa("/Load?service=BluOS&name=" + up.quote(n)), qa(n))
            for n in sorted(SAVED))
    if k.startswith("BluOS:CM/BluOS-Playlist?playlist="):   # same entries as the real player's menu
        n = up.quote(up.unquote(k.split("=", 1)[1]))
        return ('<browse serviceName="BluOS" type="contextMenu">'
                '<item actionURL=%s text="Play now" type="add-now"/><item actionURL=%s text="Add last" type="add-last"/>'
                '<item actionURL=%s text="Delete" type="delete"/></browse>' % (qa("/Add?clear=0&playlist=%s&playnow=1&service=BluOS&shuffle=0" % n),
                qa("/Add?playlist=%s&playnow=-1&service=BluOS&where=last" % n), qa("/Delete?name=%s&service=BluOS" % n)))
    return '<browse serviceName="?"></browse>'

LOOP = [0]
FAILNEXT = [0]
VOLFAIL = [0]
ADDFAIL = [0]   # next N /Add only; status and browse do not consume it
SEEKFAIL = [0]   # next N /Play?seek= only; other /Play calls do not consume it
SLAVEFAIL = [0]   # next N /AddSlave or /RemoveSlave only; other routes do not consume it
GRP = set()   # (ip, port) of grouped players (AddSlave/RemoveSlave)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def do_GET(self):
        global NAME
        if LOG: LOG.write(self.path + "\n"); LOG.flush()
        if LAT: time.sleep(LAT)
        u = up.urlparse(self.path); p = u.path; qs = up.parse_qs(u.query, keep_blank_values=True)
        g = lambda k, d=None: qs.get(k, [d])[0]
        if p == "/Settings":
            loc = "http://127.0.0.1:%d%s" % (SETTINGS_PORT, self.path)
            self.send_response(301)
            self.send_header("Location", loc)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        x = ""
        if p != "/_x" and FAILNEXT[0] > 0:
            FAILNEXT[0] -= 1
            x = "<error><detail>refused</detail></error>"
            b = ('<?xml version="1.0" encoding="UTF-8"?>' + x).encode()
            self.send_response(200); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b)
            return
        if p == "/SyncStatus": x = '<SyncStatus name=%s modelName="FAKE">%s</SyncStatus>' % (qa(NAME), "".join('<slave id="%s" port="%s"/>' % s for s in sorted(GRP)))
        elif p in ("/AddSlave", "/RemoveSlave"):
            if SLAVEFAIL[0] > 0: SLAVEFAIL[0] -= 1; x = "<error><detail>refused</detail></error>"
            elif not g("slave"): x = "<error><detail>missing slave</detail></error>"
            else: (GRP.add if p == "/AddSlave" else GRP.discard)((g("slave"), g("port", "11000"))); x = '<addSlave/>'
        elif p == "/Status":
            tmo = float(g("timeout", "0")); et = g("etag"); end = time.time() + tmo
            while et and tmo:
                with COND:
                    if etag(core()) != et or time.time() >= end: break
                    COND.wait(min(0.2, max(0.01, end - time.time())))
            c = core(); x = '<status etag="%s">%s<secs>%d</secs></status>' % (etag(c), c, status_secs())
        elif p == "/_x":
            if "resetq" in qs: Q[:] = make_queue(int(g("resetq"))); S["pid"] += 1; DELLOG.clear()
            if "song" in qs: S["song"] = int(g("song")); setpos(0)
            if "state" in qs: setpos(secs()); S["state"] = g("state")
            if "vol" in qs: S["vol"] = int(g("vol")); S["db"] = S["vol"] - 80
            if "mutelag" in qs: MLAG["lag"] = float(g("mutelag"))
            if "truemute" in qs: x = "<mute>%d</mute>" % S["mute"]
            if "bigsec" in qs:
                for j in range(int(g("bigsec"))): ALBUMS.append(dict(n="Pzz %04d" % (j + 1), a="Big Artist", tracks=["01 Big %d" % (j + 1)]))
            if "loopsec" in qs: LOOP[0] = int(g("loopsec"))
            if "fixed" in qs: S["fixed"] = int(g("fixed"))
            if "volfail" in qs: VOLFAIL[0] = int(g("volfail"))
            if "addfail" in qs: ADDFAIL[0] = int(g("addfail"))
            if "totlen" in qs: S["totlen"] = max(0, int(g("totlen")))
            if "canseek" in qs: S["canseek"] = 1 if str(g("canseek")) in ("1", "true", "True") else 0
            if "seekfail" in qs: SEEKFAIL[0] = int(g("seekfail"))
            if "reportsec" in qs:
                REPORTSEC[0] = int(g("reportsec")); S["nonce"] += 1
            if "wake" in qs: S["nonce"] += 1
            if "failnext" in qs: FAILNEXT[0] = int(g("failnext"))
            if "slavefail" in qs: SLAVEFAIL[0] = int(g("slavefail"))
            if "name" in qs: NAME = g("name") or ""
            if "postredirect" in qs: POST_REDIRECT[0] = max(0, int(g("postredirect") or 0))
            if "actionhost" in qs: ACTION_HOST[0] = g("actionhost") or "127.0.0.1"
            if "shareecho" in qs: SHARE_ECHO[0] = max(0, int(g("shareecho") or 0))
            if "addsharefail" in qs: ADD_FAIL[0] = max(0, int(g("addsharefail") or 0))
            if "sleep" in qs: S["sleep"] = int(g("sleep"))
            if "sleepend" in qs:
                S["sleep"] = 0
                if g("sleepend") == "pause":
                    def fw_pause():
                        if S["state"] == "play": setpos(secs()); S["state"] = "pause"
                        bump()
                    threading.Timer(float(g("delay", "0")), fw_pause).start()
            if "dellog" in qs: x = "<dellog>%s</dellog>" % "".join('<id id="%d"/>' % i for i in DELLOG)
            bump(); x = x or "<ok/>"
        elif p == "/Reindex":
            if idxn() == 0: S["idx_t0"] = time.time(); S["idx_dur"] = float(os.environ.get("FAKE_IDX_SECS", "2"))
            x = "<indexing>%d</indexing>" % idxn()
        elif p == "/Playlist" and "length" in qs:   # real player: /Playlist?length=1 -> length and id only
            x = "<playlist><length>%d</length><id>%d</id></playlist>" % (len(Q), S["pid"])
        elif p == "/Playlist":
            x = '<playlist length="%d" id="%d">%s</playlist>' % (len(Q), S["pid"], "".join(
                '<song id="%d"><art>%s</art><alb>%s</alb><title>%s</title><fn>%s</fn></song>' % (i, escape(s["a"]), escape(s["b"]), escape(s["t"]), escape(s["f"]))
                for i, s in enumerate(Q)))
        elif p == "/Delete" and "name" in qs:   # delete a saved playlist (real player: /Delete?name=N&service=BluOS -> <deleted>N</deleted>)
            n = g("name", ""); SAVED.pop(n, None); x = "<deleted>%s</deleted>" % escape(n)
        elif p == "/Delete":
            i = int(g("id", "-1")); DELLOG.append(i)
            if 0 <= i < len(Q):
                del Q[i]; S["pid"] += 1
                if i < S["song"]: S["song"] -= 1
            bump(); x = "<deleted>%d</deleted>" % i
        elif p == "/Save":
            n = g("name", ""); SAVED[n] = [dict(q) for q in Q]; S["pid"] += 1; bump(); x = "<saved><entries>%d</entries></saved>" % len(Q)   # real player: queue id +1
        elif p == "/Playlists":
            x = '<playlists service="BluOS">%s</playlists>' % "".join("<name>%s</name>" % escape(n) for n in sorted(SAVED))
        elif p == "/Load":   # load a saved playlist: replaces the queue and plays it
            Q[:] = [dict(q) for q in SAVED.get(g("name"), [])]; S["song"] = 0 if Q else -1; S["state"] = "play" if Q else "stop"; setpos(0)
            S["pid"] += 1; bump(); x = "<loaded service=\"BluOS\"><entries>%d</entries></loaded>" % len(Q)
        elif p == "/Add":
            if ADDFAIL[0] > 0:
                ADDFAIL[0] -= 1
                x = "<error><detail>add refused</detail></error>"
            else:
                if "file" in qs:
                    f = g("file"); Q.append(dict(t=os.path.splitext(os.path.basename(f))[0], a="Added Artist", b="Added Album", f=f))
                elif "album" in qs:
                    i = int(g("album"))
                    for j, t in enumerate(ALBUMS[i]["tracks"]): Q.append(dict(t=t, a=ALBUMS[i]["a"], b=ALBUMS[i]["n"], f=tfile(i, j)))
                if g("playnow") == "1": S["song"] = len(Q) - 1; S["state"] = "play"; setpos(0)
                S["pid"] += 1; bump(); x = "<addsong/>"
        elif p == "/Play":
            if "seek" in qs and SEEKFAIL[0] > 0:
                SEEKFAIL[0] -= 1
                x = "<error><detail>seek refused</detail></error>"
            else:
                if "seek" in qs: setpos(float(g("seek")))
                elif "id" in qs: S["song"] = int(g("id")); setpos(0)
                else: setpos(secs())
                S["state"] = "play"; bump(); x = "<state>play</state>"
        elif p == "/Clear": Q.clear(); S["pid"] += 1; S["song"] = -1; bump(); x = "<playlist/>"
        elif p == "/Browse": x = browse(g("key", "LocalMusic:"), g("q", ""))
        elif p == "/Volume" and "mute" not in qs:
            if VOLFAIL[0] > 0 and "level" in qs:
                VOLFAIL[0] -= 1
                x = "<error><detail>volume refused</detail></error>"
            else:
                if S["fixed"]: pass
                elif "level" in qs: S["vol"] = max(0, min(100, int(g("level")))); S["db"] = S["vol"] - 80
                elif "db" in qs: S["db"] = max(-80, min(0, S["db"] + int(g("db")))); S["vol"] = S["db"] + 80
                bump(); x = '<volume db="%d">%d</volume>' % (S["db"], -1 if S["fixed"] else S["vol"])
        elif p == "/Volume" and "mute" in qs:   # real player: level kept, reply db="-100" mute="1" muteDb=..
            MLAG["old"] = smute(); MLAG["t"] = time.time(); S["mute"] = int(g("mute")); bump()
            x = ('<volume db="-100" mute="1" muteVolume="%d" muteDb="%d">0</volume>' % (S["vol"], S["db"])) if S["mute"] else ('<volume db="%d" mute="0">%d</volume>' % (S["db"], S["vol"]))
        elif p == "/Stop": setpos(0); S["state"] = "stop"; bump(); x = "<state>stop</state>"
        elif p == "/Sleep":
            S["sleep"] = SLEEPS[(SLEEPS.index(S["sleep"]) + 1) % len(SLEEPS)]; bump(); x = "<sleep>%s</sleep>" % (S["sleep"] or "")
        elif p == "/Move":   # 0-based song ids, as on the real player (verified: Move?old=0&new=1 swapped rows 0 and 1, playlist id +1)
            o, n = int(g("old")), int(g("new")); Q.insert(n, Q.pop(o)); S["pid"] += 1
            if S["song"] == o: S["song"] = n
            elif o < S["song"] <= n: S["song"] -= 1
            elif n <= S["song"] < o: S["song"] += 1
            bump(); x = "<moved>moved</moved>"
        elif p == "/Presets": x = '<presets prid="0">%s</presets>' % "".join('<preset id="%d" name=%s url="x"/>' % (q["id"], qa(q["name"])) for q in PRESETS)
        elif p == "/Preset":
            q = [q for q in PRESETS if q["id"] == int(g("id", "0"))]
            if q: Q[:] = [dict(t=q[0]["name"], a="Preset", b="Radio", f="")]; S["pid"] += 1; S["song"] = 0; S["state"] = "play"; setpos(0)
            bump(); x = "<state>play</state>"
        elif p in ("/Shuffle", "/Repeat"):
            k = p[1:].lower(); S[k] = int(g("state", "0")); bump(); x = '<playlist shuffle="%d" repeat="%d"/>' % (S["shuffle"], S["repeat"])
        elif p == "/Pause":
            setpos(secs())
            if g("toggle") == "1": S["state"] = "pause" if S["state"] == "play" else "play"
            elif S["state"] == "play": S["state"] = "pause"   # plain /Pause only pauses
            bump(); x = "<state>%s</state>" % S["state"]
        elif p == "/Skip":
            if Q: S["song"] = (S["song"] + 1) % len(Q)
            setpos(0); bump(); x = "<id>%d</id>" % S["song"]
        elif p == "/Back": setpos(0); bump(); x = "<id>%d</id>" % S["song"]
        elif p == "/Artwork":
            gif = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,"
                   b"\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")
            self.send_response(200)
            self.send_header("Content-Type", "image/gif")
            self.send_header("Content-Length", str(len(gif)))
            self.end_headers()
            self.wfile.write(gif)
            return
        else:
            self.send_response(404); self.end_headers(); return
        b = ('<?xml version="1.0" encoding="UTF-8"?>' + x).encode()
        self.send_response(200); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)

class T(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True

# Share list lives in memory. Passwords are read and discarded; they are never stored or logged.
SHARE_RE = re.compile(r"^\\\\(.*?)\\(.*)$")
SETTINGS_PORT = PORT + 1
REMOVE_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("FAKE_REMOVE_PORT", str(PORT + 2)))
ACTION_HOST = ["127.0.0.1"]
POST_REDIRECT = [0]
SHARE_ECHO = [0]
ADD_FAIL = [0]
SHARE_LOCK = threading.Lock()
SHARE_STYLE = (
    "<style>\n"
    ".heading{font-weight:600;margin:0 0 8px 0;}\n"
    "#configshareform{font-family:inherit;color:inherit;}\n"
    "#configshareform fieldset{border:1px solid rgba(255,255,255,0.15);border-radius:8px;padding:6px 10px;margin:0 0 12px 0;}\n"
    "#configshareform .row{display:flex;align-items:flex-start;gap:10px;padding:8px 10px;border-radius:6px;}\n"
    "#configshareform .row:hover{background:rgba(255,255,255,0.06);}\n"
    "#configshareform input[type=checkbox]{width:18px;height:18px;accent-color:#4a9eff;margin:0;flex:0 0 auto;cursor:pointer;}\n"
    "#configshareform label{cursor:pointer;flex:1;overflow-wrap:break-word;}\n"
    "#configshareform input[type=submit]{margin-top:8px;padding:10px 18px;border-radius:6px;border:1px solid rgba(255,255,255,0.15);background:#2a2f36;color:inherit;font:inherit;cursor:pointer;}\n"
    "#configshareform input[type=submit]:hover{background:#353b44;}\n"
    "</style>"
)
ADD_SHARE_XML = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<settings pageId="addShare" schemaVersion="28">
	<menuGroup id="addShare" displayName="Add shares" url="/cp/AddShare" class="form" buttonText="Add share" notification="Share added" closeOnInvoke="true">
		<setting id="sharename" name="sharename" displayName="Enter share name (as \\\\ComputerName\\share)" class="text" pattern="^\\\\\\\\(.*?)\\\\(.*)$" patternError="Share URL must be in the form \\\\computer\\share" requiredError="This field is required." required="true"></setting>
		<setting id="username" name="username" displayName="User name (if required)" class="text"></setting>
		<setting id="password" name="password" displayName="Password (if required)" class="text" style="password"></setting>
	</menuGroup>
</settings>
"""

def share_record(path):
    match = SHARE_RE.fullmatch(path)
    host, rest = match.group(1), match.group(2)
    return {"path": path, "label": "%s on %s (%s)" % (rest, host, path)}

SHARES = [share_record(r"\\10.0.0.5\Media\Music"), share_record(r"\\nas.example\Rock & Roll")]

def note(handler):
    if LOG:
        LOG.write(handler.path + "\n")
        LOG.flush()

def read_body(handler):
    try:
        n = int(handler.headers.get("Content-Length", "0") or 0)
    except ValueError:
        n = 0
    if n <= 0:
        return b""
    return handler.rfile.read(n)

def xml_send(handler, xml, code=200):
    if not xml.lstrip().startswith("<?xml"):
        xml = '<?xml version="1.0" encoding="UTF-8"?>' + xml
    data = xml.encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "text/xml; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)

def html_text(value):
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

def action_url():
    return "http://%s:%d/findremoveshares" % (ACTION_HOST[0], REMOVE_PORT)

def network_shares_xml():
    with SHARE_LOCK:
        rows = []
        for index, share in enumerate(SHARES, start=1):
            box = "checkbox%d" % index
            rows.append(
                '<div class="row"><input name="%s" id="%s" type="checkbox" /><label for="%s">%s</label></div>'
                % (html_text(share["path"]), box, box, html_text(share["label"]))
            )
        html = (
            SHARE_STYLE
            + '<form id="configshareform" method="POST" action="%s"><fieldset>%s</fieldset>'
            % (html_text(action_url()), "".join(rows))
            + '<input type="submit" name="remove" value="Remove selected shares" /></form>'
        )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<settings pageId="networkShares" schemaVersion="28">\n'
        '\t<menuGroup id="networkShares" displayName="Network Shares" icon="/images/settings/ic_networkshares.png" refresh="true">\n'
        '\t\t<setting id="shares" name="shares" displayName="Current music shares" class="html" value=%s readonly="true"></setting>\n'
        '\t\t<menuGroup id="addShare" displayName="Add shares" url="/cp/AddShare" class="form" buttonText="Add share" notification="Share added" closeOnInvoke="true"></menuGroup>\n'
        '\t</menuGroup>\n'
        '</settings>\n'
    ) % qa(html)

def form_fields(raw):
    return up.parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True)

def add_share(handler, raw):
    fields = form_fields(raw)
    name = fields.get("sharename", [""])[0]
    if SHARE_ECHO[0] > 0:
        SHARE_ECHO[0] -= 1
        # Echo stays in this response so a client test can prove it strips the password.
        # The log line above is only the path.
        detail = escape(fields.get("password", [""])[0])
        xml_send(handler, "<error><message>refused %s</message></error>" % detail)
        return
    if SHARE_RE.fullmatch(name) is None:
        xml_send(handler, "<error><message>Share URL must be in the form \\\\computer\\share</message></error>")
        return
    if ADD_FAIL[0] > 0:
        ADD_FAIL[0] -= 1
        xml_send(handler, "<error><message>Addshare failed</message></error>")
        return
    with SHARE_LOCK:
        if any(share["path"] == name for share in SHARES):
            xml_send(handler, "<error><message>Share already exists</message></error>")
            return
        SHARES.append(share_record(name))
    xml_send(handler, "<ok/>")

class SettingsH(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def do_GET(self):
        note(self)
        if LAT: time.sleep(LAT)
        u = up.urlparse(self.path)
        if u.path == "/cp/AddShareAccept":
            self.send_response(405)
            self.send_header("Allow", "POST")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if u.path != "/Settings":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        ident = up.parse_qs(u.query).get("id", [""])[0]
        xml_send(self, ADD_SHARE_XML if ident == "addShare" else network_shares_xml())
    def do_POST(self):   # the real player's settings port has no form handlers
        note(self)
        read_body(self)
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

class RemoveH(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def do_GET(self):
        note(self)
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()
    def do_POST(self):
        note(self)
        raw = read_body(self)
        if LAT: time.sleep(LAT)
        if up.urlparse(self.path).path != "/findremoveshares":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        fields = form_fields(raw)
        with SHARE_LOCK:
            for key, values in fields.items():
                if values and values[0] == "on":
                    SHARES[:] = [share for share in SHARES if share["path"] != key]
        self.send_response(302)   # like the player's web form: redirect to the share page (not fetched by the client)
        self.send_header("Location", "/sharecfg?noheader=1")
        self.send_header("Content-Length", "0")
        self.end_headers()

def listen(port, handler):
    last = None
    for offset in range(30):
        try:
            return T(("127.0.0.1", port + offset), handler), port + offset
        except OSError as err:
            last = err
    raise SystemExit("could not bind port %s: %s" % (port, last))

def main_post(self):   # POST to the API port: the add-share form (as on a NAD C390, BluOS 4.18)
    note(self)
    raw = read_body(self)
    if LAT: time.sleep(LAT)
    path = up.urlparse(self.path).path
    if path == "/cp/AddShare" and POST_REDIRECT[0] > 0:
        POST_REDIRECT[0] -= 1
        self.send_response(307)
        self.send_header("Location", "http://127.0.0.1:%d/cp/AddShareAccept" % PORT)
        self.send_header("Content-Length", "0")
        self.end_headers()
        return
    if path in ("/cp/AddShare", "/cp/AddShareAccept"):
        add_share(self, raw)
        return
    self.send_response(404)
    self.send_header("Content-Length", "0")
    self.end_headers()
H.do_POST = main_post

if __name__ == "__main__":
    # Bind the caller's port first so a parallel test cannot lose it to this process's extra listeners.
    main_server = T(("127.0.0.1", PORT), H)
    settings_server, SETTINGS_PORT = listen(PORT + 1, SettingsH)
    remove_server, REMOVE_PORT = listen(REMOVE_PORT, RemoveH)
    threading.Thread(target=settings_server.serve_forever, daemon=True).start()
    threading.Thread(target=remove_server.serve_forever, daemon=True).start()
    main_server.serve_forever()
