#!/usr/bin/env python3
"""Builds the IntegrationVersion JSON for tb-shipment-exception-to-ops (Application Integration).

    Pub/Sub trigger (shipments-v1) ─┐
    API trigger (tests / replays) ──┴─▶ 1 JavaScript: parse ShipmentEvent
                                          └─ [status == EXCEPTION] ─▶ 2 Call REST endpoint: GET order via Apigee
                                                                        └─▶ 3 JavaScript: build ops ticket (output)

The task scripts live in src/*.js so they can be unit-tested and reviewed like code.
Env: PROJECT_ID, ORDER_API_BASE (e.g. http://<ip>.nip.io/v1/orders), ORDER_API_KEY (optional),
     TRIGGER_SA (default tb-app-integration@PROJECT_ID.iam.gserviceaccount.com).
Writes JSON to stdout.
"""
import json
import os
import pathlib

NAME = "tb-shipment-exception-to-ops"
HERE = pathlib.Path(__file__).resolve().parent
PROJECT = os.environ["PROJECT_ID"]
ORDER_API_BASE = os.environ["ORDER_API_BASE"]
ORDER_API_KEY = os.environ.get("ORDER_API_KEY", "")
TRIGGER_SA = os.environ.get("TRIGGER_SA", f"tb-app-integration@{PROJECT}.iam.gserviceaccount.com")
TOPIC = f"projects/{PROJECT}/topics/shipments-v1"


def s(v):
    return {"stringValue": v}


def b(v):
    return {"booleanValue": v}


def out(var):
    return {"stringArray": {"stringValues": [f"$`{var}`$"]}}


def js_task(task_id, name, file, next_tasks=None):
    return {
        "task": "JavaScriptTask",
        "taskId": task_id,
        "displayName": name,
        "parameters": {
            "javaScriptEngine": {"key": "javaScriptEngine", "value": s("V8")},
            "script": {"key": "script", "value": s((HERE / "src" / file).read_text())},
        },
        "nextTasks": next_tasks or [],
        "taskExecutionStrategy": "WHEN_ALL_SUCCEED",
    }


rest_task = {
    "task": "GenericRestV2Task",
    "taskId": "2",
    "displayName": "GET order through Apigee",
    "parameters": {
        "url": {"key": "url", "value": s("$orderUrl$")},
        "httpMethod": {"key": "httpMethod", "value": s("GET")},
        # Request headers = a JSON object of name -> value (what the editor's key/value rows export as).
        # A "$var$" reference here is NOT expanded (first live run: 401), so the values are literal.
        "additionalHeaders": {"key": "additionalHeaders",
                              "value": {"jsonValue": json.dumps({"x-api-key": ORDER_API_KEY,
                                                                 "X-Correlation-Id": "app-integration"})}},
        "responseBody": {"key": "responseBody", "value": out("Task_2_responseBody")},
        "responseHeader": {"key": "responseHeader", "value": out("Task_2_responseHeader")},
        "responseStatus": {"key": "responseStatus", "value": out("Task_2_responseStatus")},
        "throwError": {"key": "throwError", "value": b(True)},
        "followRedirects": {"key": "followRedirects", "value": b(True)},
        "urlFetchingService": {"key": "urlFetchingService", "value": s("HARPOON")},
        "useSSL": {"key": "useSSL", "value": b(False)},
        "disableSSLValidation": {"key": "disableSSLValidation", "value": b(False)},
        "requestorId": {"key": "requestorId", "value": s("tb-app-integration")},
        "requestBody": {"key": "requestBody", "value": s("")},
        "userAgent": {"key": "userAgent", "value": s("")},
        "httpParams": {"key": "httpParams"},
        "urlQueryStrings": {"key": "urlQueryStrings"},
    },
    "nextTasks": [{"taskId": "3"}],
    "taskExecutionStrategy": "WHEN_ALL_SUCCEED",
}


def param(key, data_type, io=None, default=None, transient=False, producer=None):
    p = {"key": key, "dataType": data_type, "displayName": key}
    if io:
        p["inputOutputType"] = io
    if default is not None:
        p["defaultValue"] = default
    if transient:
        p["isTransient"] = True
    if producer:
        p["producer"] = producer
    return p


version = {
    "description": (
        "When a carrier reports a shipment EXCEPTION on shipments-v1, fetch the order through the Apigee "
        "Order API and raise an ops ticket. Low-code equivalent of a TIBCO BusinessWorks process."
    ),
    "triggerConfigs": [
        {
            "label": "Cloud Pub/Sub Trigger",
            "triggerType": "CLOUD_PUBSUB_EXTERNAL",
            "triggerNumber": "1",
            "triggerId": f"cloud_pubsub_external_trigger/{TOPIC}",
            "properties": {
                "IP Project name": PROJECT,
                "Subscription name": f"{PROJECT}_shipments-v1",
                "Service account": TRIGGER_SA,
            },
            "startTasks": [{"taskId": "1"}],
        },
        {
            "label": "API Trigger",
            "triggerType": "API",
            "triggerNumber": "2",
            "triggerId": f"api_trigger/{NAME}_API_1",
            "properties": {"Trigger name": f"{NAME}_API_1"},
            "startTasks": [{"taskId": "1"}],
        },
    ],
    "taskConfigs": [
        js_task("1", "Parse ShipmentEvent", "parse-shipment-event.js",
                [{"taskId": "2", "condition": "$isException$ = true", "displayName": "status == EXCEPTION"}]),
        rest_task,
        js_task("3", "Build ops ticket", "build-ops-ticket.js"),
    ],
    "integrationParameters": [
        param("CloudPubSubMessage", "JSON_VALUE", io="IN"),
        param("shipmentEventJson", "JSON_VALUE", io="IN"),
        param("orderApiBaseUrl", "STRING_VALUE", default=s(ORDER_API_BASE)),
        # Demo shortcut: the key is a default value. Production: an Auth Config (API key) or a
        # config variable fed from Secret Manager, so the key never sits in the integration JSON.
        param("orderApiKey", "STRING_VALUE", default=s(ORDER_API_KEY)),
        param("shipmentEvent", "JSON_VALUE"),
        param("orderId", "STRING_VALUE", io="OUT"),
        param("status", "STRING_VALUE", io="OUT"),
        param("isException", "BOOLEAN_VALUE", io="OUT"),
        param("orderUrl", "STRING_VALUE"),
        param("requestHeaders", "JSON_VALUE"),
        param("opsTicket", "JSON_VALUE", io="OUT"),
        param("`Task_2_responseBody`", "STRING_VALUE", transient=True, producer="1_2"),
        param("`Task_2_responseHeader`", "STRING_VALUE", transient=True, producer="1_2"),
        param("`Task_2_responseStatus`", "STRING_VALUE", transient=True, producer="1_2"),
    ],
}

print(json.dumps(version, indent=2))
