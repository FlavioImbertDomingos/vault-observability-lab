#!/usr/bin/env python3
"""Generates grafana/dashboards/vault-overview.json. Edit here, then run: python3 grafana/build_dashboard.py"""
import json, os, re

FILTER = True   # add {cluster="$cluster"} to every Vault metric (turned off for the multi-cloud dashboard)


def scoped(expr):
    if not FILTER:
        return expr
    def rep(m):
        inner = m.group(3)
        return f'{m.group(1)}{{cluster="$cluster"' + (f",{inner}" if inner else "") + "}"
    return re.sub(r'\b(vault_[A-Za-z0-9_]+)(\{([^}]*)\})?', rep, expr)


DS = {"type": "prometheus", "uid": "prometheus"}
panels, y = [], 0
pid = 0


def nid():
    global pid
    pid += 1
    return pid


def row(title):
    global y
    panels.append({"type": "row", "title": title, "id": nid(), "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})
    y += 1


def stat(title, expr, x, w=3, h=4, unit="none", thresholds=None, legend=None, text_mode="value", desc=""):
    steps = thresholds or [{"color": "green", "value": None}]
    panels.append({
        "type": "stat", "title": title, "id": nid(), "datasource": DS, "description": desc,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "datasource": DS, "expr": scoped(expr), "instant": True,
                     "legendFormat": legend or "__auto"}],
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps},
                                     "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "none", "textMode": text_mode,
                    "justifyMode": "center", "orientation": "auto"},
    })


def ts(title, targets, x, w=12, h=8, unit="none", desc="", stack=False, thresholds=None):
    t = [{"refId": chr(65 + i), "datasource": DS, "expr": scoped(e), "legendFormat": l} for i, (e, l) in enumerate(targets)]
    defaults = {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 10, "showPoints": "never",
                                         "stacking": {"mode": "normal" if stack else "none"}}}
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
        defaults["custom"]["thresholdsStyle"] = {"mode": "line+area"}
    panels.append({
        "type": "timeseries", "title": title, "id": nid(), "datasource": DS, "description": desc,
        "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": t,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    })


RED0 = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
GREEN_RED = [{"color": "green", "value": None}, {"color": "red", "value": 1}]

# ------------------------------------------------------------------ health
row("Cluster health")
stat("Unsealed", "sum(vault_core_unsealed)", 0,
     thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 3}],
     desc="vault.core.unsealed summed over nodes. Any node at 0 during normal operation needs attention.")
stat("Active node", "vault_core_active == 1", 3, legend="{{node}}", text_mode="name",
     thresholds=[{"color": "blue", "value": None}], desc="The node reporting vault.core.active = 1.")
stat("Raft peers", "max(vault_raft_peers)", 6,
     thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 3}])
stat("Fault tolerance", "max(vault_autopilot_failure_tolerance)", 9, thresholds=RED0,
     desc="How many voters can fail before quorum is lost (autopilot).")
stat("Autopilot OK", "max(vault_autopilot_healthy)", 12, thresholds=RED0)
stat("Audit fails 1h",
     "round(sum(increase(vault_audit_log_request_failure[1h])) + sum(increase(vault_audit_log_response_failure[1h])))",
     15, thresholds=GREEN_RED, desc="If every audit device fails, Vault stops serving requests.")
stat("Root tokens 24h", "round(sum(increase(vault_token_create_root[24h])))", 18,
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.5}],
     desc="vault.token.create_root. Alert on any change.")
stat("Locked users", "max(vault_core_locked_users) or vector(0)", 21,
     thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
     desc="userpass/LDAP/AppRole user lockout after repeated failed logins (default 5 attempts, 15 min).")
y += 4
stat("Active leases", "sum(vault_expire_num_leases)", 0, w=4,
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 100000},
                 {"color": "red", "value": 250000}])
stat("Tokens", "sum(vault_token_count)", 4, w=4, thresholds=[{"color": "blue", "value": None}])
stat("Identity entities", "sum(vault_identity_entity_count)", 8, w=4, thresholds=[{"color": "blue", "value": None}])
stat("Requests / s", "sum(rate(vault_core_handle_request_count[1m]))", 12, w=4, unit="reqps",
     thresholds=[{"color": "blue", "value": None}])
stat("p99 latency (active)", 'max(vault_core_handle_request{quantile="0.99"} * on(instance) group_left() (vault_core_active == 1))',
     16, w=4, unit="ms", thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 250},
                                     {"color": "red", "value": 500}])
