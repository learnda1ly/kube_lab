# Mac Universal Forwarder → lab Splunk

Local UF install (this laptop) forwarding to k3s Splunk on S2S `:9997`, and
phoning home to the lab **deployment server** on mgmt `:8089`.

## Layout (on the Mac)

| Path | Purpose |
|------|---------|
| `~/splunkforwarder` | UF 9.3.x home (matches lab indexer major) |
| `~/splunkforwarder/etc/system/local/outputs.conf` | Forward to `192.168.1.20:9997` |
| `~/splunkforwarder/etc/system/local/deploymentclient.conf` | Phone home to `192.168.1.20:8089` |
| `~/splunkforwarder/etc/apps/TA-add-on-for-apple-unified-logging/` | Deployed by DS (`mac_endpoints` server class) |
| `~/splunkforwarder/etc/apps/macos_activity/` | Shell history + Cursor agent/activity monitors |
| `~/splunk-uf-test-logs/` | Drop / append files here for a quick ingest test |

Do not point `$SPLUNK_HOME` at `/Applications/Splunk` when managing the UF — this Mac also has full Splunk Enterprise installed there.

## Deployment server (k3s)

| Piece | Location |
|-------|----------|
| App bundle | `/opt/splunk/etc/deployment-apps/TA-add-on-for-apple-unified-logging` |
| Inputs overlay | that app's `local/inputs.conf` (logd + system/install logs → `macos`) |
| Server class | `mac_endpoints` in `serverclass.conf` |
| Repo copies | `manifests/splunk/serverclass.conf`, `deployment-apps/...`, `service-mgmt.yaml` |

After editing server classes on the indexer:

```bash
kubectl -n splunk exec deploy/splunk -- sudo -u splunk -E \
  /opt/splunk/bin/splunk reload deploy-server -auth "admin:${SPLUNK_PASSWORD}"
```

## Start / stop

```bash
export SPLUNK_HOME="$HOME/splunkforwarder"
"$SPLUNK_HOME/bin/splunk" start --accept-license --answer-yes --no-prompt </dev/null
"$SPLUNK_HOME/bin/splunk" status </dev/null
"$SPLUNK_HOME/bin/splunk" stop </dev/null
```

## outputs.conf (reference)

```ini
[tcpout]
defaultGroup = kube_lab
disabled = false

[tcpout:kube_lab]
server = 192.168.1.20:9997
```

## deploymentclient.conf (reference)

```ini
[deployment-client]
clientName = Stephens-MacBook-Pro-2
phoneHomeIntervalInSecs = 60

[target-broker:deploymentServer]
targetUri = 192.168.1.20:8089
```

## Verify

Search UI (`http://192.168.1.20:30080`):

```
index=macos earliest=-1h
```

Shell history / Cursor actions:

```
index=macos sourcetype=mac:zsh_history
index=macos sourcetype=cursor:log
index=macos sourcetype=cursor:agent_transcript
index=macos sourcetype=cursor:agent_terminal
```

Confirm apps on the Mac:

```bash
ls ~/splunkforwarder/etc/apps/TA-add-on-for-apple-unified-logging
ls ~/splunkforwarder/etc/apps/macos_activity
```
## Smoke test (non-TA path)

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) hello from mac uf" >> ~/splunk-uf-test-logs/labtest.log
# index=main sourcetype=mac:labtest
```
