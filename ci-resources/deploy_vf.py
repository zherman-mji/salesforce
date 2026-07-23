#!/usr/bin/env python3
"""Deploy changed VF pages to Salesforce via Tooling API PATCH."""
import json, os, sys, subprocess, urllib.request, urllib.parse, urllib.error, time

private_key = os.environ.get("SF_PRIVATE_KEY", "")
key_path = "/tmp/server.key"
with open(key_path, "w") as f:
    f.write(private_key)

client_id = os.environ["SF_CLIENT_ID"]
client_secret = os.environ["SF_CLIENT_SECRET"]
username = os.environ["SF_USERNAME"]
instance_url = os.environ["SF_INSTANCE_URL"]

import jwt
now = int(time.time())
payload = {
    "iss": client_id,
    "sub": username,
    "aud": "https://login.salesforce.com",
    "exp": now + 300,
    "iat": now,
}
with open(key_path) as f:
    pk = f.read()
assertion = jwt.encode(payload, pk, algorithm="RS256")

data = {
    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "assertion": assertion,
    "client_id": client_id,
    "client_secret": client_secret,
}
req = urllib.request.Request(
    "https://login.salesforce.com/services/oauth2/token",
    data=urllib.parse.urlencode(data).encode("utf-8"),
    headers={"Content-Type": "application/x-www-form-urlencoded"},
)
with urllib.request.urlopen(req) as resp:
    auth_result = json.loads(resp.read().decode())
    token = auth_result["access_token"]
    instance = auth_result["instance_url"]

headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

result = subprocess.run(
    ["git", "diff", "--name-only", "--diff-filter=AM", "HEAD~1", "--",
     "force-app/main/default/pages/"],
    capture_output=True, text=True, cwd=os.getcwd()
)
changed_pages = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]

if not changed_pages:
    print("No VF pages changed in this push.")
    sys.exit(0)

for page_path in changed_pages:
    page_name = os.path.splitext(os.path.basename(page_path))[0]
    print(f"Deploying {page_name}...")
    with open(page_path) as f:
        markup = f.read()
    q = urllib.parse.quote(f"SELECT Id FROM ApexPage WHERE Name='{page_name}'")
    req = urllib.request.Request(
        f"{instance}/services/data/v60.0/tooling/query?q={q}", headers=headers)
    with urllib.request.urlopen(req) as resp:
        records = json.loads(resp.read().decode()).get("records", [])
    if not records:
        print(f"  WARNING: {page_name} not found (new page? needs SFDX deploy)")
        continue
    pid = records[0]["Id"]
    patch_req = urllib.request.Request(
        f"{instance}/services/data/v60.0/tooling/sobjects/ApexPage/{pid}",
        data=json.dumps({"Markup": markup}).encode(),
        headers=headers, method="PATCH")
    with urllib.request.urlopen(patch_req) as resp:
        print(f"  {page_name} deployed (status {resp.status})")