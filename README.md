# openflake-mcp on OpenShift

OpenFlake MCP server, deployable to any OpenShift cluster in one AAP job.

```
Containerfile              app image (pins mcp<2 — see below)
start.py                   uvicorn entrypoint
nginx/
  default.conf.template    bearer-token gate, token substituted at deploy
openshift/
  build.yaml               ImageStream + BuildConfig (Git source)
  deploy.yaml              Deployment + Service + Route
playbooks/
  deploy-openflake-mcp.yml AAP-ready playbook, the whole deploy
collections/
  requirements.yml         kubernetes.core, synced automatically by AAP
```

Secrets are never in this repo. They are created at deploy time and live only
in the cluster.

---

## Two things that will break this if you change them

**1. The `mcp<2` pin in `Containerfile`.** Upstream is v1 code; mcp 2.x renamed
`FastMCP` to `MCPServer`. Unpinned, the pod crashes with
`ModuleNotFoundError: No module named 'mcp.server.fastmcp'`. The pin appears
twice because `pip install -e .` can pull it back up.

**2. `proxy_set_header Host 127.0.0.1:8000` in the nginx template.** The MCP
Python SDK validates the `Host` header as DNS-rebinding protection. Change it
to `$host` and you get a healthy 2/2 pod that fails every request.

---

## Deploy from AAP

One job template does the whole deploy, and it is safe to re-run.

**Project** — point an AAP project at this repo, branch `main`. AAP reads
`collections/requirements.yml` on sync and installs `kubernetes.core`.

**Credential** — attach an *OpenShift or Kubernetes API Bearer Token*
credential to the job template. AAP exports `K8S_AUTH_HOST`,
`K8S_AUTH_API_KEY` and `K8S_AUTH_VERIFY_SSL`, and `kubernetes.core` reads them
on its own. The playbook never takes a host or token as a variable — do not add
them to the survey.

**Job template** — playbook `playbooks/deploy-openflake-mcp.yml`, inventory any
(everything runs on `localhost`), and a survey supplying:

| Variable | Required | Default | Notes |
|---|---|---|---|
| `openflake_instance_url` | yes | | trailing slash added if you forget |
| `openflake_username` | yes | | |
| `openflake_password` | yes | | mark the survey answer **encrypted** |
| `openflake_git_uri` | yes | | this repo's clone URL |
| `openflake_namespace` | no | `openflake-mcp` | |
| `openflake_git_ref` | no | `main` | |
| `openflake_bearer_token` | no | generated | supply to pin a known token |
| `openflake_rotate_token` | no | `false` | mint a new token over an existing one |
| `openflake_validate_certs` | no | `true` | `false` for a self-signed Route cert |

On the first run the playbook mints a bearer token and prints it once. On later
runs it leaves the existing token alone, so re-running to change the OpenFlake
instance does not break your clients. Set `openflake_rotate_token=true` when you
actually want a new one.

### Run it from a laptop instead

```bash
oc login <api-url>
ansible-galaxy collection install -r collections/requirements.yml
ansible-playbook playbooks/deploy-openflake-mcp.yml \
  -e openflake_instance_url=https://your.openflake.example.com/ \
  -e openflake_username=svc-mcp \
  -e openflake_password='...' \
  -e openflake_git_uri=https://github.com/rlopez133/openflake-mcp.git
```

---

### Manual, if you prefer

```bash
oc new-project openflake-mcp

oc create secret generic openflake-mcp-env \
  --from-literal=OPENFLAKE_INSTANCE_URL='https://your.openflake.example.com/' \
  --from-literal=OPENFLAKE_USERNAME='your-username' \
  --from-literal=OPENFLAKE_PASSWORD='your-password'

TOKEN=$(openssl rand -hex 32); echo "$TOKEN"
sed "s|REPLACE_ME|$TOKEN|" nginx/default.conf.template > /tmp/default.conf
oc create secret generic openflake-mcp-nginx-conf --from-file=default.conf=/tmp/default.conf
rm /tmp/default.conf

sed -e "s|GIT_URI|https://github.com/rlopez133/openflake-mcp.git|" \
    -e "s|GIT_REF|main|" openshift/build.yaml | oc apply -f -
oc start-build openflake-mcp --follow

oc apply -f openshift/deploy.yaml
oc get pods -w
```

---

## Verify