stat("429s in last hour", "round(sum(increase(vault_quota_rate_limit_violation[1h]))) or vector(0)", 20, w=4,
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
y += 4

# ---------------------------------------------------------------- requests
row("Requests")
ts("Request rate by node (req/s)", [("rate(vault_core_handle_request_count[1m])", "{{node}}")], 0, unit="reqps",
   desc="vault.core.handle_request. Standbys forward to the active node, so the active node carries the load.")
ts("Request latency on the active node (ms)",
   [('max by (quantile) (vault_core_handle_request{quantile=~"0.5|0.9|0.99"} '
     '* on(instance) group_left() (vault_core_active == 1))', "p{{quantile}}")], 12, unit="ms",
   desc="Alert when latency rises more than 50% or 3 standard deviations above your baseline.")
y += 8
ts("Logins per second", [("rate(vault_core_handle_login_request_count[1m])", "{{node}}")], 0, w=8, unit="reqps")
ts("Login latency p99 (ms)", [('vault_core_handle_login_request{quantile="0.99"}', "{{node}}")], 8, w=8, unit="ms")
ts("Rate limit quota violations (per min)",
   [("sum by (name) (increase(vault_quota_rate_limit_violation[1m]))", "{{name}}")], 16, w=8,
   desc="quota.rate_limit.violation. Clients get HTTP 429. The lab generates a burst about every 10 minutes.")
y += 8
ts("In-flight requests", [("vault_core_in_flight_requests", "{{node}}")], 0, w=8)
ts("Audit log writes per second", [("rate(vault_audit_log_request_count[1m])", "request {{node}}"),
                                   ("rate(vault_audit_log_response_count[1m])", "response {{node}}")], 8, w=8,
   unit="ops")
ts("Requests forwarded by standbys (per s)", [("rate(vault_ha_rpc_client_forward_count[1m])", "{{node}}")], 16, w=8,
   unit="reqps")
y += 8

# ------------------------------------------------------------------ usage
row("Usage and capacity")
ts("Active leases", [("vault_expire_num_leases", "{{node}}")], 0, w=8,
   desc="vault.expire.num_leases. A steady climb is a lease explosion: shorten TTLs or use batch tokens.")
ts("Tokens by policy", [("sum by (policy) (vault_token_count_by_policy)", "{{policy}}")], 8, w=8, stack=True)
ts("Token creation by auth method (per min)",
   [("sum by (auth_method) (rate(vault_token_creation[5m])) * 60", "{{auth_method}}")], 16, w=8)
y += 8
ts("Identity entities", [("sum(vault_identity_entity_count)", "entities")], 0, w=8,
   desc="Large entity and group counts slow ACL evaluation.")
ts("KV secrets by mount", [("sum by (mount_point) (vault_secret_kv_count)", "{{mount_point}}")], 8, w=8)
ts("Irrevocable leases", [("sum(vault_expire_num_irrevocable_leases)", "irrevocable")], 16, w=8,
   desc="Leases Vault could not revoke. A rising count needs investigation.")
y += 8

# ------------------------------------------------------------------- raft
row("Integrated Storage (Raft)")
ts("Leader last contact p99 (ms)", [('vault_raft_leader_lastContact{quantile="0.99"}', "{{node}}")], 0, w=8,
   unit="ms", desc="Time since the leader last heard from followers. Rising values mean network or disk trouble.")
ts("Follower heartbeat age (ms)", [("vault_raft_storage_follower_last_heartbeat_ms", "{{peer_id}}")], 8, w=8,
   unit="ms")
ts("Raft commit time p99 (ms)", [('vault_raft_commitTime{quantile="0.99"}', "{{node}}")], 16, w=8, unit="ms")
y += 8
ts("Applied index by node", [("vault_raft_storage_stats_applied_index", "{{node}}")], 0, w=8,
   desc="Followers should track the leader closely.")
ts("Storage put / get p99 (ms)", [('vault_raft_storage_put{quantile="0.99"}', "put {{node}}"),
                                  ('vault_raft_storage_get{quantile="0.99"}', "get {{node}}")], 8, w=8, unit="ms")
ts("BoltDB freelist used (bytes)", [("sum by (node) (vault_raft_storage_bolt_freelist_used_bytes)", "{{node}}")],
   16, w=8,
   unit="bytes")
y += 8

# ---------------------------------------------------------------- runtime
row("Runtime")
ts("Memory from the OS (sys_bytes)", [("vault_runtime_sys_bytes", "{{node}}")], 0, w=8, unit="bytes",
   desc="Add memory when it passes 90% of the host.")
ts("GC pause (seconds per minute)", [("rate(vault_runtime_total_gc_pause_ns[2m]) * 60 / 1e9", "{{node}}")], 8, w=8,
   unit="s", thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 2},
                         {"color": "red", "value": 5}],
   desc="HashiCorp guidance: warn above 2 s per minute, critical above 5 s.")
