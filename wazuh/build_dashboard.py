#!/usr/bin/env python3
"""Generates wazuh/vault-siem-dashboard.ndjson (OpenSearch Dashboards saved objects).
./lab.sh up imports it into the Wazuh dashboard. Edit here, then: python3 wazuh/build_dashboard.py"""
import json, os

IDX = "wazuh-alerts-*"
objs, panels, refs = [], [], []


def source(query):
    return json.dumps({"query": {"query": query, "language": "kuery"}, "filter": [],
                       "indexRefName": "kibanaSavedObjectMeta.searchSourceJSON.index"})


def vis(vid, title, vtype, params, aggs, query):
    objs.append({
        "type": "visualization", "id": vid,
        "attributes": {
            "title": title, "description": "", "version": 1, "uiStateJSON": "{}",
            "visState": json.dumps({"title": title, "type": vtype, "params": params, "aggs": aggs}),
            "kibanaSavedObjectMeta": {"searchSourceJSON": source(query)},
        },
        "references": [{"name": "kibanaSavedObjectMeta.searchSourceJSON.index", "type": "index-pattern", "id": IDX}],
    })


def place(oid, otype, x, y, w, h):
    i = str(len(panels) + 1)
    panels.append({"embeddableConfig": {}, "gridData": {"x": x, "y": y, "w": w, "h": h, "i": i},
                   "panelIndex": i, "version": "2.19.0", "panelRefName": f"panel_{len(refs)}"})
    refs.append({"name": f"panel_{len(refs)}", "type": otype, "id": oid})


COUNT = {"id": "1", "enabled": True, "type": "count", "params": {}, "schema": "metric"}


def terms(aid, field, size, schema):
    return {"id": aid, "enabled": True, "type": "terms", "schema": schema,
            "params": {"field": field, "orderBy": "1", "order": "desc", "size": size, "otherBucket": False,
                       "missingBucket": False}}


def metric(vid, title, query, x, color="#54B399"):
    vis(vid, title, "metric", {
        "addTooltip": True, "addLegend": False, "type": "metric",
        "metric": {"percentageMode": False, "useRanges": False, "colorSchema": "Green to Red",
                   "metricColorMode": "None", "colorsRange": [{"from": 0, "to": 10000}],
                   "labels": {"show": True}, "invertColors": False,
                   "style": {"bgFill": "#000", "bgColor": False, "labelColor": False, "subText": "", "fontSize": 48}}},
        [dict(COUNT, params={"customLabel": title})], query)
    place(vid, "visualization", x, 0, 8, 7)


def table(vid, title, query, fields, x, y, w, h=14, size=10):
    aggs = [COUNT] + [terms(str(i + 2), f, size, "bucket") for i, f in enumerate(fields)]
    vis(vid, title, "table", {"perPage": 10, "showPartialRows": False, "showMetricsAtAllLevels": False,
                              "showTotal": False, "totalFunc": "sum", "percentageCol": ""}, aggs, query)
    place(vid, "visualization", x, y, w, h)


# headline counts
metric("vault-m-all", "Vault alerts", "rule.groups:vault", 0)
metric("vault-m-high", "Level 10+", "rule.groups:vault and rule.level >= 10", 8)
metric("vault-m-login", "Failed logins", "rule.id:100110", 16)
metric("vault-m-root", "Root token events", "rule.groups:vault_root", 24)
metric("vault-m-priv", "Privileged operations", "rule.groups:vault_privileged", 32)
metric("vault-m-denied", "Permission denied", "rule.id:100120", 40)

