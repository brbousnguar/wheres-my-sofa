%dw 2.0

// Order data and the business rules that must not depend on a prompt:
// who owns an order, which slots are free, when a delivery can still move.

var data = readUrl("classpath://data/orders.json", "application/json")

// Rebooking closes this many days before the booked slot.
var rebookCutoffDays = 2

fun day(n) =
  if (n == null) null
  else if (n >= 0) (now() as Date) + ("P$(n)D" as Period)
  else (now() as Date) - ("P$(abs(n))D" as Period)

fun normEmail(e) = lower(trim(e default ""))

fun rawOrder(id) = (data.orders filter ((o) -> o.orderId == upper(trim(id default ""))))[0]

fun ownedBy(o, email) = o != null and normEmail(o.customer.email) == normEmail(email)

fun ordersOf(email) = data.orders filter ((o) -> ownedBy(o, email)) orderBy -($.orderedOn)

fun allSlots(o) = [o.delivery.slot] ++ (o.delivery.availableSlots default []) filter ($ != null)

fun currentSlot(o, rebookings) = do {
  var moved = rebookings[o.orderId]
  ---
  if (moved != null) (allSlots(o) filter ($.slotId == moved))[0] else o.delivery.slot
}

fun freeSlots(o, rebookings) = do {
  var cur = currentSlot(o, rebookings)
  ---
  allSlots(o) filter ($.slotId != cur.slotId) orderBy $.date
}

fun canReschedule(o, rebookings) =
  o.delivery.status == "BOOKED" and (currentSlot(o, rebookings).date >= rebookCutoffDays)

fun slotOut(s) = if (s == null) null else do {
  var d = day(s.date)
  ---
  { slotId: s.slotId, date: d, weekday: d as String { format: "EEEE" }, window: s.window }
}

fun lineOut(l) = {
  lineId: l.lineId,
  product: l.product,
  options: l.options,
  quantity: l.quantity default 1,
  madeToOrder: l.madeToOrder,
  status: l.status,
  (deliveredOn: day(l.deliveredOn)) if (l.deliveredOn != null),
  (production: {
    supplierOrder: l.production.supplierOrder,
    workshop: l.production.workshop,
    stagesDone: l.production.stagesDone,
    currentStage: l.production.currentStage,
    stagesLeft: l.production.stagesLeft,
    promisedReadyOn: day(l.production.promisedReadyOn),
    estimatedReadyOn: day(l.production.estimatedReadyOn),
    delayDays: l.production.estimatedReadyOn - l.production.promisedReadyOn,
    (delayReason: l.production.delayReason) if (l.production.delayReason != null)
  }) if (l.production != null)
}

fun deliveryOut(o, rebookings) = {
  status: o.delivery.status,
  (slot: slotOut(currentSlot(o, rebookings))) if (o.delivery.slot != null),
  (deliveredOn: day(o.delivery.deliveredOn)) if (o.delivery.deliveredOn != null),
  (address: o.delivery.address) if (o.delivery.address != null),
  (note: o.delivery.note) if (o.delivery.note != null),
  (canReschedule: canReschedule(o, rebookings)) if (o.delivery.status == "BOOKED")
}

fun orderOut(o, rebookings) = {
  orderId: o.orderId,
  customerName: o.customer.name,
  orderedOn: day(o.orderedOn),
  store: o.store,
  status: o.status,
  lines: o.lines map lineOut($),
  delivery: deliveryOut(o, rebookings)
}

fun summaryOut(o, rebookings) = {
  orderId: o.orderId,
  orderedOn: day(o.orderedOn),
  status: o.status,
  items: o.lines map ((l) -> "$(l.quantity default 1) x $(l.product)"),
  deliveryStatus: o.delivery.status
}
