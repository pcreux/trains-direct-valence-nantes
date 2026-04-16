#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Génère index.html avec les trains directs Valence TGV ↔ Angers / Nantes
# Usage : NAVITIA_TOKEN=xxx ruby generate.rb

require 'net/http'
require 'json'
require 'date'
require 'uri'
require 'yaml'
require 'dotenv/load'

TOKEN        = ENV.fetch('NAVITIA_TOKEN') { abort 'Définir la variable NAVITIA_TOKEN.' }
BASE         = 'https://api.sncf.com/v1/coverage/sncf'
HISTORY_FILE = 'history.yaml'

JOURS = %w[dimanche lundi mardi mercredi jeudi vendredi samedi]
MOIS  = %w[janvier février mars avril mai juin juillet août septembre octobre novembre décembre]

# ── API ──────────────────────────────────────────────────────────────────────

def api_get(path, params = {})
  uri = URI("#{BASE}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?

  retries = 0
  begin
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      req = Net::HTTP::Get.new(uri)
      req.basic_auth(TOKEN, '')
      response = http.request(req)
      body = JSON.parse(response.body)
      return nil if response.code == '404' && body.dig('error', 'id') == 'date_out_of_bounds'
      raise "503" if response.code == '503'
      abort "Erreur API #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
      body
    end
  rescue => e
    retries += 1
    if retries <= 5
      warn "  Nouvelle tentative dans #{retries * 2}s (#{e.message})…"
      sleep retries * 2
      retry
    end
    abort "Échec API après #{retries} tentatives : #{e.message}"
  end
end

def resolve_stop(query)
  data  = api_get('/places', q: query, 'type[]' => 'stop_area', count: 5)
  stops = (data['places'] || []).select { |p| p['embedded_type'] == 'stop_area' }
  abort "Arrêt introuvable : '#{query}'" if stops.empty?
  warn "  #{query.ljust(25)} → #{stops.first['name']} (#{stops.first['id']})"
  stops.first['id']
end

def fetch_direct_journeys(from_id, to_id, start_dt, end_dt)
  seen    = {}
  results = []
  date    = start_dt.to_date

  while date <= end_dt.to_date
    current = DateTime.new(date.year, date.month, date.day, 4, 0, 0)
    day_end = DateTime.new(date.year, date.month, date.day, 23, 59, 0)

    loop do
      break if current > day_end

      data = api_get('/journeys',
        from:                from_id,
        to:                  to_id,
        datetime:            current.strftime('%Y%m%dT%H%M%S'),
        datetime_represents: 'departure',
        max_nb_transfers:    0,
        min_nb_journeys:     10,
        direct_path:         'none'
      )

      return results if data.nil?

      trips = data['journeys'] || []
      break if trips.empty?

      trips.each do |trip|
        dep_str = trip['departure_date_time']
        dep     = DateTime.strptime(dep_str, '%Y%m%dT%H%M%S')

        next if dep.to_date != date
        next if seen[dep_str]
        next if dep < start_dt || dep > end_dt

        seen[dep_str] = true
        arr = DateTime.strptime(trip['arrival_date_time'], '%Y%m%dT%H%M%S')

        results << { dep: dep, arr: arr, duration: trip['duration'] / 60 }
      end

      last_dep = DateTime.strptime(trips.last['departure_date_time'], '%Y%m%dT%H%M%S')
      break if last_dep.to_date > date
      current = last_dep + Rational(1, 1440)
    end

    date += 1
  end

  results.sort_by { |r| r[:dep] }
end

# ── History ───────────────────────────────────────────────────────────────────

def load_history
  return { 'routes' => [] } unless File.exist?(HISTORY_FILE)
  YAML.safe_load(File.read(HISTORY_FILE)) || { 'routes' => [] }
end

def find_or_create_route(history, from_label, to_label)
  route = history['routes'].find { |r| r['from'] == from_label && r['to'] == to_label }
  unless route
    route = { 'from' => from_label, 'to' => to_label, 'connections' => [] }
    history['routes'] << route
  end
  route
end

def merge_connections(route, new_trips)
  existing = route['connections']
  seen = existing.map { |c| "#{c['date']}T#{c['departure']}" }.to_h { |k| [k, true] }
  new_trips.each do |trip|
    key = trip[:dep].strftime('%Y-%m-%dT%H:%M')
    next if seen[key]
    seen[key] = true
    existing << {
      'date'      => trip[:dep].strftime('%Y-%m-%d'),
      'departure' => trip[:dep].strftime('%H:%M'),
      'arrival'   => trip[:arr].strftime('%H:%M'),
      'duration'  => trip[:duration]
    }
  end
  route['connections'] = existing.sort_by { |c| "#{c['date']}T#{c['departure']}" }
end

# ── Formatting ────────────────────────────────────────────────────────────────

def fmt_date(date)
  "#{JOURS[date.wday].capitalize[0, 3]}. #{date.day} #{MOIS[date.month - 1][0, 3]}."
end

def fmt_duration(min)
  "#{min / 60}h#{(min % 60).to_s.rjust(2, '0')}"
end

def dep_class(hour)
  case hour
  when  0..6  then 't-nuit'
  when  7..11 then 't-matin'
  when 12..16 then 't-apm'
  else             't-soir'
  end
end

def render_rows(connections)
  return '<tr><td colspan="4" class="empty">Aucun train direct trouvé.</td></tr>' if connections.empty?

  connections.map do |c|
    date = Date.parse(c['date'])
    hour = c['departure'].split(':').first.to_i
    cls  = date.wday == 1 ? ' class="week-start"' : ''
    "<tr#{cls}>" \
      "<td>#{fmt_date(date)}</td>" \
      "<td class=\"time #{dep_class(hour)}\">#{c['departure']}</td>" \
      "<td class=\"time\">#{c['arrival']}</td>" \
      "<td class=\"dur\">#{fmt_duration(c['duration'])}</td>" \
    "</tr>"
  end.join("\n        ")
end

def render_section(from_label, to_label, connections)
  count = connections.size
  rows  = render_rows(connections)
  count_label = count == 0 ? 'Aucun train direct' : "#{count} train#{count > 1 ? 's' : ''} direct#{count > 1 ? 's' : ''}"
  <<~HTML
    <section class="card">
      <div class="card-header">
        <div class="card-title">#{from_label} <span class="arrow">→</span> #{to_label}</div>
        <div class="count">#{count_label}</div>
      </div>
      <div class="table-scroll">
        <table>
          <thead>
            <tr><th>Jour</th><th>Départ</th><th>Arrivée</th><th>Durée</th></tr>
          </thead>
          <tbody>
          #{rows}
          </tbody>
        </table>
      </div>
    </section>
  HTML
end

# ── Main ─────────────────────────────────────────────────────────────────────

warn 'Résolution des arrêts…'
valence_id = resolve_stop('Valence TGV')
angers_id  = resolve_stop('Angers Saint-Laud')
nantes_id  = resolve_stop('Nantes')

start_dt = DateTime.now
end_dt   = DateTime.now + 30
warn "Récupération des trains #{start_dt.strftime('%d/%m/%Y')} → #{end_dt.strftime('%d/%m/%Y')}…"

routes = [
  ['Valence TGV',       'Angers Saint-Laud', valence_id, angers_id],
  ['Valence TGV',       'Nantes',            valence_id, nantes_id],
  ['Angers Saint-Laud', 'Valence TGV',       angers_id,  valence_id],
  ['Nantes',            'Valence TGV',       nantes_id,  valence_id],
]

history = load_history

sections = routes.map do |from_label, to_label, from_id, to_id|
  trips = fetch_direct_journeys(from_id, to_id, start_dt, end_dt)
  warn "  #{from_label} → #{to_label} : #{trips.size} train(s)"
  route = find_or_create_route(history, from_label, to_label)
  merge_connections(route, trips)
  render_section(from_label, to_label, route['connections'])
end

history['generated_at'] = Date.today.to_s
File.write(HISTORY_FILE, history.to_yaml)
warn "#{HISTORY_FILE} mis à jour."

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
      td.dur  { color: #6b7280; font-size: 0.8rem; }

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
warn 'index.html généré.'