# timeline
vis("vault-timeline", "Vault alerts over time", "histogram", {
    "type": "histogram", "addTooltip": True, "addLegend": True, "legendPosition": "right", "times": [],
    "addTimeMarker": False, "grid": {"categoryLines": False},
    "categoryAxes": [{"id": "CategoryAxis-1", "type": "category", "position": "bottom", "show": True,
                      "scale": {"type": "linear"}, "labels": {"show": True, "filter": True, "truncate": 100},
                      "title": {}}],
    "valueAxes": [{"id": "ValueAxis-1", "name": "LeftAxis-1", "type": "value", "position": "left", "show": True,
                   "scale": {"type": "linear", "mode": "normal"},
                   "labels": {"show": True, "rotate": 0, "filter": False, "truncate": 100}, "title": {"text": "Alerts"}}],
    "seriesParams": [{"show": True, "type": "histogram", "mode": "stacked", "data": {"label": "Alerts", "id": "1"},
                      "valueAxis": "ValueAxis-1", "drawLinesBetweenPoints": True, "lineWidth": 2,
                      "showCircles": True}],
    "labels": {"show": False}, "thresholdLine": {"show": False, "value": 10, "width": 1, "style": "full",
                                                 "color": "#E7664C"}},
    [COUNT,
     {"id": "2", "enabled": True, "type": "date_histogram", "schema": "segment",
      "params": {"field": "timestamp", "useNormalizedOpenSearchInterval": True, "interval": "auto",
                 "drop_partials": False, "min_doc_count": 1, "extended_bounds": {}}},
     terms("3", "rule.description", 8, "group")],
    "rule.groups:vault")
place("vault-timeline", "visualization", 0, 7, 48, 14)

# breakdowns
vis("vault-levels", "Alerts by level", "pie",
    {"type": "pie", "addTooltip": True, "addLegend": True, "legendPosition": "right", "isDonut": True,
     "labels": {"show": False, "values": True, "last_level": True, "truncate": 100}},
    [COUNT, terms("2", "rule.level", 10, "segment")], "rule.groups:vault")
place("vault-levels", "visualization", 0, 21, 12, 14)
table("vault-top-rules", "Top Vault rules", "rule.groups:vault", ["rule.id", "rule.description"], 12, 21, 36)
table("vault-identities", "Identities in alerts", "rule.groups:vault and data.auth.display_name:*",
      ["data.auth.display_name"], 0, 35, 16)
table("vault-paths", "Paths in alerts", "rule.groups:vault and data.request.path:*", ["data.request.path"], 16, 35, 16)
table("vault-failed", "Failed logins by path and source", "rule.id:100110",
      ["data.request.path", "data.request.remote_address"], 32, 35, 16)
table("vault-server", "Server log findings by node", "rule.groups:vault_server", ["rule.description", "location"],
      0, 49, 48, h=12)

# event list
objs.append({
    "type": "search", "id": "vault-events",
    "attributes": {
        "title": "Vault alert events", "description": "", "version": 1,
        "columns": ["rule.level", "rule.description", "data.auth.display_name", "data.request.path",
                    "data.request.remote_address"],
        "sort": [["timestamp", "desc"]],
        "kibanaSavedObjectMeta": {"searchSourceJSON": source("rule.groups:vault")},
    },
    "references": [{"name": "kibanaSavedObjectMeta.searchSourceJSON.index", "type": "index-pattern", "id": IDX}],
})
place("vault-events", "search", 0, 61, 48, 18)

objs.append({
    "type": "dashboard", "id": "vault-siem",
    "attributes": {
        "title": "Vault SIEM", "description": "Vault audit and server log alerts from the lab rules (1001xx, 1002xx)",
        "hits": 0, "version": 1, "timeRestore": True, "timeFrom": "now-1h", "timeTo": "now",
        "refreshInterval": {"pause": False, "value": 30000},
        "optionsJSON": json.dumps({"hidePanelTitles": False, "useMargins": True}),
        "panelsJSON": json.dumps(panels),
        "kibanaSavedObjectMeta": {"searchSourceJSON": json.dumps({"query": {"query": "", "language": "kuery"},
                                                                  "filter": []})},
    },
    "references": refs,
})

out = os.path.join(os.path.dirname(__file__), "vault-siem-dashboard.ndjson")
with open(out, "w") as f:
    for o in objs:
        f.write(json.dumps(o) + "\n")
print("wrote", out, len(objs), "objects")

# The Wazuh app creates the wazuh-alerts-* index pattern on first login. On a fresh lab the
# import may run before that, so lab.sh imports this first (without overwrite).
ip = {"type": "index-pattern", "id": IDX,
      "attributes": {"title": IDX, "timeFieldName": "timestamp"}, "references": []}
with open(os.path.join(os.path.dirname(__file__), "wazuh-alerts-index-pattern.ndjson"), "w") as f:
    f.write(json.dumps(ip) + "\n")
