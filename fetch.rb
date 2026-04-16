#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Fetches direct train connections from the SNCF API and updates history.yaml
# Usage: NAVITIA_TOKEN=xxx ruby fetch.rb

require 'net/http'
require 'json'
require 'date'
require 'uri'
require 'yaml'
require 'dotenv/load'

TOKEN        = ENV.fetch('NAVITIA_TOKEN') { abort 'Set NAVITIA_TOKEN.' }
BASE         = 'https://api.sncf.com/v1/coverage/sncf'
HISTORY_FILE = 'history.yaml'

# ── API ───────────────────────────────────────────────────────────────────────

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
      abort "API error #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
      body
    end
  rescue => e
    retries += 1
    if retries <= 5
      warn "  Retrying in #{retries * 2}s (#{e.message})…"
      sleep retries * 2
      retry
    end
    abort "API failed after #{retries} attempts: #{e.message}"
  end
end

def resolve_stop(query)
  data  = api_get('/places', q: query, 'type[]' => 'stop_area', count: 5)
  stops = (data['places'] || []).select { |p| p['embedded_type'] == 'stop_area' }
  abort "Stop not found: '#{query}'" if stops.empty?
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

# ── Main ──────────────────────────────────────────────────────────────────────

warn 'Resolving stops…'
valence_id = resolve_stop('Valence TGV')
angers_id  = resolve_stop('Angers Saint-Laud')
nantes_id  = resolve_stop('Nantes')

start_dt = DateTime.now
end_dt   = DateTime.now + 30
warn "Fetching trains #{start_dt.strftime('%d/%m/%Y')} → #{end_dt.strftime('%d/%m/%Y')}…"

routes = [
  ['Valence TGV',       'Angers Saint-Laud', valence_id, angers_id],
  ['Valence TGV',       'Nantes',            valence_id, nantes_id],
  ['Angers Saint-Laud', 'Valence TGV',       angers_id,  valence_id],
  ['Nantes',            'Valence TGV',       nantes_id,  valence_id],
]

history = load_history

routes.each do |from_label, to_label, from_id, to_id|
  trips = fetch_direct_journeys(from_id, to_id, start_dt, end_dt)
  warn "  #{from_label} → #{to_label}: #{trips.size} train(s)"
  route = find_or_create_route(history, from_label, to_label)
  merge_connections(route, trips)
end

history['generated_at'] = Date.today.to_s
File.write(HISTORY_FILE, history.to_yaml)
warn "#{HISTORY_FILE} updated."
