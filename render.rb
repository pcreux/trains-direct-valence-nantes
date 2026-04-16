#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Generates index.html from history.yaml
# Usage: ruby render.rb

require 'yaml'
require 'date'

HISTORY_FILE = 'history.yaml'

JOURS = %w[dimanche lundi mardi mercredi jeudi vendredi samedi]
MOIS  = %w[janvier février mars avril mai juin juillet août septembre octobre novembre décembre]

# ── Helpers ───────────────────────────────────────────────────────────────────

def fmt_date(date)
  "#{JOURS[date.wday].capitalize[0, 3]}. #{date.day} #{MOIS[date.month - 1][0, 3]}."
end

def dep_class(hour)
  case hour
  when  0..6  then 't-nuit'
  when  7..11 then 't-matin'
  when 12..16 then 't-apm'
  else             't-soir'
  end
end

def find_route(history, from_label, to_label)
  history['routes'].find { |r| r['from'] == from_label && r['to'] == to_label } || { 'connections' => [] }
end

# ── Merge ─────────────────────────────────────────────────────────────────────

def merge_outbound(angers, nantes)
  by_key = {}
  angers.each { |c| (by_key["#{c['date']}T#{c['departure']}"] ||= { 'date' => c['date'], 'departure' => c['departure'] })['angers'] = c['arrival'] }
  nantes.each { |c| (by_key["#{c['date']}T#{c['departure']}"] ||= { 'date' => c['date'], 'departure' => c['departure'] })['nantes'] = c['arrival'] }
  by_key.values.sort_by { |r| "#{r['date']}T#{r['departure']}" }
end

def merge_inbound(angers, nantes)
  by_key = {}
  angers.each { |c| (by_key["#{c['date']}T#{c['arrival']}"] ||= { 'date' => c['date'], 'arrival' => c['arrival'] })['angers'] = c['departure'] }
  nantes.each { |c| (by_key["#{c['date']}T#{c['arrival']}"] ||= { 'date' => c['date'], 'arrival' => c['arrival'] })['nantes'] = c['departure'] }
  by_key.values.sort_by { |r| "#{r['date']}T#{r['arrival']}" }
end

# ── Rendering ─────────────────────────────────────────────────────────────────

def render_rows_outbound(rows)
  return '<tr><td colspan="4" class="empty">Aucun train direct trouvé.</td></tr>' if rows.empty?
  rows.map do |r|
    date = Date.parse(r['date'])
    hour = r['departure'].split(':').first.to_i
    cls  = date.wday == 1 ? ' class="week-start"' : ''
    "<tr#{cls}><td>#{fmt_date(date)}</td><td class=\"time #{dep_class(hour)}\">#{r['departure']}</td><td class=\"time\">#{r['angers'] || '—'}</td><td class=\"time\">#{r['nantes'] || '—'}</td></tr>"
  end.join("\n        ")
end

def render_rows_inbound(rows)
  return '<tr><td colspan="4" class="empty">Aucun train direct trouvé.</td></tr>' if rows.empty?
  rows.map do |r|
    date        = Date.parse(r['date'])
    nantes_cls  = r['nantes'] ? dep_class(r['nantes'].split(':').first.to_i) : ''
    angers_cls  = r['angers'] ? dep_class(r['angers'].split(':').first.to_i) : ''
    cls         = date.wday == 1 ? ' class="week-start"' : ''
    "<tr#{cls}><td>#{fmt_date(date)}</td><td class=\"time #{nantes_cls}\">#{r['nantes'] || '—'}</td><td class=\"time #{angers_cls}\">#{r['angers'] || '—'}</td><td class=\"time\">#{r['arrival']}</td></tr>"
  end.join("\n        ")
end

def render_section_outbound(rows)
  count = rows.size
  count_label = count == 0 ? 'Aucun train direct' : "#{count} départ#{count > 1 ? 's' : ''}"
  <<~HTML
    <section class="card">
      <div class="card-header">
        <div class="card-title">Valence TGV <span class="arrow">→</span> Angers · Nantes</div>
        <div class="count">#{count_label}</div>
      </div>
      <div class="table-scroll">
        <table>
          <thead>
            <tr><th>Jour</th><th>Valence</th><th>Angers</th><th>Nantes</th></tr>
          </thead>
          <tbody>
          #{render_rows_outbound(rows)}
          </tbody>
        </table>
      </div>
    </section>
  HTML
end

