/**
 * Task 1 - Parse ShipmentEvent (JavaScript task, V8).
 * Works for both triggers:
 *   - Cloud Pub/Sub trigger: CloudPubSubMessage.data holds the ShipmentEvent JSON (plain or base64)
 *   - API trigger (tests / replays): shipmentEventJson holds the ShipmentEvent
 * Sets: shipmentEvent, orderId, status, isException, orderUrl, requestHeaders.
 */
function b64decode(s) {
  var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  var out = "", buf = 0, bits = 0;
  s = String(s).replace(/[^A-Za-z0-9+/]/g, "");
  for (var i = 0; i < s.length; i++) {
    buf = (buf << 6) | chars.indexOf(s.charAt(i));
    bits += 6;
    if (bits >= 8) { bits -= 8; out += String.fromCharCode((buf >> bits) & 0xff); }
  }
  try { return decodeURIComponent(escape(out)); } catch (e) { return out; }
}

function asObject(v) {
  if (v === null || v === undefined || v === "") return null;
  if (typeof v === "string") {
    var t = v.trim();
    if (t.charAt(0) === "{") return JSON.parse(t);
    return JSON.parse(b64decode(t));
  }
  return v;
}

function executeScript(event) {
  var ev = asObject(event.getParameter("shipmentEventJson"));
  if (!ev) {
    var msg = asObject(event.getParameter("CloudPubSubMessage"));
    if (msg) ev = asObject(msg.data);
  }
  if (!ev) throw new Error("no ShipmentEvent in shipmentEventJson or CloudPubSubMessage.data");

  var status = String(ev.status || "");
  event.setParameter("shipmentEvent", ev);
  event.setParameter("orderId", String(ev.orderId || ""));
  event.setParameter("status", status);
  event.setParameter("isException", status === "EXCEPTION");
  var key = event.getParameter("orderApiKey");
  event.setParameter("orderUrl", event.getParameter("orderApiBaseUrl") + "/" + encodeURIComponent(ev.orderId)
      + (key ? "?apikey=" + encodeURIComponent(key) : ""));
  event.setParameter("requestHeaders", {
    "x-api-key": event.getParameter("orderApiKey"),
    "X-Correlation-Id": String(ev.correlationId || ev.eventId || "")
  });
  event.log("shipment " + ev.trackingNumber + " for " + ev.orderId + " status=" + status);
}
