.pragma library

// Layout model shared by the editor and the drag overlay.
//
// A layout is a list of columns. Each column has a `width` (fraction of the
// usable area) and `rows`, a list of row heights (fractions of the column).
// hypr/zones.lua does the same math on the Hyprland side; keep them in sync.

var MIN_FRACTION = 0.05

var presets = [
  { name: "Focus", description: "25 / 50 / 25", columns: [col(0.25), col(0.5), col(0.25)] },
  { name: "Side stacks", description: "Stacked sides, wide middle", columns: [col(0.25, [0.5, 0.5]), col(0.5), col(0.25, [0.5, 0.5])] },
  { name: "Wide focus", description: "20 / 60 / 20", columns: [col(0.2), col(0.6), col(0.2)] },
  { name: "Thirds", description: "Three equal columns", columns: [col(1 / 3), col(1 / 3), col(1 / 3)] },
  { name: "Halves", description: "Two equal columns", columns: [col(0.5), col(0.5)] },
  { name: "Grid", description: "2 × 2", columns: [col(0.5, [0.5, 0.5]), col(0.5, [0.5, 0.5])] }
]

function col(width, rows) {
  return { width: width, rows: rows || [1] }
}

function clone(columns) {
  return JSON.parse(JSON.stringify(columns || []))
}

function defaultLayout() {
  return clone(presets[0].columns)
}

// Zones in pixels relative to `area` ({ x, y, w, h }), with `gap` around and
// between them. Each zone remembers which column/row it came from.
function zones(columns, area, gap) {
  var out = []
  var innerX = area.x + gap
  var innerY = area.y + gap
  var innerW = area.w - gap
  var innerH = area.h - gap
  var fx = 0
  for (var c = 0; c < columns.length; c++) {
    var column = columns[c]
    var fy = 0
    for (var r = 0; r < column.rows.length; r++) {
      out.push({
        column: c,
        row: r,
        x: Math.floor(innerX + fx * innerW),
        y: Math.floor(innerY + fy * innerH),
        w: Math.floor(column.width * innerW - gap),
        h: Math.floor(column.rows[r] * innerH - gap)
      })
      fy += column.rows[r]
    }
    fx += column.width
  }
  return out
}

// Left edge of each column after the first, as a fraction of the area.
function columnEdges(columns) {
  var edges = []
  var fx = 0
  for (var c = 0; c < columns.length - 1; c++) {
    fx += columns[c].width
    edges.push(fx)
  }
  return edges
}

function rowEdges(column) {
  var edges = []
  var fy = 0
  for (var r = 0; r < column.rows.length - 1; r++) {
    fy += column.rows[r]
    edges.push(fy)
  }
  return edges
}

function round(value) {
  return Math.round(value * 1000) / 1000
}

// Move the divider between `list[i]` and `list[i + 1]` to `edge` (a fraction
// measured from the start of the list), keeping both sides above the minimum.
// `snap` rounds to whole percents; leave it off while dragging so the divider
// follows the pointer, and snap once it's dropped.
function moveEdge(list, i, edge, snap) {
  var start = 0
  for (var k = 0; k < i; k++) start += list[k]
  var pair = list[i] + list[i + 1]
  var first = Math.min(Math.max(edge - start, MIN_FRACTION), pair - MIN_FRACTION)
  first = snap ? round(Math.round(first * 100) / 100) : round(first)
  list[i] = first
  list[i + 1] = round(pair - first)
}

function moveColumnEdge(columns, i, edge, snap) {
  var next = clone(columns)
  var widths = next.map(function (c) { return c.width })
  moveEdge(widths, i, edge, snap)
  for (var c = 0; c < next.length; c++) next[c].width = widths[c]
  return next
}

function moveRowEdge(columns, c, i, edge, snap) {
  var next = clone(columns)
  moveEdge(next[c].rows, i, edge, snap)
  return next
}

// Split a zone in two side by side. A column with several rows becomes two
// columns with the same rows.
function splitVertical(columns, c) {
  var next = clone(columns)
  var half = round(next[c].width / 2)
  if (half < MIN_FRACTION) return next
  next[c].width = round(next[c].width - half)
  next.splice(c + 1, 0, { width: half, rows: next[c].rows.slice() })
  return next
}

function splitHorizontal(columns, c, r) {
  var next = clone(columns)
  var rows = next[c].rows
  var half = round(rows[r] / 2)
  if (half < MIN_FRACTION) return next
  rows[r] = round(rows[r] - half)
  rows.splice(r + 1, 0, half)
  return next
}

// Remove a zone, giving its space to a neighbour.
function remove(columns, c, r) {
  var next = clone(columns)
  var rows = next[c].rows
  if (rows.length > 1) {
    var freed = rows.splice(r, 1)[0]
    rows[Math.max(0, r - 1)] = round(rows[Math.max(0, r - 1)] + freed)
    return next
  }
  if (next.length === 1) return next
  var removed = next.splice(c, 1)[0]
  var neighbour = Math.max(0, c - 1)
  next[neighbour].width = round(next[neighbour].width + removed.width)
  return next
}

// Accept anything that looks like a layout, otherwise fall back.
function sanitize(columns) {
  if (!Array.isArray(columns) || columns.length === 0) return defaultLayout()
  var out = []
  var total = 0
  for (var c = 0; c < columns.length; c++) {
    var width = Number(columns[c] && columns[c].width)
    if (!(width > 0)) continue
    var rows = Array.isArray(columns[c].rows) ? columns[c].rows.map(Number).filter(function (h) { return h > 0 }) : []
    if (rows.length === 0) rows = [1]
    var rowTotal = rows.reduce(function (a, b) { return a + b }, 0)
    out.push({ width: width, rows: rows.map(function (h) { return round(h / rowTotal) }) })
    total += width
  }
  if (out.length === 0) return defaultLayout()
  for (var i = 0; i < out.length; i++) out[i].width = round(out[i].width / total)
  return out
}
