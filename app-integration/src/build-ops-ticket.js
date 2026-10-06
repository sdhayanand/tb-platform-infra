/**
 * Task 3 - Build the ops ticket from the shipment exception + the order fetched through Apigee.
 * In production the next step is a ServiceNow / Jira connector task; here the ticket is the
 * integration's output variable (opsTicket), visible in the execution log and the :execute response.
 */
function executeScript(event) {
  var ev = event.getParameter("shipmentEvent");
  if (typeof ev === "string") ev = JSON.parse(ev);
  var body = event.getParameter("`Task_2_responseBody`");
  var order = {};
  try { order = typeof body === "string" ? JSON.parse(body) : (body || {}); } catch (e) { order = { raw: String(body) }; }
  var lines = order.lines || [];
  event.setParameter("opsTicket", {
    title: "Shipment exception for " + ev.orderId + " (" + ev.carrier + " " + ev.trackingNumber + ")",
    priority: (order.orderType === "TAILORED" || order.orderType === "RENTAL") ? "P2" : "P3",
    carrier: ev.carrier,
    trackingNumber: ev.trackingNumber,
    location: ev.location,
    statusTime: ev.statusTime,
    correlationId: ev.correlationId,
    order: {
      orderId: order.orderId,
      status: order.status,
      orderType: order.orderType,
      storeId: order.storeId,
      totalAmount: order.totalAmount,
      lineCount: lines.length
    },
    fetchedVia: "Apigee " + event.getParameter("orderApiBaseUrl"),
    httpStatus: String(event.getParameter("`Task_2_responseStatus`"))
  });
}
