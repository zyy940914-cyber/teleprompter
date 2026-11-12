#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 ios-app 上传到 GitHub 并触发云端编译，最后下载 .ipa
用法：GH_TOKEN=xxx python3 upload_to_github.py
"""
import os, sys, json, base64, time, shutil, zipfile, urllib.request, urllib.error

TOKEN = os.environ.get("GH_TOKEN", "").strip()
OWNER = os.environ.get("GH_OWNER", "zyy940914-cyber")
REPO = os.environ.get("GH_REPO", "teleprompter")
SRC = os.environ.get("SRC_DIR", "/Users/yuanyuan/WorkBuddy/2026-11-12-11-01-32/ios-app")
OUT_IPA = "/Users/yuanyuan/WorkBuddy/2026-11-12-11-01-32/Teleprompter.ipa"
API = "https://api.github.com"

if not TOKEN:
    print("缺少 GH_TOKEN 环境变量")
    sys.exit(2)


def api(method, path, data=None, raw=False, timeout=90):
    url = path if path.startswith("http") else API + path
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(url, data=body, method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            payload = resp.read()
            return resp.status, (payload if raw else (json.loads(payload) if payload else {})), resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore"), e.headers


def check_token():
    code, data, _ = api("GET", "/user")
    if code != 200:
        print("❌ 令牌无效：", str(data)[:200])
        sys.exit(3)
    print("✅ 令牌有效，账号：", data.get("login"), "权限范围：", _[ "x-oauth-scopes"] if "x-oauth-scopes" in _ else "（细粒度令牌）")
    return data.get("login")


def ensure_repo():
    code, data, _ = api("GET", f"/repos/{OWNER}/{REPO}")
    if code == 200:
        print(f"✅ 仓库已存在：{OWNER}/{REPO}")
        return True
    code, data, _ = api("POST", "/user/repos", {
        "name": REPO,
        "private": True,
        "description": "悬浮提词器 iOS App（源码 + 云端编译流水线）",
        "auto_init": False,
        "has_issues": False,
        "has_wiki": False,
    })
    if code in (200, 201):
        print(f"✅ 已创建私有仓库：{OWNER}/{REPO}")
        return True
    print("❌ 创建仓库失败：", str(data)[:300])
    return False


def collect_files():
    out = []
    for root, dirs, files in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for f in files:
            if f in (".DS_Store",):
                continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, SRC)
            out.append((p, rel))
    return sorted(out, key=lambda x: x[1])


def upload_files():
    files = collect_files()
    print(f"准备上传 {len(files)} 个文件…")
    ok = 0
    for path, rel in files:
        with open(path, "rb") as fh:
            content = base64.b64encode(fh.read()).decode()
        code, data, _ = api("PUT", f"/repos/{OWNER}/{REPO}/contents/{rel}", {
            "message": f"add {rel}",
            "content": content,
            "branch": "main",
        })
        if code in (200, 201):
            ok += 1
            print(f"  ✓ {rel}")
        else:
            print(f"  ✗ {rel} -> {code} {str(data)[:200]}")
    print(f"上传完成：{ok}/{len(files)}")
    return ok == len(files)


def trigger_workflow():
    code, data, _ = api("POST", f"/repos/{OWNER}/{REPO}/actions/workflows/build-ipa.yml/dispatches",
                        {"ref": "main"})
    if code in (204, 201, 200):
        print("✅ 已触发云端编译")
        return True
    print("❌ 触发失败：", code, str(data)[:300])
    return False


def wait_run(max_wait=1500):
    print("等待编译完成（通常 5–8 分钟）…")
    start = time.time()
    run_id = None
    while time.time() - start < max_wait:
        code, data, _ = api("GET", f"/repos/{OWNER}/{REPO}/actions/runs?per_page=5")
        if code == 200 and data.get("workflow_runs"):
            run = data["workflow_runs"][0]
            run_id = run["id"]
            status, concl = run["status"], run.get("conclusion")
            print(f"  状态：{status} {concl or ''}")
            if status == "completed":
                if concl == "success":
                    print("✅ 编译成功")
                    return run_id
                print(f"❌ 编译失败：{concl}")
                return run_id
        time.sleep(20)
    print("⌛ 等待超时")
    return run_id


def print_logs(run_id):
    code, data, _ = api("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/jobs")
    if code != 200:
        print("无法读取任务信息", code)
        return
    for job in data.get("jobs", []):
        print(f"\n任务：{job['name']} -> {job.get('conclusion')}")
        for step in job.get("steps", []):
            print(f"  {step['number']}. {step['name']}: {step.get('conclusion')}")
        if job.get("conclusion") != "success":
            jid = job["id"]
            code2, logs, _ = api("GET", f"/repos/{OWNER}/{REPO}/actions/jobs/{jid}/logs", raw=True)
            if code2 == 200:
                text = logs.decode("utf-8", "ignore") if isinstance(logs, bytes) else str(logs)
                lines = [l for l in text.splitlines() if "error:" in l.lower() or "failed" in l.lower()]
                print("\n---- 编译报错摘要 ----")
                print("\n".join(lines[-40:]) if lines else text[-3000:])


def download_artifact(run_id):
    code, data, _ = api("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/artifacts")
    if code != 200 or not data.get("artifacts"):
        print("没有找到安装包产物：", code)
        return None
    art = data["artifacts"][0]
    print("产物：", art["name"], art["size_in_bytes"], "bytes")
    url = art["archive_download_url"]
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    tmp_zip = "/tmp/gh_artifact.zip"
    try:
        with urllib.request.urlopen(req, timeout=300) as resp, open(tmp_zip, "wb") as out:
            shutil.copyfileobj(resp, out)
    except Exception as e:
        print("下载失败：", e)
        return None
    with zipfile.ZipFile(tmp_zip) as z:
        names = z.namelist()
        print("压缩包内容：", names)
        with z.open(names[0]) as src, open(OUT_IPA, "wb") as dst:
            shutil.copyfileobj(src, dst)
    size = os.path.getsize(OUT_IPA)
    print(f"✅ 已保存安装包：{OUT_IPA}（{size/1024/1024:.1f} MB）")
    return OUT_IPA


if __name__ == "__main__":
    check_token()
    if not ensure_repo():
        sys.exit(4)
    if not upload_files():
        sys.exit(5)
    if not trigger_workflow():
        sys.exit(6)
    run_id = wait_run()
    if not run_id:
        sys.exit(7)
    code, run, _ = api("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}")
    if run.get("conclusion") == "success":
        download_artifact(run_id)
    else:
        print_logs(run_id)
        print("\n把上面的报错发给我，我来改代码后重跑。")