ts("Goroutines", [("vault_runtime_num_goroutines", "{{node}}")], 16, w=8)
y += 8

dash = {
    "uid": "vault-overview", "title": "Vault overview", "tags": ["vault"], "timezone": "browser",
    "schemaVersion": 39, "version": 1, "refresh": "15s", "time": {"from": "now-1h", "to": "now"},
    "panels": panels, "templating": {"list": [{
        "name": "cluster", "label": "Cluster", "type": "query", "datasource": DS,
        "query": {"query": "label_values(vault_core_unsealed, cluster)", "refId": "cluster"},
        "definition": "label_values(vault_core_unsealed, cluster)", "refresh": 2, "sort": 1,
        "current": {"text": "cloud-a", "value": "cloud-a"}, "includeAll": False, "multi": False}]}, "annotations": {"list": []},
    "description": "Vault lab: key metrics from HashiCorp's monitoring guidance",
}
out = os.path.join(os.path.dirname(__file__), "dashboards", "vault-overview.json")
with open(out, "w") as f:
    json.dump(dash, f, indent=2)
print("wrote", out, len(panels), "panels")


# ------------------------------------------------------------------ multi-cloud
# Side-by-side view of every cluster Prometheus knows about (cloud-a, cloud-b, ...).
FILTER = False
panels, y, pid = [], 0, 0
row("Clusters side by side")
ts("Unsealed nodes per cluster", [("sum by (cluster) (vault_core_unsealed)", "{{cluster}}")], 0, w=8)
ts("Raft fault tolerance per cluster", [("max by (cluster) (vault_autopilot_failure_tolerance)", "{{cluster}}")], 8, w=8,
   desc="0 means the cluster cannot lose another voter.")
ts("Active node per cluster", [("max by (cluster, node) (vault_core_active) == 1", "{{cluster}}: {{node}}")], 16, w=8,
   desc="A leader change shows as a new line.")
y += 8
row("Load and usage")
ts("Requests per second", [("sum by (cluster) (rate(vault_core_handle_request_count[1m]))", "{{cluster}}")], 0, w=8,
   unit="reqps")
ts("p99 latency on the active node (ms)",
   [('max by (cluster) (vault_core_handle_request{quantile="0.99"} * on(instance) group_left() (vault_core_active == 1))',
     "{{cluster}}")], 8, w=8, unit="ms")
ts("Logins per second", [("sum by (cluster) (rate(vault_core_handle_login_request_count[1m]))", "{{cluster}}")], 16,
   w=8, unit="reqps")
y += 8
ts("Active leases", [("sum by (cluster) (vault_expire_num_leases)", "{{cluster}}")], 0, w=8)
ts("Tokens", [("sum by (cluster) (vault_token_count)", "{{cluster}}")], 8, w=8)
ts("KV secrets by mount", [("sum by (cluster, mount_point) (vault_secret_kv_count)", "{{cluster}} {{mount_point}}")],
   16, w=8, desc="After terraform apply, the platform/ mount appears with the same count in every cluster.")
y += 8
row("Health signals")
ts("Audit failures (per 5 min)",
   [("sum by (cluster) (increase(vault_audit_log_request_failure[5m]) + increase(vault_audit_log_response_failure[5m]))",
     "{{cluster}}")], 0, w=8)
ts("Raft commit time p99 (ms)", [('max by (cluster) (vault_raft_commitTime{quantile="0.99"})', "{{cluster}}")], 8,
   w=8, unit="ms")
ts("Memory (sys_bytes, sum of nodes)", [("sum by (cluster) (vault_runtime_sys_bytes)", "{{cluster}}")], 16, w=8,
   unit="bytes")
y += 8
multi = {
    "uid": "vault-multicloud", "title": "Vault multi-cloud", "tags": ["vault"], "timezone": "browser",
    "schemaVersion": 39, "version": 1, "refresh": "15s", "time": {"from": "now-1h", "to": "now"},
    "panels": panels, "templating": {"list": []}, "annotations": {"list": []},
    "description": "Every Vault cluster side by side (./lab.sh multicloud up adds cloud-b)",
}
out = os.path.join(os.path.dirname(__file__), "dashboards", "vault-multicloud.json")
with open(out, "w") as f:
    json.dump(multi, f, indent=2)
print("wrote", out, len(panels), "panels")