```bash
URL="https://$(oc get route openflake-mcp -o jsonpath='{.spec.host}')"

curl -i "$URL/"                                        # must be 401
curl -i -H "Authorization: Bearer $TOKEN" "$URL/mcp"   # 406 = success
```

A **406** with a JSON-RPC body about `text/event-stream` and an
`mcp-session-id` header is the success signal: nginx authenticated, proxied,
and the app answered. Only the 401 check is a real gate — if an
unauthenticated request returns anything else, stop, because the Route is
public and the app has no auth of its own.

Neither check exercises your OpenFlake credentials. A running pod only proves
the three env vars are present; bad credentials surface as OpenFlake 401s on
the first real tool call. Make one query from your client before calling it
done.

Client endpoint is `$URL/mcp` with header `Authorization: Bearer <token>`.

---

## Rebuild after a code change

```bash
git push
oc start-build openflake-mcp --follow
```

The image trigger redeploys automatically. Re-running the AAP job template does
the same thing and is the better habit — it rebuilds from `openflake_git_ref`
and waits for the rollout. To rebuild on every push, add a webhook:
**Builds → BuildConfigs → openflake-mcp → Webhooks**, copy the GitHub URL with
its secret, and paste it into the repo's webhook settings.

## Point at a different OpenFlake instance

Update the secret and restart — `envFrom` is resolved at pod start, so editing
the secret alone does nothing. No rebuild: nothing about the instance is baked
into the image.

```bash
oc create secret generic openflake-mcp-env \
  --from-literal=OPENFLAKE_INSTANCE_URL='https://other.openflake.example.com/' \
  --from-literal=OPENFLAKE_USERNAME='your-username' \
  --from-literal=OPENFLAKE_PASSWORD='your-password' \
  --dry-run=client -o yaml | oc apply -f -

oc rollout restart deployment/openflake-mcp
```

Pass all three literals — that pipeline replaces the whole secret. Or re-run the
AAP job with the new values, which restarts the deployment for you and leaves
the bearer token untouched.

## Rotate the token

```bash
TOKEN=$(openssl rand -hex 32); echo "$TOKEN"
sed "s|REPLACE_ME|$TOKEN|" nginx/default.conf.template > /tmp/default.conf
oc create secret generic openflake-mcp-nginx-conf --from-file=default.conf=/tmp/default.conf \
  --dry-run=client -o yaml | oc apply -f -
rm /tmp/default.conf
oc rollout restart deployment/openflake-mcp
```

Or run the AAP job with `openflake_rotate_token=true`.

Only one token is valid at a time. The old one dies the moment the new pod
serves traffic — no grace period, so clients break instantly.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ModuleNotFoundError: mcp.server.fastmcp` | `mcp<2` pin missing or overridden |
| `KeyError: 'OPENFLAKE_INSTANCE_URL'` | `openflake-mcp-env` missing a key |
| Pod stuck `1/2` | Usually nginx: `oc logs deploy/openflake-mcp -c nginx` |
| nginx won't start | Wrong image — stock `nginx:alpine` needs root |
| 401 with the right token | Substitution failed; `oc exec deploy/openflake-mcp -c nginx -- cat /etc/nginx/conf.d/default.conf` |
| Pod healthy, every request fails | `Host` header not pinned to `127.0.0.1:8000` |
| Drops after ~30s | Route timeout annotation missing |
| Build fails at `git clone` | Build pod has no egress to github.com, or the repo went private (see `build.yaml`) |
| Permission errors on `/app` | Add `RUN chmod -R g=u /app` before `USER 1001` |
| `ImagePullBackOff` | Build never pushed: `oc get istag openflake-mcp:latest` |
| Playbook: `Failed to import kubernetes` | EE lacks the `kubernetes` python lib; use a k8s-capable EE |
| Playbook: 401/403 from the API | Job template credential missing or lacks namespace rights |

```bash
oc logs deploy/openflake-mcp -c openflake-mcp
oc logs deploy/openflake-mcp -c nginx
oc logs -f bc/openflake-mcp
```

---

## Known drift risk

`Containerfile` clones upstream with `--branch master`, so builds are not
reproducible — upstream can change between builds. That is exactly how the
mcp 2.x break arrived. To pin, grab the current SHA:

```bash
git ls-remote https://github.com/cooktheryan/servicenow-mcp.git master
```

and replace the clone line with a clone plus `git checkout <sha>`.
