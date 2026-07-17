#!/usr/bin/env python3
"""
leadv2-quota-read.py — Live quota reads for the three provider buckets.
Credential-safe: tokens are held in process memory ONLY. They are never printed,
logged, or written to any cache file. Cache files store ONLY the normalized,
non-secret result (percentages, reset times, plan type).

Usage:
    leadv2-quota-read.py glm|codex|anthropic [--no-cache] [--cache-dir DIR]

Each provider is INDEPENDENT — one failing never blanks another. Any read error
fails OPEN: the bucket reports {"status":"unknown", ...} and exit code 0, so a
caller (the GLM gate) never crashes on a quota blip. unknown is never 0%.

Buckets:
  glm        z.ai token quota. Disambiguates 5h vs weekly by nextResetTime
             distance (position-independent). Bearer $ZAI_AUTH_TOKEN.
  codex      ChatGPT/Codex usage. Refreshes the OAuth token first (rotation
             rotates the refresh_token -> written back to auth.json), then reads
             chatgpt.com/backend-api/wham/usage. used_percent verbatim.
  anthropic  Anthropic Max/Team usage via /api/oauth/usage with a FRESH
             in-process access token (NO DPoP needed for the resource server).
             Scans every Claude Code-credentials* keychain entry; reports each
             fresh account. 429 -> unknown. No fresh token -> unknown (DPoP
             refresh is the unwired fallback; in leadv2 a live session keeps a
             fresh token present).

Env overrides:
  LEADV2_QUOTA_TTL_GLM (60)  LEADV2_QUOTA_TTL_CODEX (120)  LEADV2_QUOTA_TTL_ANTHROPIC (300)
  LEADV2_QUOTA_CACHE_DIR (~/.claude/state/leadv2/quota-cache)
  LEADV2_BURN_DB (~/.claude/burn/history.db)  -- Anthropic rate_limit_info kv secondary signal
  CODEX_HOME (~/.codex)  ZAI_AUTH_TOKEN  LEADV2_ZAI_ENV (~/.claude/secrets/zai.env)
"""
import datetime, json, os, subprocess, sys, tempfile, time, urllib.request, urllib.error

UTC = datetime.timezone.utc


def iso_now():
    return datetime.datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_from_ms(ms):
    try:
        return datetime.datetime.fromtimestamp((ms or 0) / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return None


def iso_from_epoch(s):
    try:
        return datetime.datetime.fromtimestamp(int(s or 0), UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return None


CACHE_DIR = os.environ.get("LEADV2_QUOTA_CACHE_DIR",
                           os.path.expanduser("~/.claude/state/leadv2/quota-cache"))
TTL = {"glm": int(os.environ.get("LEADV2_QUOTA_TTL_GLM", "60")),
       "codex": int(os.environ.get("LEADV2_QUOTA_TTL_CODEX", "120")),
       "anthropic": int(os.environ.get("LEADV2_QUOTA_TTL_ANTHROPIC", "300"))}


def cache_get(provider):
    p = os.path.join(CACHE_DIR, provider + ".json")
    try:
        if time.time() - os.path.getmtime(p) < TTL[provider]:
            with open(p) as f:
                return json.load(f)
    except Exception:
        pass
    return None


def cache_put(provider, obj):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=provider + ".", dir=CACHE_DIR)
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, os.path.join(CACHE_DIR, provider + ".json"))
    except Exception:
        pass