def render_section_inbound(rows)
  count = rows.size
  count_label = count == 0 ? 'Aucun train direct' : "#{count} arrivée#{count > 1 ? 's' : ''}"
  <<~HTML
    <section class="card">
      <div class="card-header">
        <div class="card-title">Nantes · Angers <span class="arrow">→</span> Valence TGV</div>
        <div class="count">#{count_label}</div>
      </div>
      <div class="table-scroll">
        <table>
          <thead>
            <tr><th>Jour</th><th>Nantes</th><th>Angers</th><th>Valence</th></tr>
          </thead>
          <tbody>
          #{render_rows_inbound(rows)}
          </tbody>
        </table>
      </div>
    </section>
  HTML
end

# ── Main ──────────────────────────────────────────────────────────────────────

history = YAML.safe_load(File.read(HISTORY_FILE))

sections = [
  render_section_outbound(merge_outbound(
    find_route(history, 'Valence TGV', 'Angers Saint-Laud')['connections'],
    find_route(history, 'Valence TGV', 'Nantes')['connections']
  )),
  render_section_inbound(merge_inbound(
    find_route(history, 'Angers Saint-Laud', 'Valence TGV')['connections'],
    find_route(history, 'Nantes', 'Valence TGV')['connections']
  ))
]

today        = Date.today
generated_at = "#{JOURS[today.wday]} #{today.day} #{MOIS[today.month - 1]} #{today.year}"

html = <<~HTML
  <!DOCTYPE html>
  <html lang="fr">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Trains directs — Valence TGV ↔ Angers · Nantes</title>
    <style>
      *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

      body {
        font-family: system-ui, -apple-system, 'Segoe UI', sans-serif;
        background: #f0f2f5;
        color: #1c1c1e;
        min-height: 100vh;
      }

      header {
        background: #c8102e;
        color: #fff;
        padding: 2.25rem 1.5rem 2rem;
        text-align: center;
      }
      header h1 { font-size: 1.6rem; font-weight: 700; letter-spacing: -0.01em; }
      header .subtitle { font-size: 1rem; opacity: 0.85; margin-top: 0.3rem; }
      header .updated  { font-size: 0.75rem; opacity: 0.6; margin-top: 0.75rem; }

      main {
        max-width: 860px;
        margin: 2rem auto;
        padding: 0 1rem 4rem;
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 1.25rem;
      }
      @media (max-width: 600px) { main { grid-template-columns: 1fr; } }

      .card {
        background: #fff;
        border-radius: 10px;
        overflow: hidden;
        box-shadow: 0 1px 4px rgba(0,0,0,0.08);
      }

      .card-header {
        padding: 0.9rem 1.1rem 0.7rem;
        border-bottom: 1px solid #e5e7eb;
      }
      .card-title {
        font-size: 0.88rem;
        font-weight: 600;
        color: #c8102e;
        display: flex;
        align-items: center;
        gap: 0.3rem;
      }
      .arrow { color: #aaa; font-weight: 400; }
      .count { font-size: 0.72rem; color: #9ca3af; margin-top: 0.2rem; }

      .table-scroll {
        max-height: 33rem;
        overflow-y: auto;
      }

      table { width: 100%; border-collapse: collapse; }

      th {
        font-size: 0.68rem;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.06em;
        color: #9ca3af;
        padding: 0.55rem 1.1rem;
        text-align: left;
        background: #fafafa;
        border-bottom: 1px solid #e5e7eb;
        position: sticky;
        top: 0;
        z-index: 1;
      }

      td {
        padding: 0.5rem 1.1rem;
        font-size: 0.85rem;
        border-bottom: 1px solid #f3f4f6;
        white-space: nowrap;
      }
      tr:last-child td { border-bottom: none; }

      td.time { font-variant-numeric: tabular-nums; font-weight: 500; }

      td.t-nuit  { background: #ede9fe; color: #6d28d9; }
      td.t-matin { background: #fef9c3; color: #92400e; }
      td.t-apm   { background: #ffedd5; color: #9a3412; }
      td.t-soir  { background: #dbeafe; color: #1e40af; }

      tr.week-start td { border-top: 2px solid #d1d5db; }
      tbody tr:hover td { background: #f0f4ff; }

      td.empty { color: #9ca3af; font-style: italic; padding: 1rem 1.1rem; }
    </style>
  </head>
  <body>
    <header>
      <h1>🚄 Trains directs</h1>
      <p class="subtitle">Valence TGV ↔ Angers · Nantes</p>
      <p class="updated">Mis à jour le #{generated_at}</p>
    </header>
    <main>
#{sections.map { |s| s.gsub(/^/, '    ') }.join("\n")}
    </main>
    <script>
      document.querySelectorAll('.table-scroll').forEach(function(el) {
        el.scrollTop = el.scrollHeight;
      });
    </script>
  </body>
  </html>
HTML

File.write('index.html', html)
warn 'index.html generated.'