def http_json(url, headers=None, method="GET", data=None, timeout=15):
    req = urllib.request.Request(url, headers=headers or {}, method=method, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.getcode(), r.read().decode()


def unknown(provider, error, **extra):
    d = {"provider": provider, "status": "unknown", "error": error, "fetched_at": iso_now()}
    d.update(extra)
    return d


# ── GLM ─────────────────────────────────────────────────────────────────────
def read_glm():
    tok = os.environ.get("ZAI_AUTH_TOKEN")
    if not tok:
        envf = os.environ.get("LEADV2_ZAI_ENV", os.path.expanduser("~/.claude/secrets/zai.env"))
        try:
            with open(envf) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("ZAI_AUTH_TOKEN") and "=" in line:
                        tok = line.split("=", 1)[1].strip().strip('"').strip("'")
                        break
        except Exception:
            pass
    if not tok:
        return unknown("glm", "ZAI_AUTH_TOKEN not set / not readable")
    try:
        glm_url = os.environ.get("LEADV2_ZAI_QUOTA_URL",
                                 "https://api.z.ai/api/monitor/usage/quota/limit")
        _, body = http_json(glm_url, headers={"Authorization": "Bearer " + tok})
        doc = json.loads(body)
        limits = (doc.get("data") or {}).get("limits") or []
    except urllib.error.HTTPError as e:
        return unknown("glm", "http %d" % e.code)
    except Exception as e:
        return unknown("glm", "fetch/parse: %s" % e)

    now_ms = int(time.time() * 1000)
    token_limits = [l for l in limits if l.get("type") == "TOKENS_LIMIT"]
    five_hour, weekly, search = None, None, None
    # Disambiguate by nextResetTime DISTANCE (position-independent, reorder-safe).
    for l in token_limits:
        hrs = ((l.get("nextResetTime") or 0) - now_ms) / 3_600_000.0
        if hrs < 36 and five_hour is None:
            five_hour = l
        elif hrs >= 36 and weekly is None:
            weekly = l
        else:
            if five_hour is None:
                five_hour = l
            elif weekly is None:
                weekly = l
    for l in limits:
        if l.get("type") == "TIME_LIMIT":
            search = l

    def win(l):
        if not l:
            return None
        return {"pct": l.get("percentage"),
                "reset_epoch_ms": l.get("nextResetTime"),
                "reset_iso": iso_from_ms(l.get("nextResetTime")),
                "unit": l.get("unit"), "number": l.get("number")}

    out = {"provider": "glm", "status": "ok",
           "level": (doc.get("data") or {}).get("level"), "fetched_at": iso_now(),
           "five_hour": win(five_hour), "weekly": win(weekly)}
    if search:
        out["search_credits"] = {"percentage": search.get("percentage"),
                                 "usage": search.get("usage"),
                                 "remaining": search.get("remaining"),
                                 "reset_iso": iso_from_ms(search.get("nextResetTime"))}
    if not (five_hour and weekly):
        # 0 or 1 usable windows means we cannot assess quota (bad token returns
        # 200 with empty limits). Fail honestly to unknown — never report ok/null.
        return unknown("glm",
                       "could not resolve both quota windows (got %d TOKENS_LIMIT); "
                       "token rejected or unexpected payload" % len(token_limits),
                       level=(doc.get("data") or {}).get("level"))
    return out


# ── Codex ───────────────────────────────────────────────────────────────────
def read_codex():
    aj = os.path.join(os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex")), "auth.json")
    try:
        d = json.load(open(aj))
        rtok = d["tokens"]["refresh_token"]
    except Exception as e:
        return unknown("codex", "auth.json unreadable: %s" % e, needs_login=True)

    body = json.dumps({"grant_type": "refresh_token",
                       "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
                       "refresh_token": rtok,
                       "scope": "openid profile email offline_access"}).encode()
    try:
        _, rbody = http_json("https://auth.openai.com/oauth/token", method="POST", data=body,
                             headers={"Content-Type": "application/json",
                                      "User-Agent": "codex_cli_rs/0.0.0 (leadv2-quota)"})
        tok = json.loads(rbody)
    except urllib.error.HTTPError as e:
        return unknown("codex", "refresh http %d" % e.code, needs_login=True)
    except Exception as e:
        return unknown("codex", "refresh: %s" % e, needs_login=True)

    access = tok.get("access_token")
    new_refresh = tok.get("refresh_token") or rtok
    if not access:
        return unknown("codex", "no access_token in refresh response", needs_login=True)

    # Rotation invalidated the old refresh_token — write the new one back so the
    # CLI's refresh chain survives. chmod 600. Token never printed/logged.
    wrote_back = False
    try:
        d["tokens"]["access_token"] = access
        d["tokens"]["refresh_token"] = new_refresh
        if tok.get("id_token"):
            d["tokens"]["id_token"] = tok["id_token"]
        d["last_refresh"] = iso_now()
        td = os.path.dirname(aj) or "."
        fd, tmp = tempfile.mkstemp(prefix=".auth.json.", dir=td)
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, aj)
        wrote_back = True
    except Exception:
        pass  # token still held in memory for the single usage call below

    try:
        _, ubody = http_json("https://chatgpt.com/backend-api/wham/usage",
                             headers={"Authorization": "Bearer " + access,
                                      "User-Agent": "codex_cli_rs/0.0.0 (leadv2-quota)"})
        u = json.loads(ubody)
    except urllib.error.HTTPError as e:
        return unknown("codex", "usage http %d" % e.code, refreshed=True, wrote_back=wrote_back)
    except Exception as e:
        return unknown("codex", "usage: %s" % e, refreshed=True, wrote_back=wrote_back)

    rl = u.get("rate_limit") or {}
    pw = rl.get("primary_window") or {}
    sw = rl.get("secondary_window")
    windows = []
    if pw:
        windows.append({"kind": "primary", "used_percent": pw.get("used_percent"),
                        "limit_window_seconds": pw.get("limit_window_seconds"),
                        "reset_epoch": pw.get("reset_at"),
                        "reset_iso": iso_from_epoch(pw.get("reset_at")),
                        "limit_reached": rl.get("limit_reached")})
    if sw:
        windows.append({"kind": "secondary", "used_percent": sw.get("used_percent"),
                        "limit_window_seconds": sw.get("limit_window_seconds"),
                        "reset_epoch": sw.get("reset_at"),
                        "reset_iso": iso_from_epoch(sw.get("reset_at"))})
    cr = u.get("credits") or {}
    return {"provider": "codex", "status": "ok", "plan_type": u.get("plan_type"),
            "fetched_at": iso_now(), "refreshed": True, "wrote_back": wrote_back,
            "limit_reached": rl.get("limit_reached"), "allowed": rl.get("allowed"),
            "windows": windows,
            "credits": {"has_credits": cr.get("has_credits"), "balance": cr.get("balance")}}


# ── Anthropic ───────────────────────────────────────────────────────────────
def _keychain_services(prefix="Claude Code-credentials"):
    services = set()
    try:
        out = subprocess.check_output(["security", "dump-keychain"], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            s = line.strip()
            if s.startswith('"svce"<blob>="'):
                sv = s.split('="', 1)[1].rstrip('"')
                if sv.startswith(prefix):
                    services.add(sv)
    except Exception:
        pass
    return services or {prefix}


def _read_keychain(service):
    try:
        raw = subprocess.check_output(["security", "find-generic-password", "-s", service, "-w"],
                                      stderr=subprocess.STDOUT).decode()
        return json.loads(raw)
    except Exception:
        return None


def _anthropic_kv():
    """Last captured rate_limit_info from history.db kv (secondary signal)."""
    db = os.environ.get("LEADV2_BURN_DB", os.path.expanduser("~/.claude/burn/history.db"))
    if not os.path.exists(db):
        return None
    try:
        out = subprocess.check_output(
            ["sqlite3", db,
             "SELECT value FROM kv WHERE key='rate_limit_anthropic' ORDER BY rowid DESC LIMIT 1;"],
            stderr=subprocess.DEVNULL).decode().strip()
        return json.loads(out) if out else None
    except Exception:
        return None


def read_anthropic():
    now_ms = int(time.time() * 1000)
    accounts = []
    for sv in sorted(_keychain_services()):
        blob = _read_keychain(sv)
        if not isinstance(blob, dict):
            continue
        o = blob.get("claudeAiOauth") or {}
        at, ea = o.get("accessToken"), o.get("expiresAt")
        if not (at and ea and ea > now_ms):
            continue  # stale — DPoP refresh not wired here
        code, body, err = None, "", None
        try:
            code, body = http_json("https://api.anthropic.com/api/oauth/usage",
                                   headers={"Authorization": "Bearer " + at,
                                            "User-Agent": "claude-code/1.0 (leadv2-quota)"})
        except urllib.error.HTTPError as e:
            code = e.code
            if code != 429:
                try:
                    body = e.read().decode()
                except Exception:
                    body = ""
        except Exception as e:
            err = str(e)

        suffix = "default" if sv == "Claude Code-credentials" else sv.rsplit("-", 1)[-1]
        acct = {"entry_suffix": suffix, "service": sv,
                "subscription_type": o.get("subscriptionType"),
                "tier": o.get("rateLimitTier"), "http": code}
        if code == 200:
            try:
                u = json.loads(body)
                fh = u.get("five_hour") or {}
                sd = u.get("seven_day") or {}
                acct.update({"status": "ok",
                             "five_hour_pct": fh.get("utilization"),
                             "five_hour_reset_iso": fh.get("resets_at"),
                             "seven_day_pct": sd.get("utilization"),
                             "seven_day_reset_iso": sd.get("resets_at"),
                             "limits": u.get("limits")})
            except Exception as ex:
                acct.update({"status": "unknown", "error": "parse: %s" % ex})
        elif code == 429:
            acct.update({"status": "unknown",
                         "error": "429 rate_limited (reported as unknown, NEVER 0)"})
        else:
            acct.update({"status": "unknown", "error": err or ("http %s" % code)})
        accounts.append(acct)

    if not accounts:
        out = unknown("anthropic",
                      "no fresh in-process access token in any Claude Code-credentials* keychain entry; "
                      "DPoP refresh (platform.claude.com/v1/oauth/token) is not wired — start or recently "
                      "use a Claude session to refresh in-process, then re-run", accounts=[], needs_session=True)
        kv = _anthropic_kv()
        if kv:
            out["rate_limit_info_captured"] = kv
            out["note"] = ("reporting the last rate_limit_info captured into history.db kv "
                           "(rate_limit_anthropic) as a fallback signal")
        return out
    return {"provider": "anthropic", "status": "ok", "accounts": accounts, "fetched_at": iso_now()}


READERS = {"glm": read_glm, "codex": read_codex, "anthropic": read_anthropic}


def main():
    args = sys.argv[1:]
    if not args or args[0] not in READERS:
        sys.stderr.write("usage: leadv2-quota-read.py glm|codex|anthropic [--no-cache]\n")
        sys.exit(2)
    provider = args[0]
    if "--no-cache" not in args:
        cached = cache_get(provider)
        if cached is not None:
            print(json.dumps(cached))
            return
    obj = READERS[provider]()
    obj.setdefault("provider", provider)
    obj.setdefault("fetched_at", iso_now())
    cache_put(provider, obj)
    print(json.dumps(obj))


if __name__ == "__main__":
    main()
